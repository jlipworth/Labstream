import Foundation
import PMSKit
import os

// GH #135 Stage 5c: the Emby "Convert Media" server-prep subsystem, split out of the
// DownloadManager god-object into its own file. Behavior-unchanged — these are the same
// @MainActor methods (an extension of a @MainActor class inherits its isolation), relocated
// verbatim so the convert-then-download lane reads as one cohesive unit:
//   triggerConvertAndDownload → pollAndDownloadEmbyConvertJob → finishEmbyConvert
//   (+ cancel/refresh/file-source helpers and the reuse-preflight pure helpers).
// Emby parity with the Plex optimize lane: render a PERSISTENT converted file, poll it to
// completion, then hand it to the resumable `.original` static lane via downloadEmby(…override:).

extension DownloadManager {

    // MARK: - Emby convert-then-download (server-side prepare → resumable download)

    /// Emby parity with the Plex optimize lane: create a server-side "Convert Media" Sync job that
    /// renders a PERSISTENT converted file (next-to-original, `targetId:"originalmediafolder"`),
    /// poll it to completion surfacing "Preparing on server… N%", then hand the freshly-converted
    /// MediaSource off to the resumable `.original` static lane via `downloadEmby(…override:)`.
    ///
    /// Why this exists: a live streaming transcode is ephemeral (no stable byte range), so a dropped
    /// connection restarts a multi-GB download from zero. The converted file IS range-resumable, and
    /// we KEEP it (deleting the Sync job never deletes the file) so #126's existing-version reuse
    /// serves the next download/resume for free.
    ///
    /// Mirrors `triggerOptimizeAndDownload`: the whole chain runs off the captured `session`
    /// (server/token/userId/identity), seeds a 0% `.preparing` row, and surfaces progress through the
    /// SAME `optimizeProgress`/`optimizeState` plumbing the UI already reads. The caller
    /// (`downloadEmby`) already holds the `activeJobs` slot; the relaunch resume path inserts it
    /// before calling. Failures are retry-only (NO streaming fallback — that would silently
    /// reintroduce the non-resumable behavior this feature removes).
    // Called from `downloadEmby` and the relaunch-resume path in DownloadManager.swift, so these
    // two entry points are `internal` (not `private`) now that the subsystem lives in its own file.
    func triggerConvertAndDownload(item: MediaItem, targetName: String,
                                           metadata: OfflineMetadata,
                                           session: BackendSession) async {
        let itemId = item.ratingKey
        let ratingKey = Self.embyRecordKey(itemId)
        let server = session.baseURL
        let token = session.token
        let identity = appModel.identity.emby
        guard let userId = session.userID else {
            failEmbyConvert(ratingKey: ratingKey, .notAuthenticated)
            return
        }

        // Carry the convert preset + a `.preparing`-grade metadata snapshot. `optimizeTargetName`
        // doubles as the server-prep marker the UI/resume paths key off (parity with Plex).
        var convertMetadata = metadata
        convertMetadata.optimizeTargetName = targetName
        convertMetadata.downloadLane = .optimize
        convertMetadata.resumeMode = .serverPrepThenStatic

        // Snapshot the existing File MediaSources. Used both to (a) reuse an already-converted version
        // instead of re-converting, and (b) identify the freshly-converted source once a new job
        // completes (a second `File` source appears on the same item).
        let fileSources = await embyFileSources(server: server, token: token, identity: identity,
                                                userId: userId, itemId: itemId)
        let snapshotIds = Set(fileSources.compactMap { $0.id })

        // REUSE PREFLIGHT (#126 on the auto-convert path): if a server-prepared converted version that
        // satisfies this preset's output resolution ALREADY exists, download THAT via the resumable
        // `.existingVersion` lane instead of creating another Sync convert job. Without this, every
        // repeat download of the same item piles up duplicate `- tv (N)` conversions in the library —
        // and, worse, Emby's per-item Sync job can then transcode a DERIVED source (a duplicate whose
        // file was since removed surfaces as ffmpeg "No such file" → the job Fails → the row shows
        // "Server conversion failed"). Reusing the kept converted file avoids both.
        let requestedHeight = Self.convertPresetOutputHeight(forLabel: targetName)
        if let reuse = Self.reusableConvertedSource(fileSources, requestedHeight: requestedHeight,
                                                    primaryMediaSourceId: metadata.mediaSourceID),
           let reuseId = reuse.id {
            recordDownloadDiagnostic("downloads.convert_reuse", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "source_count": .int(fileSources.count),
            ])
            // We hold the in-flight slot from `downloadEmby`; release it so the `.existingVersion`
            // handoff re-acquires cleanly (mirrors `finishEmbyConvert`'s post-convert handoff). No
            // `.preparing` row was seeded yet, so there is nothing to remove.
            releaseInFlight(ratingKey: ratingKey)
            await downloadEmby(item, choice: .existingVersion, mediaSourceIDOverride: reuseId)
            return
        }

        // #133 intent: if a prior Emby Sync convert already copied an MP4 next to the original but
        // PlaybackInfo has not exposed it yet, make a bounded, targeted library refresh before
        // starting a duplicate conversion. This is safe/read-only with respect to media bytes: it
        // only asks Emby to re-index this one item, then polls for an existing reusable File source.
        if let refreshedReuse = await refreshAndPollReusableEmbyConvertedSource(
            server: server, token: token, identity: identity, userId: userId, itemId: itemId,
            ratingKey: ratingKey, requestedHeight: requestedHeight,
            primaryMediaSourceId: metadata.mediaSourceID,
            initialSourceCount: fileSources.count,
            phase: "pre_create"),
           let reuseId = refreshedReuse.id {
            recordDownloadDiagnostic("downloads.convert_reuse", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "phase": .label("post_refresh"),
            ])
            releaseInFlight(ratingKey: ratingKey)
            await downloadEmby(item, choice: .existingVersion, mediaSourceIDOverride: reuseId)
            return
        }

        // Persist the FULL pre-conversion id set (not just the original) so a relaunch-resume still
        // excludes any PRIOR converted version — otherwise a stale version could be mistaken for the new one.
        convertMetadata.embyConvertSnapshotIDs = Array(snapshotIds)

        // NOTE: Emby IGNORES the submitted job `name` and stores the item's own title instead
        // (verified live, Emby 4.9.3 — a "<title> [VisionPlay <hex>]" submission comes back stored
        // as just "<title>"). So unlike Plex's `[VisionPlay …]` queue-title marker discipline, an
        // Emby convert job CANNOT be tagged/identified by name. We instead identify and cancel our
        // jobs by the persisted `embyConvertJobID` (set immediately after create, below). The name
        // is still sent (harmless, matches the Emby web client) but is purely cosmetic.
        let jobName = "\(item.title) [VisionPlay \(UUID().uuidString.prefix(8))]"
        let quality = EmbyConvertRequest.convertQuality(forPresetLabel: targetName)

        recordDownloadDiagnostic("downloads.convert_start", fields: [
            "download_id": .identifier(ratingKey),
            "target": .label(targetName),
            "bitrate": .int(quality.bitrate ?? 0),
            "snapshot_count": .int(snapshotIds.count),
        ])

        // Seed the 0% `.preparing` row immediately so the UI shows the job while we create it.
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                    bytes: 0, progress: 0, status: .preparing, metadata: convertMetadata))
        optimizeState[ratingKey] = "queued"
        refreshRecords()

        // 1. Create the convert job.
        let job: EmbyConvertJob
        do {
            let req = try EmbyConvertRequest.createJobRequest(
                server: server, token: token, identity: identity, userId: userId, itemId: itemId,
                quality: quality.quality, profile: quality.profile, bitrate: quality.bitrate,
                name: jobName,
                container: quality.container, videoCodec: quality.videoCodec, audioCodec: quality.audioCodec)
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DownloadError.transferFailed("Convert job HTTP \(http.statusCode)")
            }
            // The CREATE response nests the job under "Job" (SyncJobCreationResult) — decode the
            // envelope, NOT the bare top-level shape the single-job poll GET returns.
            job = try EmbyConvertRequest.decodeCreatedJob(from: data)
        } catch {
            recordDownloadDiagnostic("downloads.convert_failed", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("create"),
                "error": .error(error),
            ])
            failEmbyConvert(ratingKey: ratingKey,
                            (error as? DownloadError) ?? .transferFailed(String(describing: error)))
            return
        }

        // Persist the job id so a relaunch resumes polling (not restarts) and a row delete can
        // cancel the server-side job (`DELETE /Sync/Jobs/{id}`). If the user deleted/cancelled the
        // row while `POST /Sync/Jobs` was in flight, do NOT upsert it back into existence; cancel the
        // server job best-effort and leave the row gone.
        guard activeJobs.contains(ratingKey),
              store.records.first(where: { $0.ratingKey == ratingKey })?.status == .preparing else {
            recordDownloadDiagnostic("downloads.convert_abandoned", fields: [
                "download_id": .identifier(ratingKey),
                "job_id": .int(job.id),
                "phase": .label("post_create"),
            ])
            cancelEmbyConvertJob(jobId: job.id, ratingKey: ratingKey,
                                 server: server, token: token, identity: identity)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
            return
        }
        convertMetadata.embyConvertJobID = job.id
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                    bytes: 0, progress: 0, status: .preparing, metadata: convertMetadata))
        refreshRecords()

        await pollAndDownloadEmbyConvertJob(item: item, ratingKey: ratingKey, jobId: job.id,
                                            snapshotIds: snapshotIds, targetName: targetName,
                                            server: server, token: token, identity: identity,
                                            userId: userId)
    }

    /// Poll an Emby convert job to a terminal state, surfacing `Progress` through the optimize
    /// plumbing ("Preparing on server… N%"), then hand the converted source to the resumable
    /// `.original` lane. Shared by the initial trigger and the relaunch-resume path.
    func pollAndDownloadEmbyConvertJob(item: MediaItem, ratingKey: String, jobId: Int,
                                               snapshotIds: Set<String>, targetName: String,
                                               server: URL, token: String,
                                               identity: EmbyClientIdentity, userId: String) async {
        // 2. Poll (reuse `optimizePollInterval`; no wall-clock timeout — the conversion is
        //    server-side and may legitimately take a long time for large media).
        while true {
            // Bail if the row was deleted/cancelled out from under us (delete() also fires the
            // server-side DELETE /Sync/Jobs).
            guard activeJobs.contains(ratingKey),
                  store.records.first(where: { $0.ratingKey == ratingKey })?.status == .preparing else {
                recordDownloadDiagnostic("downloads.convert_abandoned", fields: [
                    "download_id": .identifier(ratingKey),
                    "job_id": .int(jobId),
                ])
                return
            }

            let job: EmbyConvertJob
            do {
                let req = try EmbyConvertRequest.jobStatusRequest(server: server, token: token,
                                                                  identity: identity, jobId: jobId)
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    if Self.isTerminalEmbyConvertPollStatus(http.statusCode) {
                        recordDownloadDiagnostic("downloads.convert_failed", fields: [
                            "download_id": .identifier(ratingKey),
                            "job_id": .int(jobId),
                            "phase": .label("poll_http"),
                            "status_code": .int(http.statusCode),
                        ])
                        failEmbyConvert(ratingKey: ratingKey,
                                        .transferFailed("Server conversion is no longer available (HTTP \(http.statusCode))."))
                        return
                    }
                    throw DownloadError.transferFailed("Convert poll HTTP \(http.statusCode)")
                }
                job = try EmbyConvertRequest.decodeJob(from: data)
            } catch {
                // A transient poll error shouldn't fail the whole job; keep polling. (The job runs
                // server-side regardless of our connectivity.)
                recordDownloadDiagnostic("downloads.convert_poll_error", fields: [
                    "download_id": .identifier(ratingKey),
                    "job_id": .int(jobId),
                    "error": .error(error),
                ])
                try? await Task.sleep(nanoseconds: UInt64(optimizePollInterval * 1_000_000_000))
                continue
            }

            // Surface progress through the shared optimize plumbing the UI already renders. Emby does
            // NOT report incremental convert progress — `Progress` stays pinned at 0 throughout
            // Converting and only jumps to 100 at completion. So gate on `pct > 0` (NOT `>= 0`): a
            // pinned-0 must leave `optimizeProgress` unset so the UI shows the indeterminate
            // "Preparing on server…" rather than a misleading "Preparing on server… 0%" (and so we
            // never compute a bogus ETA from a non-moving 0). Only a real >0 value drives the %/ETA.
            if let pct = job.progress, pct > 0 {
                let p = min(1.0, pct / 100.0)
                optimizeProgress[ratingKey] = p
                optimizeState[ratingKey] = "transcoding"
                updateOptimizeETA(ratingKey: ratingKey, progress: p)
            } else {
                optimizeState[ratingKey] = "queued"
            }
            refreshRecords()

            if job.status.isTerminal {
                if job.status.didSucceed {
                    // Cancel race: the user may have deleted the row during the status `await` above.
                    // delete() removes the row and releases the in-flight slot; if it did, do NOT
                    // proceed to finishEmbyConvert (which re-seeds a download row and re-inserts the
                    // activeJobs slot, resurrecting a cancelled download). All these methods are
                    // @MainActor, so a plain guard is sufficient — no TOCTOU between this check and
                    // finishEmbyConvert's own top-of-method guard.
                    guard activeJobs.contains(ratingKey) else {
                        recordDownloadDiagnostic("downloads.convert_abandoned", fields: [
                            "download_id": .identifier(ratingKey),
                            "job_id": .int(jobId),
                            "phase": .label("post_status_completed"),
                        ])
                        return
                    }
                    await finishEmbyConvert(item: item, ratingKey: ratingKey, jobId: jobId,
                                            snapshotIds: snapshotIds, targetName: targetName,
                                            server: server, token: token, identity: identity,
                                            userId: userId)
                } else {
                    // Server-side Failed/Cancelled → fail the row (retry-only; keep the marker job
                    // for diagnostics — deleting it wouldn't delete a partial file anyway).
                    recordDownloadDiagnostic("downloads.convert_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "job_id": .int(jobId),
                        "phase": .label("server"),
                        "status": .label(job.status.rawValue),
                    ])
                    failEmbyConvert(ratingKey: ratingKey,
                                    .transferFailed("Server conversion \(job.status.rawValue.lowercased())."))
                }
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(optimizePollInterval * 1_000_000_000))
        }
    }


    /// Terminal failure for an Emby convert-lane row: record the error, mark the row `.failed`
    /// (retryable), and tear down this lane's prep progress + in-flight slot. Centralizes the
    /// finalization that every Emby convert failure site repeated verbatim (#135 Stage 4).
    ///
    /// This lane releases the in-flight slot EXPLICITLY here — deliberately UNLIKE the Plex optimize
    /// lane, which leaves the release to `refreshRecords`'s terminal-row sweep. That asymmetry is
    /// real (the two server-prep lanes have different cancel/teardown semantics) and is preserved by
    /// keeping this helper Emby-local rather than folding both lanes into one shared finalizer.
    /// `clearOptimizeProgress`/`setStatus` are no-ops when no row/progress exists yet, so the
    /// pre-seed `notAuthenticated` site can use this too.
    private func failEmbyConvert(ratingKey: String, _ error: DownloadError) {
        lastError[ratingKey] = error
        store.setStatus(ratingKey: ratingKey, .failed)
        clearOptimizeProgress(ratingKey: ratingKey)
        releaseInFlight(ratingKey: ratingKey)
        refreshRecords()
    }

    private static func isTerminalEmbyConvertPollStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 401, 403, 404, 410:
            return true
        default:
            return false
        }
    }

    private func cancelEmbyConvertJob(jobId: Int, ratingKey: String,
                                      server: URL, token: String,
                                      identity: EmbyClientIdentity) {
        recordDownloadDiagnostic("downloads.convert_cancel", fields: [
            "download_id": .identifier(ratingKey),
            "job_id": .int(jobId),
        ])
        Task {
            if let req = try? EmbyConvertRequest.deleteJobRequest(
                server: server, token: token, identity: identity, jobId: jobId) {
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    /// On a Completed convert job: fetch UNFILTERED PlaybackInfo (`mediaSourceId:nil`), pick the
    /// `File` source NOT in the pre-conversion snapshot (fallback: an h264/mp4 non-primary source),
    /// then hand off to the resumable `.original` static lane via `downloadEmby(…override:)`. The
    /// converted file is KEPT (no Sync-job cleanup) so #126's reuse serves the next download.
    private func finishEmbyConvert(item: MediaItem, ratingKey: String, jobId: Int,
                                   snapshotIds: Set<String>, targetName: String,
                                   server: URL, token: String,
                                   identity: EmbyClientIdentity, userId: String) async {
        // Cancel race (entry guard): bail if the row was deleted/cancelled before we got here.
        guard activeJobs.contains(ratingKey) else {
            recordDownloadDiagnostic("downloads.convert_abandoned", fields: [
                "download_id": .identifier(ratingKey),
                "job_id": .int(jobId),
                "phase": .label("finish_entry"),
            ])
            return
        }
        let itemId = item.ratingKey
        func looksConverted(_ source: EmbyMediaSourceInfo) -> Bool {
            source.videoCodec?.caseInsensitiveCompare("h264") == .orderedSame
                || (source.container ?? "").lowercased().contains("mp4")
        }
        // When several candidates qualify, prefer the most-recently-added so a stale converted
        // version is never chosen over the fresh one. Emby mediasource ids are numeric (string-typed);
        // the freshly converted source gets the highest id. Non-numeric ids sort to the back (-1).
        func recency(_ source: EmbyMediaSourceInfo) -> Int { Int(source.id ?? "") ?? -1 }
        func mostRecent(_ sources: [EmbyMediaSourceInfo]) -> EmbyMediaSourceInfo? {
            sources.max(by: { recency($0) < recency($1) })
        }

        // POLL for the freshly-converted source. Emby reports the Sync job `Completed` BEFORE it has
        // indexed the converted file as a downloadable MediaSource: the file is copied into the
        // library folder, then a LibraryMonitor refresh + ffprobe must run before PlaybackInfo lists
        // it (measured live: ~3 min lag). A single immediate fetch therefore misses it and the row
        // would fail with "Converted source not found". Poll unfiltered PlaybackInfo (best-effort;
        // transient errors just retry) until the NEW (post-snapshot) h264/mp4 `File` source appears.
        let maxAttempts = 72   // ~6 min at the 5s optimizePollInterval — comfortably past the index lag.
        var fileSources: [EmbyMediaSourceInfo] = []
        var newSource: EmbyMediaSourceInfo?
        await requestEmbyItemRefresh(server: server, token: token, identity: identity, userId: userId,
                                     itemId: itemId, ratingKey: ratingKey, phase: "post_completed")
        for attempt in 0..<maxAttempts {
            // Cancel race: the user may delete the row during the wait (delete() also fires the
            // server-side DELETE /Sync/Jobs and releases the slot).
            guard activeJobs.contains(ratingKey) else {
                recordDownloadDiagnostic("downloads.convert_abandoned", fields: [
                    "download_id": .identifier(ratingKey),
                    "job_id": .int(jobId),
                    "phase": .label("finish_poll"),
                ])
                return
            }
            // `embyFileSources` returns only on-disk (`File`) sources with a non-empty id, unfiltered
            // by MediaSourceId, and is best-effort (empty on any error → this attempt simply retries).
            fileSources = await embyFileSources(server: server, token: token, identity: identity,
                                                userId: userId, itemId: itemId)
            let notInSnapshot = fileSources.filter { !snapshotIds.contains($0.id ?? "") }
            // The convert profile always yields h264/mp4, so a NEW h264/mp4 File source is exactly the
            // converted output — never the original HEVC/MKV source.
            if let fresh = mostRecent(notInSnapshot.filter(looksConverted)) {
                newSource = fresh
                break
            }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(optimizePollInterval * 1_000_000_000))
            }
        }
        // Final fallback for an empty/ambiguous snapshot (the strict NEW-h264/mp4 match never landed):
        // most-recent new File source, then most-recent h264/mp4 File source.
        if newSource == nil {
            let notInSnapshot = fileSources.filter { !snapshotIds.contains($0.id ?? "") }
            newSource = mostRecent(notInSnapshot) ?? mostRecent(fileSources.filter(looksConverted))
        }

        guard let newSourceId = newSource?.id, !newSourceId.isEmpty else {
            recordDownloadDiagnostic("downloads.convert_failed", fields: [
                "download_id": .identifier(ratingKey),
                "job_id": .int(jobId),
                "phase": .label("no_converted_source"),
                "source_count": .int(fileSources.count),
            ])
            failEmbyConvert(ratingKey: ratingKey,
                            .transferFailed("Converted source not found after completion."))
            return
        }

        // Cancel race (final guard): the unfiltered PlaybackInfo fetch above is an `await`, so the
        // user could have deleted the row during it. If they did (slot released, row gone), do NOT
        // re-seed a download via the handoff below — that would resurrect a cancelled download.
        guard activeJobs.contains(ratingKey) else {
            recordDownloadDiagnostic("downloads.convert_abandoned", fields: [
                "download_id": .identifier(ratingKey),
                "job_id": .int(jobId),
                "phase": .label("finish_pre_handoff"),
            ])
            return
        }

        recordDownloadDiagnostic("downloads.convert_completed", fields: [
            "download_id": .identifier(ratingKey),
            "job_id": .int(jobId),
            "target": .label(targetName),
        ])
        // Clear the prep progress + release THIS lane's bookkeeping so the handoff `downloadEmby`
        // re-acquires the `activeJobs` slot cleanly and drives the row from 0% on the static lane.
        clearOptimizeProgress(ratingKey: ratingKey)
        releaseInFlight(ratingKey: ratingKey)
        // Remove the seeded `.preparing` row so the handoff re-seeds a fresh download row at the
        // converted source (its own size, route, container).
        store.remove(ratingKey: ratingKey)
        // Hand off to the existing resumable `.original` static lane. `.existingVersion` addresses a
        // specific converted MediaSource id (the #126 byte-for-byte reuse path) — it negotiates the
        // mp4/h264 converted source to `.original` and never re-enters the convert lane (only
        // `.optimize` reroutes). The KEPT converted file is what reuse serves next time.
        await downloadEmby(item, choice: .existingVersion, mediaSourceIDOverride: newSourceId)
    }

    /// Enumerate the current `File` MediaSources for an Emby item (unfiltered PlaybackInfo). Used to
    /// snapshot the pre-conversion sources so the freshly-converted one can be identified later, AND
    /// for the convert-lane reuse preflight (an already-converted version is reused instead of
    /// re-converting). Only on-disk (`Protocol == File`, or absent on older servers) sources with a
    /// non-empty id are returned. Best-effort: empty array on any error.
    private func embyFileSources(server: URL, token: String, identity: EmbyClientIdentity,
                                 userId: String, itemId: String) async -> [EmbyMediaSourceInfo] {
        do {
            let req = try EmbyPlayback.downloadPlaybackInfoRequest(
                server: server, token: token, identity: identity, userId: userId, itemId: itemId,
                mediaSourceId: nil, maxStaticBitrate: 200_000_000)
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return []
            }
            let sources = try EmbyPlaybackInfoResponse.decode(from: data).mediaSources
            return sources.filter { source in
                guard let id = source.id, !id.isEmpty else { return false }
                if let proto = source.mediaProtocol, proto.caseInsensitiveCompare("File") != .orderedSame {
                    return false
                }
                return true
            }
        } catch {
            return []
        }
    }

    /// Ask Emby to re-index one item after a convert job copied a persistent file next to the
    /// original. Best-effort by design: a refresh failure should not fail the download path because
    /// Emby's background library monitor may still discover the file during normal polling.
    private func requestEmbyItemRefresh(server: URL, token: String, identity: EmbyClientIdentity,
                                        userId: String, itemId: String,
                                        ratingKey: String, phase: String) async {
        do {
            let req = try EmbyConvertRequest.itemRefreshRequest(server: server, token: token,
                                                                identity: identity, userId: userId,
                                                                itemId: itemId)
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                recordDownloadDiagnostic("downloads.convert_refresh_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "phase": .label(phase),
                    "status_code": .int(http.statusCode),
                ])
                return
            }
            recordDownloadDiagnostic("downloads.convert_refresh", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label(phase),
            ])
        } catch {
            recordDownloadDiagnostic("downloads.convert_refresh_failed", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label(phase),
                "error": .error(error),
            ])
        }
    }

    /// Bounded #133 reuse probe: refresh one Emby item and poll briefly for an already-optimized
    /// copy before creating a new conversion. This catches the common case where the MP4 exists on
    /// disk but PlaybackInfo is stale; it also makes a resumed server-prep row able to transition to
    /// the static byte-range lane once Emby exposes the copied file.
    private func refreshAndPollReusableEmbyConvertedSource(server: URL, token: String,
                                                           identity: EmbyClientIdentity,
                                                           userId: String, itemId: String,
                                                           ratingKey: String,
                                                           requestedHeight: Int?,
                                                           primaryMediaSourceId: String?,
                                                           initialSourceCount: Int,
                                                           phase: String) async -> EmbyMediaSourceInfo? {
        await requestEmbyItemRefresh(server: server, token: token, identity: identity, userId: userId,
                                     itemId: itemId, ratingKey: ratingKey, phase: phase)

        let maxAttempts = 6 // ~30 seconds at the shared 5s poll cadence; bounded before new convert.
        for attempt in 0..<maxAttempts {
            guard activeJobs.contains(ratingKey) else { return nil }
            let sources = await embyFileSources(server: server, token: token, identity: identity,
                                                userId: userId, itemId: itemId)
            if let reuse = Self.reusableConvertedSource(sources, requestedHeight: requestedHeight,
                                                        primaryMediaSourceId: primaryMediaSourceId) {
                recordDownloadDiagnostic("downloads.convert_reuse_refresh", fields: [
                    "download_id": .identifier(ratingKey),
                    "phase": .label(phase),
                    "attempt": .int(attempt + 1),
                    "initial_source_count": .int(initialSourceCount),
                    "source_count": .int(sources.count),
                ])
                return reuse
            }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(optimizePollInterval * 1_000_000_000))
            }
        }
        return nil
    }

    /// The video height a convert preset is expected to OUTPUT, after the `tv`-profile 1080p cap
    /// (live-verified: 4 Mbps → 720p, 20 Mbps → 1080p, and "4K 40 Mbps" clamps to 1080p). Parsed from
    /// the preset label's leading resolution token. Used by the reuse preflight to decide whether an
    /// already-existing converted version satisfies the request. nil → unknown label (don't reuse;
    /// convert fresh).
    static func convertPresetOutputHeight(forLabel label: String) -> Int? {
        let token = label.split(separator: " ").first.map { $0.lowercased() } ?? ""
        switch token {
        // 4K and "Original" now route through `profile:"custom"` (#128), which preserves the source
        // resolution — they are NO LONGER capped at the `tv` profile's 1080p ceiling. Use 2160 as the
        // high-water tier hint; `reusableConvertedSource` falls back to the most-recent converted
        // sibling when no exact tier matches, so a sub-4K source still reuses correctly.
        case "4k", "2160p": return 2160
        case "1080p":       return 1080
        case "720p":        return 720
        case "480p":        return 480
        default:
            // "Original video quality" — custom-profile, resolution-preserving (#128).
            return label.lowercased().hasPrefix("original") ? 2160 : nil
        }
    }

    /// Pick an already-existing server-prepared (converted) `File` source to REUSE for a convert
    /// request, or nil if none satisfies it. A reusable candidate is a non-primary h264/mp4 File
    /// source (the convert profile's output — never the HEVC/MKV original). Prefer a converted
    /// source whose resolution tier matches the requested preset. For the resolution-capping `tv`
    /// tiers (≤1080p) only, fall back to the most-recent converted source no larger than the
    /// requested tier, because Emby's `tv` profile can produce a non-ladder size (live #133 example:
    /// a "1080p 8 Mbps" Sync copy exposed as 720×404). The custom 4K/Original profile (#128)
    /// preserves source resolution and has no non-ladder case, so it requires an exact tier match
    /// (no fallback) — otherwise a 4K request could silently reuse a stale 1080p convert, or a sub-4K
    /// request could be handed a multi-GB 4K file. Reusing an API-visible converted file is better
    /// than starting a duplicate server conversion; users can still choose specific visible versions
    /// from the picker.
    static func reusableConvertedSource(_ sources: [EmbyMediaSourceInfo],
                                        requestedHeight: Int?,
                                        primaryMediaSourceId: String?) -> EmbyMediaSourceInfo? {
        guard let requestedHeight,
              let wantedTier = resolutionLabel(forHeight: requestedHeight) else { return nil }
        func resolution(_ s: EmbyMediaSourceInfo) -> String? {
            let video = s.mediaStreams.first { $0.type == "Video" }
            return DownloadResolutionLabel.label(width: s.width ?? video?.width,
                                                 height: s.height ?? video?.height)
        }
        // mp4 container = the convert profile's output (`-f mp4`). The pre-conversion original in the
        // convert lane is always HEVC/MKV (an mp4/h264 original would direct-play and never reach this
        // lane), and even an mp4 original is excluded by `primaryMediaSourceId` below — so container
        // alone is a reliable discriminator. We do NOT also require `videoCodec == h264`: PlaybackInfo
        // reports VideoCodec as null at the source level (the codec is in MediaStreams), so an AND
        // would never match a real converted source.
        func looksConverted(_ s: EmbyMediaSourceInfo) -> Bool {
            (s.container ?? "").lowercased().contains("mp4")
        }
        func recency(_ s: EmbyMediaSourceInfo) -> Int { Int(s.id ?? "") ?? -1 }
        let converted = sources.filter { $0.id != primaryMediaSourceId && looksConverted($0) }
        if let exact = converted
            .filter({ resolution($0) == wantedTier })
            .max(by: { recency($0) < recency($1) }) {
            return exact
        }
        // No exact-tier match. Fall back to the most-recent converted sibling ONLY for the
        // resolution-capping `tv` profile tiers (≤1080p), where Emby can emit a non-ladder size
        // SMALLER than the nominal tier (live #133: a "1080p 8 Mbps" copy came back 720×404) — and
        // even then never reuse a source in a HIGHER tier than requested. The custom profile (#128
        // 4K/Original) preserves source resolution and has no non-ladder case, so reusing a smaller/
        // older convert there would silently downgrade a 4K request (deliver 1080p), and a sub-4K
        // request must never be handed back a multi-GB 4K file. For 4K/Original we therefore require
        // the exact tier above and otherwise convert fresh.
        guard requestedHeight <= 1080 else { return nil }
        func tierRank(_ label: String?) -> Int {
            switch label {
            case "4K":    return 4
            case "1080p": return 3
            case "720p":  return 2
            case "480p":  return 1
            default:      return 0   // sub-480 non-ladder (e.g. "720×404") or unknown
            }
        }
        let requestedRank = tierRank(wantedTier)
        return converted
            .filter { tierRank(resolution($0)) <= requestedRank }
            .max { recency($0) < recency($1) }
    }
}
