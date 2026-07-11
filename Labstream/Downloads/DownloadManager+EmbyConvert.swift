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

    func recoverAndCancelEmbyConvertTombstone(
        _ tombstone: DownloadStore.EmbyConvertCleanupTombstone,
        server: URL, token: String, identity: EmbyClientIdentity,
        currentUserID: String) async {
        // One recovery per tombstone at a time: overlapping sweeps (pause/retry/backend-ready
        // edges) otherwise duplicate the job-list fetch and race DELETEs for the same job.
        guard !embyCleanupTombstonesInFlight.contains(tombstone.id) else { return }
        embyCleanupTombstonesInFlight.insert(tombstone.id)
        defer { embyCleanupTombstonesInFlight.remove(tombstone.id) }
        let metadata = tombstone.metadata
        guard let baseline = metadata.embyConvertJobBaselineIDs,
              let fingerprint = metadata.embyConvertRecoveryFingerprint,
              let startedAt = metadata.embyConvertRecoveryStartedAtEpochSeconds,
              let phase = metadata.embyConvertRecoveryPhase else { return }
        guard EmbyConvertRecoveryPolicy.publicUserMatches(
            currentSessionUserID: currentUserID,
            persistedBackendUserID: metadata.backendUserID,
            fingerprintUserID: fingerprint.userId) else {
            recordDownloadDiagnostic("downloads.convert_cleanup_deferred", fields: [
                "download_id": .identifier(tombstone.ratingKey),
                "reason": .label("emby_user_mismatch"),
            ])
            return
        }
        do {
            let listRequest = try EmbyConvertRequest.jobListRequest(
                server: server, token: token, identity: identity)
            let (data, response) = try await URLSession.shared.data(for: listRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let list = try EmbyConvertRequest.decodeJobList(from: data)
            // Jobs currently OWNED by live rows are never cancellable by a tombstone: deleting a
            // crash-window row and immediately re-downloading the same item/preset creates a
            // fingerprint-identical job inside the creation window, and without this exclusion
            // the sweep would DELETE the user's active conversion.
            let liveJobIDs = Set(store.records.compactMap { $0.metadata?.embyConvertJobID })
            let cleanupAction = EmbyConvertRecoveryPolicy.cleanupAction(
                baselineJobIDs: Set(baseline), jobs: list.items, listIsComplete: list.isComplete,
                fingerprint: fingerprint, attemptStartedAtEpochSeconds: startedAt, phase: phase,
                nowEpochSeconds: Date().timeIntervalSince1970,
                liveJobIDs: liveJobIDs)
            switch cleanupAction {
            case .retainTombstone:
                return
            case .discardTombstone:
                discardEmbyCleanupTombstone(id: tombstone.id)
                return
            case .cancel(let jobId):
                let deleteRequest = try EmbyConvertRequest.deleteJobRequest(
                    server: server, token: token, identity: identity, jobId: jobId)
                let (_, deleteResponse) = try await URLSession.shared.data(for: deleteRequest)
                guard let deleteHTTP = deleteResponse as? HTTPURLResponse,
                      (200..<300).contains(deleteHTTP.statusCode) || [404, 410].contains(deleteHTTP.statusCode)
                else { return }
                discardEmbyCleanupTombstone(id: tombstone.id)
                recordDownloadDiagnostic("downloads.convert_cleanup_recovered", fields: [
                    "download_id": .identifier(tombstone.ratingKey),
                    "job_id": .int(jobId),
                ])
            }
        } catch {
            // Retain the durable tombstone; a later backend-ready/lifecycle pass retries it.
            recordDownloadDiagnostic("downloads.convert_cleanup_deferred", fields: [
                "download_id": .identifier(tombstone.ratingKey),
            ])
        }
    }

    /// Drop a completed/expired cleanup tombstone from both the durable store queue and the
    /// in-memory deferred queue (tombstones whose persist failed at delete() time live only there).
    func discardEmbyCleanupTombstone(id: UUID) {
        store.removeEmbyConvertCleanupTombstone(id: id)
        deferredEmbyCleanupTombstones.removeAll { $0.id == id }
    }

    func beginEmbyConvertAttempt(ratingKey: String) -> UUID {
        serverPrepAttempts.beginEmbyConvertAttempt(forRecordKey: ratingKey)
    }

    func embyConvertAttemptIsCurrent(ratingKey: String, attemptID: UUID,
                                     targetName: String? = nil, jobId: Int? = nil) -> Bool {
        guard activeJobs.contains(ratingKey),
              serverPrepAttempts.isCurrentEmbyConvertAttempt(forRecordKey: ratingKey, id: attemptID),
              let row = store.records.first(where: { $0.ratingKey == ratingKey }),
              row.status == .preparing else { return false }
        if let targetName, row.metadata?.optimizeTargetName != targetName { return false }
        if let jobId, row.metadata?.embyConvertJobID != jobId { return false }
        return true
    }

    func recordStaleEmbyConvertAttempt(ratingKey: String, phase: String, jobId: Int? = nil) {
        var fields: [String: DiagnosticFieldValue] = [
            "download_id": .identifier(ratingKey),
            "phase": .label(phase),
        ]
        if let jobId { fields["job_id"] = .int(jobId) }
        recordDownloadDiagnostic("downloads.convert_abandoned", fields: fields)
    }

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
                                           session: BackendSession,
                                           audioStreamIndex: Int? = nil) async {
        let itemId = item.ratingKey
        let ratingKey = DownloadRecordIdentity.recordKey(for: itemId, backend: .emby)
        let server = session.baseURL
        let token = session.token
        let identity = appModel.identity.emby
        guard let userId = session.userID else {
            failEmbyConvert(ratingKey: ratingKey, .notAuthenticated)
            return
        }
        let attemptID = beginEmbyConvertAttempt(ratingKey: ratingKey)

        // Carry the convert preset + a `.preparing`-grade metadata snapshot. `optimizeTargetName`
        // doubles as the server-prep marker the UI/resume paths key off (parity with Plex).
        var convertMetadata = metadata
        convertMetadata.optimizeTargetName = targetName
        convertMetadata.downloadLane = .optimize
        convertMetadata.resumeMode = .serverPrepThenStatic

        // Seed a visible `.preparing` row BEFORE the expensive reuse/refresh preflight so the
        // headset UI immediately reflects the accepted tap and subsequent taps see an active row.
        // If we find a reusable converted source below, this temporary server-prep row is removed
        // before handing off to the static `.existingVersion` lane. If the app dies before the
        // Sync job is created, launch reconciliation keeps the row `.preparing` and the resume path
        // fails it as a retryable "conversion did not finish starting" row because it has no job id.
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                    bytes: 0, progress: 0, status: .preparing, metadata: convertMetadata))
        optimizeState[ratingKey] = DownloadOptimizeStateLabel.queued
        refreshRecords()

        // Snapshot the existing File MediaSources. Used both to (a) reuse an already-converted version
        // instead of re-converting, and (b) identify the freshly-converted source once a new job
        // completes (a second `File` source appears on the same item).
        let fileSources = await embyFileSources(server: server, token: token, identity: identity,
                                                userId: userId, itemId: itemId)
        guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                          targetName: targetName) else {
            recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "preflight_sources")
            return
        }
        let snapshotIds = Set(fileSources.compactMap { $0.id })

        // REUSE PREFLIGHT (#126 on the auto-convert path): if a server-prepared converted version that
        // satisfies this preset's output resolution ALREADY exists, download THAT via the resumable
        // `.existingVersion` lane instead of creating another Sync convert job. Without this, every
        // repeat download of the same item piles up duplicate `- tv (N)` conversions in the library —
        // and, worse, Emby's per-item Sync job can then transcode a DERIVED source (a duplicate whose
        // file was since removed surfaces as ffmpeg "No such file" → the job Fails → the row shows
        // "Server conversion failed"). Reusing the kept converted file avoids both.
        let requestedHeight = EmbyConvertedSourcePolicy.presetOutputHeight(forLabel: targetName)
        if let reuse = EmbyConvertedSourcePolicy.reusableSource(fileSources, requestedHeight: requestedHeight,
                                                                primaryMediaSourceID: metadata.mediaSourceID,
                                                                requestedAudioStreamIndex: audioStreamIndex),
           let reuseId = reuse.id {
            recordDownloadDiagnostic("downloads.convert_reuse", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "source_count": .int(fileSources.count),
            ])
            guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                              targetName: targetName) else {
                recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "preflight_reuse")
                return
            }
            // We hold the in-flight slot from `downloadEmby`; release it so the `.existingVersion`
            // handoff re-acquires cleanly (mirrors `finishEmbyConvert`'s post-convert handoff). The
            // Keep the `.preparing` row until the static lane replaces it. Removing first left a
            // process-kill window with no durable row and no way to resume this accepted download.
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(ratingKey: ratingKey)
            await downloadEmby(item, choice: .existingVersion, audioStreamIndex: audioStreamIndex,
                               mediaSourceIDOverride: reuseId,
                               deferStaticStartWhenQueuePaused: true,
                               requestedProfileLabelOverride: metadata.requestedProfileLabel ?? targetName,
                               allowReplacingExistingActiveRow: true)
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
            requestedAudioStreamIndex: audioStreamIndex,
            excludedSourceIds: [],
            initialSourceCount: fileSources.count,
            phase: "pre_create", attemptID: attemptID),
           let reuseId = refreshedReuse.id {
            recordDownloadDiagnostic("downloads.convert_reuse", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "phase": .label("post_refresh"),
            ])
            guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                              targetName: targetName) else {
                recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "post_refresh_reuse")
                return
            }
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(ratingKey: ratingKey)
            await downloadEmby(item, choice: .existingVersion, audioStreamIndex: audioStreamIndex,
                               mediaSourceIDOverride: reuseId,
                               deferStaticStartWhenQueuePaused: true,
                               requestedProfileLabelOverride: metadata.requestedProfileLabel ?? targetName,
                               allowReplacingExistingActiveRow: true)
            return
        }

        guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                          targetName: targetName) else {
            recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "pre_create")
            return
        }
        // Persist the FULL pre-conversion id set (not just the original) so a relaunch-resume still
        // excludes any PRIOR converted version — otherwise a stale version could be mistaken for the new one.
        convertMetadata.embyConvertSnapshotIDs = Array(snapshotIds)

        // NOTE: Emby IGNORES the submitted job `name` and stores the item's own title instead
        // (verified live, Emby 4.9.3 — a "<title> [Labstream <hex>]" submission comes back stored
        // as just "<title>"). So unlike Plex's `[Labstream …]` queue-title marker discipline, an
        // Emby convert job CANNOT be tagged/identified by name. We instead identify and cancel our
        // jobs by the persisted `embyConvertJobID` (set immediately after create, below). The name
        // is still sent (harmless, matches the Emby web client) but is purely cosmetic.
        let jobName = "\(item.title) [Labstream \(UUID().uuidString.prefix(8))]"
        let quality = EmbyConvertRequest.convertQuality(forPresetLabel: targetName)
        let recoveryFingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: itemId, quality: quality.quality, profile: quality.profile, bitrate: quality.bitrate,
            userId: userId, container: quality.container, videoCodec: quality.videoCodec,
            audioCodec: quality.audioCodec, audioStreamIndex: audioStreamIndex)

        // Capture the COMPLETE Sync-job id set before POST. This is the only durable ownership
        // evidence available if the process dies after Emby accepts POST but before we persist its
        // response id; list ordering and the submitted name are both unusable for recovery.
        let jobBaseline: EmbyConvertJobList
        do {
            let req = try EmbyConvertRequest.jobListRequest(
                server: server, token: token, identity: identity)
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DownloadError.transferFailed("Convert baseline HTTP \(http.statusCode)")
            }
            jobBaseline = try EmbyConvertRequest.decodeJobList(from: data)
            guard jobBaseline.isComplete else {
                throw DownloadError.transferFailed("Convert baseline was incomplete")
            }
        } catch {
            guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                              targetName: targetName) else {
                recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "baseline_error")
                return
            }
            recordDownloadDiagnostic("downloads.convert_failed", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("baseline"),
                "error": .error(error),
            ])
            failEmbyConvert(ratingKey: ratingKey,
                            (error as? DownloadError) ?? .transferFailed(
                                DiagnosticRedactor.safeUserFacingErrorMessage(error,
                                                                              operation: "Transfer")))
            return
        }
        guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                          targetName: targetName) else {
            recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "post_baseline")
            return
        }
        convertMetadata.embyConvertJobBaselineIDs = Array(Set(jobBaseline.items.map(\.id))).sorted()
        convertMetadata.embyConvertRecoveryFingerprint = recoveryFingerprint
        convertMetadata.embyConvertRecoveryStartedAtEpochSeconds = Date().timeIntervalSince1970
        convertMetadata.embyConvertRecoveryPhase = .prepared

        recordDownloadDiagnostic("downloads.convert_start", fields: [
            "download_id": .identifier(ratingKey),
            "target": .label(targetName),
            "bitrate": .int(quality.bitrate ?? 0),
            "snapshot_count": .int(snapshotIds.count),
            "job_baseline_count": .int(jobBaseline.items.count),
        ])

        // Refresh the visible `.preparing` row with the full pre-conversion snapshot before creating
        // the server job.
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                    bytes: 0, progress: 0, status: .preparing, metadata: convertMetadata))
        refreshRecords()

        // 1. Create the convert job.
        let job: EmbyConvertJob
        var postWasDispatched = false
        var createHTTPStatus: Int?
        do {
            let req = try EmbyConvertRequest.createJobRequest(
                server: server, token: token, identity: identity, userId: userId, itemId: itemId,
                quality: quality.quality, profile: quality.profile, bitrate: quality.bitrate,
                name: jobName,
                container: quality.container, videoCodec: quality.videoCodec, audioCodec: quality.audioCodec,
                audioStreamIndex: audioStreamIndex)
            // Persist dispatch ambiguity BEFORE handing POST to URLSession. A kill after this point
            // must recover by bounded list identity; `.prepared` rows can never adopt a job.
            convertMetadata.embyConvertRecoveryPhase = .dispatchAmbiguous
            store.upsert(DownloadRecord(
                ratingKey: ratingKey, title: item.title,
                localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                bytes: 0, progress: 0, status: .preparing, metadata: convertMetadata))
            refreshRecords()
            postWasDispatched = true
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                createHTTPStatus = http.statusCode
                if !(200..<300).contains(http.statusCode) {
                    throw DownloadError.transferFailed("Convert job HTTP \(http.statusCode)")
                }
            }
            // The CREATE response nests the job under "Job" (SyncJobCreationResult) — decode the
            // envelope, NOT the bare top-level shape the single-job poll GET returns.
            job = try EmbyConvertRequest.decodeCreatedJob(from: data)
        } catch {
            guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                              targetName: targetName) else {
                recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "create_error")
                return
            }
            recordDownloadDiagnostic("downloads.convert_failed", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("create"),
                "error": .error(error),
            ])
            if EmbyConvertRecoveryPolicy.createFailureDisposition(
                postWasDispatched: postWasDispatched,
                httpStatusCode: createHTTPStatus) == .clearRecovery {
                store.clearEmbyConvertRecovery(ratingKey: ratingKey)
            }
            failEmbyConvert(ratingKey: ratingKey,
                            (error as? DownloadError) ?? .transferFailed(
                                DiagnosticRedactor.safeUserFacingErrorMessage(error,
                                                                              operation: "Transfer")))
            return
        }

        // Persist the job id so a relaunch resumes polling (not restarts) and a row delete can
        // cancel the server-side job (`DELETE /Sync/Jobs/{id}`). If the user deleted/cancelled the
        // row while `POST /Sync/Jobs` was in flight, do NOT upsert it back into existence; cancel the
        // server job best-effort and leave the row gone.
        guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                          targetName: targetName) else {
            recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "post_create", jobId: job.id)
            cancelEmbyConvertJob(jobId: job.id, ratingKey: ratingKey,
                                 server: server, token: token, identity: identity)
            refreshRecords()
            return
        }
        convertMetadata.adoptEmbyConvertJobID(job.id)
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                    bytes: 0, progress: 0, status: .preparing, metadata: convertMetadata))
        refreshRecords()

        await pollAndDownloadEmbyConvertJob(item: item, ratingKey: ratingKey, jobId: job.id,
                                            snapshotIds: snapshotIds, targetName: targetName,
                                            server: server, token: token, identity: identity,
                                            userId: userId, audioStreamIndex: audioStreamIndex,
                                            attemptID: attemptID)
    }

    /// Recover the narrow POST-accepted / response-id-not-persisted crash window. No heuristic
    /// fallback is allowed: only one exact new job relative to the durable full baseline is adopted.
    func recoverAndResumeEmbyConvertJob(item: MediaItem, ratingKey: String,
                                        baselineJobIDs: Set<Int>,
                                        fingerprint: EmbyConvertRecoveryPolicy.Fingerprint,
                                        attemptStartedAtEpochSeconds: Double,
                                        recoveryPhase: EmbyConvertRecoveryPolicy.Phase,
                                        snapshotIds: Set<String>, targetName: String,
                                        server: URL, token: String,
                                        identity: EmbyClientIdentity, userId: String,
                                        audioStreamIndex: Int?, attemptID: UUID) async {
        let list: EmbyConvertJobList
        do {
            let req = try EmbyConvertRequest.jobListRequest(
                server: server, token: token, identity: identity)
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DownloadError.transferFailed("Convert recovery HTTP \(http.statusCode)")
            }
            list = try EmbyConvertRequest.decodeJobList(from: data)
            guard list.isComplete else {
                throw DownloadError.transferFailed("Convert recovery list was incomplete")
            }
        } catch {
            guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                              targetName: targetName) else {
                recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "recovery_list_error")
                return
            }
            recordDownloadDiagnostic("downloads.convert_failed", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("recovery_list"),
                "error": .error(error),
            ])
            failEmbyConvert(ratingKey: ratingKey,
                            .transferFailed("Server conversion could not be recovered safely; retry."))
            return
        }

        guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                          targetName: targetName) else {
            recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "post_recovery_list")
            return
        }
        let matchingIDs = EmbyConvertRecoveryPolicy.matchingNewJobIDs(
            baselineJobIDs: baselineJobIDs, jobs: list.items, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: attemptStartedAtEpochSeconds,
            phase: recoveryPhase)
        guard matchingIDs.count == 1, let jobId = matchingIDs.first else {
            recordDownloadDiagnostic("downloads.convert_failed", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("recovery_ambiguous"),
                "candidate_count": .int(matchingIDs.count),
                "baseline_count": .int(baselineJobIDs.count),
            ])
            failEmbyConvert(ratingKey: ratingKey,
                            .transferFailed("Server conversion could not be identified safely; retry."))
            return
        }

        // Persist ownership BEFORE polling or publishing recovery. A second kill after this upsert
        // follows the ordinary job-id resume path and can safely cancel this exact job on delete.
        guard var row = store.records.first(where: { $0.ratingKey == ratingKey }),
              var metadata = row.metadata,
              metadata.embyConvertJobID == nil else {
            recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "recovery_persist", jobId: jobId)
            return
        }
        metadata.adoptEmbyConvertJobID(jobId)
        row.metadata = metadata
        store.upsert(row)
        refreshRecords()
        recordDownloadDiagnostic("downloads.convert_resume", fields: [
            "download_id": .identifier(ratingKey),
            "job_id": .int(jobId),
            "recovered": .bool(true),
        ])

        await pollAndDownloadEmbyConvertJob(
            item: item, ratingKey: ratingKey, jobId: jobId, snapshotIds: snapshotIds,
            targetName: targetName, server: server, token: token, identity: identity,
            userId: userId, audioStreamIndex: audioStreamIndex, attemptID: attemptID)
    }

    /// Poll an Emby convert job to a terminal state, surfacing `Progress` through the optimize
    /// plumbing ("Preparing on server… N%"), then hand the converted source to the resumable
    /// `.original` lane. Shared by the initial trigger and the relaunch-resume path.
    func pollAndDownloadEmbyConvertJob(item: MediaItem, ratingKey: String, jobId: Int,
                                               snapshotIds: Set<String>, targetName: String,
                                               server: URL, token: String,
                                               identity: EmbyClientIdentity, userId: String,
                                               audioStreamIndex: Int? = nil,
                                               attemptID: UUID) async {
        // Relaunch/resume recovery: the Sync job can be effectively done (or even no longer useful
        // to poll) while Emby has already exposed the converted MP4 as a File MediaSource. Check for
        // that reusable server-prepared source before entering the long job-status loop so rows that
        // were at "Preparing on server… 100%" do not sit there until the user retries manually.
        let requestedHeight = EmbyConvertedSourcePolicy.presetOutputHeight(forLabel: targetName)
        let primaryMediaSourceId: String?
        if let id = item.media?.first?.id {
            primaryMediaSourceId = String(id)
        } else {
            primaryMediaSourceId = nil
        }
        let resumedReusableSource = await refreshAndPollReusableEmbyConvertedSource(
            server: server, token: token, identity: identity, userId: userId, itemId: item.ratingKey,
            ratingKey: ratingKey, requestedHeight: requestedHeight,
            primaryMediaSourceId: primaryMediaSourceId,
            requestedAudioStreamIndex: audioStreamIndex,
            excludedSourceIds: snapshotIds,
            initialSourceCount: snapshotIds.count,
            phase: "resume_pre_poll", attemptID: attemptID)
        if let reuseId = resumedReusableSource?.id,
           embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                       targetName: targetName, jobId: jobId) {
            recordDownloadDiagnostic("downloads.convert_reuse", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "phase": .label("resume_pre_poll"),
            ])
            // If THIS attempt's job is still Converting it would otherwise render to completion
            // server-side as a duplicate version. Cancel it first:
            // DELETE /Sync/Jobs/{id} never deletes an already-converted file, so this is safe
            // even when the reused source IS this job's own finished output.
            cancelEmbyConvertJob(jobId: jobId, ratingKey: ratingKey,
                                 server: server, token: token, identity: identity)
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(ratingKey: ratingKey)
            let requestedProfileLabel = records.first { $0.ratingKey == ratingKey }?
                .metadata?.requestedProfileLabel ?? targetName
            await downloadEmby(item, choice: .existingVersion, audioStreamIndex: audioStreamIndex,
                               mediaSourceIDOverride: reuseId,
                               deferStaticStartWhenQueuePaused: true,
                               requestedProfileLabelOverride: requestedProfileLabel,
                               allowReplacingExistingActiveRow: true)
            return
        }

        // 2. Poll (reuse `optimizePollInterval`). A healthy conversion may legitimately take
        // hours, so render duration is unbounded; only a consecutive run of unreachable/5xx/
        // undecodable status responses is budgeted by `EmbyConvertPollHealthPolicy`.
        var pollHealth = EmbyConvertPollHealthPolicy.State()
        while true {
            // Bail if the row was deleted/cancelled out from under us (delete() also fires the
            // server-side DELETE /Sync/Jobs).
            guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                                  targetName: targetName, jobId: jobId) else {
                recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "poll", jobId: jobId)
                return
            }

            let job: EmbyConvertJob
            do {
                let req = try EmbyConvertRequest.jobStatusRequest(server: server, token: token,
                                                                  identity: identity, jobId: jobId)
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    if Self.isTerminalEmbyConvertPollStatus(http.statusCode) {
                        // Lens 6 F4: the status GET above is an await — the row can have been
                        // deleted/retried during it. Mirror the didSucceed guard: a STALE chain
                        // must never `failEmbyConvert` (that bricks a fresh re-download with the
                        // old job's error and strips its in-flight slot).
                        guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                                          targetName: targetName, jobId: jobId) else {
                            recordStaleEmbyConvertAttempt(ratingKey: ratingKey,
                                                          phase: "poll_http_stale", jobId: jobId)
                            return
                        }
                        recordDownloadDiagnostic("downloads.convert_failed", fields: [
                            "download_id": .identifier(ratingKey),
                            "job_id": .int(jobId),
                            "phase": .label("poll_http"),
                            "status_code": .int(http.statusCode),
                        ])
                        // 404/410 proves the job no longer exists: clear the id so Retry creates a
                        // fresh job instead of re-polling a dead one forever. 401/403 is an AUTH
                        // problem — keep the id so re-login + Retry resumes polling the live job.
                        if [404, 410].contains(http.statusCode) {
                            store.clearEmbyConvertJobID(ratingKey: ratingKey)
                        }
                        failEmbyConvert(ratingKey: ratingKey,
                                        .transferFailed("Server conversion is no longer available (HTTP \(http.statusCode))."))
                        return
                    }
                    throw DownloadError.transferFailed("Convert poll HTTP \(http.statusCode)")
                }
                job = try EmbyConvertRequest.decodeJob(from: data)
            } catch {
                let healthAction = EmbyConvertPollHealthPolicy.registerFailure(state: &pollHealth)
                // A transient poll error shouldn't fail the whole job; keep polling while the
                // consecutive budget remains. The job runs server-side regardless of connectivity.
                recordDownloadDiagnostic("downloads.convert_poll_error", fields: [
                    "download_id": .identifier(ratingKey),
                    "job_id": .int(jobId),
                    "consecutive_failures": .int(pollHealth.consecutiveFailures),
                    "error": .error(error),
                ])
                if healthAction == .failPersistent {
                    guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                                      targetName: targetName, jobId: jobId) else {
                        recordStaleEmbyConvertAttempt(ratingKey: ratingKey,
                                                      phase: "poll_unreachable_stale", jobId: jobId)
                        return
                    }
                    recordDownloadDiagnostic("downloads.convert_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "job_id": .int(jobId),
                        "phase": .label("poll_unreachable"),
                        "consecutive_failures": .int(pollHealth.consecutiveFailures),
                    ])
                    failEmbyConvert(ratingKey: ratingKey,
                                    .transferFailed("Server conversion status stayed unreachable. Retry to continue."))
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(optimizePollInterval * 1_000_000_000))
                continue
            }
            EmbyConvertPollHealthPolicy.registerSuccess(state: &pollHealth)

            // Lens 6 F4/F6: the status fetch above is an await. Re-check attempt currency BEFORE
            // publishing progress or acting on a terminal status, so one poll-cycle of latency
            // cannot re-plant stale prep progress after a delete, and a stale chain never reaches
            // the Failed/Cancelled `failEmbyConvert` below (its success sibling was already
            // guarded; the failure branch was not).
            guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                              targetName: targetName, jobId: jobId) else {
                recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "post_status", jobId: jobId)
                return
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
                optimizeState[ratingKey] = p >= 1.0
                    ? DownloadOptimizeStateLabel.finalizing
                    : DownloadOptimizeStateLabel.transcoding
                updateOptimizeETA(ratingKey: ratingKey, progress: p)
            } else {
                optimizeState[ratingKey] = DownloadOptimizeStateLabel.queued
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
                    guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                                          targetName: targetName, jobId: jobId) else {
                        recordStaleEmbyConvertAttempt(ratingKey: ratingKey,
                                                      phase: "post_status_completed", jobId: jobId)
                        return
                    }
                    markServerPrepFinalizing(ratingKey: ratingKey)
                    refreshRecords()
                    await finishEmbyConvert(item: item, ratingKey: ratingKey, jobId: jobId,
                                            snapshotIds: snapshotIds, targetName: targetName,
                                            server: server, token: token, identity: identity,
                                            userId: userId, audioStreamIndex: audioStreamIndex,
                                            attemptID: attemptID)
                } else {
                    // Server-side Failed/Cancelled → fail the row (retry-only; the server job
                    // itself is left alone — deleting it wouldn't delete a partial file anyway).
                    recordDownloadDiagnostic("downloads.convert_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "job_id": .int(jobId),
                        "phase": .label("server"),
                        "status": .label(job.status.rawValue),
                    ])
                    // The job reached a terminal state: clear the persisted id so Retry creates a
                    // fresh job. A `.failed` row that keeps its id resumes POLLING on retry (the
                    // offline-recovery path), which for a terminal job would just re-fail forever.
                    store.clearEmbyConvertJobID(ratingKey: ratingKey)
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
        // Do not blanket-clear the pre-POST baseline/fingerprint here. An ambiguous dispatched
        // POST or a zero/multiple/list-error recovery must retain ownership evidence so Relaunch/
        // Retry re-enters recovery rather than creating and orphaning another server job. The
        // definitive pre-dispatch/non-2xx create branch clears explicitly; exact adoption clears
        // atomically with persisting the recovered job id.
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
                                   identity: EmbyClientIdentity, userId: String,
                                   audioStreamIndex: Int?,
                                   attemptID: UUID) async {
        // Cancel race (entry guard): bail if the row was deleted/cancelled before we got here.
        guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                          targetName: targetName, jobId: jobId) else {
            recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "finish_entry", jobId: jobId)
            return
        }
        let itemId = item.ratingKey

        // POLL for the freshly-converted source. Emby reports the Sync job `Completed` BEFORE it has
        // indexed the converted file as a downloadable MediaSource: the file is copied into the
        // library folder, then a LibraryMonitor refresh + ffprobe must run before PlaybackInfo lists
        // it (measured live: ~3 min lag). A single immediate fetch therefore misses it and the row
        // would fail with "Converted source not found". Poll unfiltered PlaybackInfo (best-effort;
        // transient errors just retry) until the NEW (post-snapshot) h264/mp4 `File` source appears.
        let maxAttempts = 72   // ~6 min at the 5s optimizePollInterval — comfortably past the index lag.
        var fileSources: [EmbyMediaSourceInfo] = []
        var newSource: EmbyMediaSourceInfo?
        // Tier facts for the pickup sanity gate: a source with known dimensions far below what this
        // job could have rendered is a foreign sibling, not our output.
        let requestedHeight = EmbyConvertedSourcePolicy.presetOutputHeight(forLabel: targetName)
        let primaryMediaSourceId = (item.media?.first?.id).map(String.init)
        markServerPrepFinalizing(ratingKey: ratingKey)
        recordDownloadDiagnostic("downloads.convert_finalizing", fields: [
            "download_id": .identifier(ratingKey),
            "job_id": .int(jobId),
            "max_attempts": .int(maxAttempts),
        ])
        refreshRecords()
        await requestEmbyItemRefresh(server: server, token: token, identity: identity, userId: userId,
                                     itemId: itemId, ratingKey: ratingKey, phase: "post_completed")
        for attempt in 0..<maxAttempts {
            // Cancel race: the user may delete the row during the wait (delete() also fires the
            // server-side DELETE /Sync/Jobs and releases the slot).
            guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                                  targetName: targetName, jobId: jobId) else {
                recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "finish_poll", jobId: jobId)
                return
            }
            // `embyFileSources` returns only on-disk (`File`) sources with a non-empty id, unfiltered
            // by MediaSourceId, and is best-effort (empty on any error → this attempt simply retries).
            fileSources = await embyFileSources(server: server, token: token, identity: identity,
                                                userId: userId, itemId: itemId)
            // The convert profile always yields h264/mp4, so a NEW h264/mp4 File source is exactly the
            // converted output — never the original HEVC/MKV source.
            if let fresh = EmbyConvertedSourcePolicy.newConvertedSource(fileSources,
                                                                        excludingSnapshotIDs: snapshotIds,
                                                                        requestedHeight: requestedHeight,
                                                                        primaryMediaSourceID: primaryMediaSourceId) {
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
            newSource = EmbyConvertedSourcePolicy.completedSourceFallback(fileSources,
                                                                          excludingSnapshotIDs: snapshotIds,
                                                                          requestedHeight: requestedHeight,
                                                                          primaryMediaSourceID: primaryMediaSourceId)
        }

        guard let newSourceId = newSource?.id, !newSourceId.isEmpty else {
            // Lens 6 F4: the source polling above awaited repeatedly; the last iteration's fetch
            // has no guard between it and this failure branch. Mirror the didSucceed guard —
            // stale → record + return, never `failEmbyConvert`.
            guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                              targetName: targetName, jobId: jobId) else {
                recordStaleEmbyConvertAttempt(ratingKey: ratingKey,
                                              phase: "no_converted_source_stale", jobId: jobId)
                return
            }
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
        guard embyConvertAttemptIsCurrent(ratingKey: ratingKey, attemptID: attemptID,
                                          targetName: targetName, jobId: jobId) else {
            recordStaleEmbyConvertAttempt(ratingKey: ratingKey, phase: "finish_pre_handoff", jobId: jobId)
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
        let requestedProfileLabel = records.first { $0.ratingKey == ratingKey }?
            .metadata?.requestedProfileLabel ?? targetName
        // Keep the seeded `.preparing` row until the static handoff atomically replaces it. A crash
        // here can then resume the completed job/source lookup instead of losing the download.
        // Hand off to the existing resumable `.original` static lane. `.existingVersion` addresses a
        // specific converted MediaSource id (the #126 byte-for-byte reuse path) — it negotiates the
        // mp4/h264 converted source to `.original` and never re-enters the convert lane (only
        // `.optimize` reroutes). The KEPT converted file is what reuse serves next time.
        await downloadEmby(item, choice: .existingVersion, audioStreamIndex: audioStreamIndex,
                           mediaSourceIDOverride: newSourceId,
                           deferStaticStartWhenQueuePaused: true,
                           requestedProfileLabelOverride: requestedProfileLabel,
                           allowReplacingExistingActiveRow: true)
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
            return EmbyConvertedSourcePolicy.fileSources(sources)
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
                                                           requestedAudioStreamIndex: Int? = nil,
                                                           excludedSourceIds: Set<String>,
                                                           initialSourceCount: Int,
                                                           phase: String,
                                                           attemptID: UUID) async -> EmbyMediaSourceInfo? {
        await requestEmbyItemRefresh(server: server, token: token, identity: identity, userId: userId,
                                     itemId: itemId, ratingKey: ratingKey, phase: phase)

        let maxAttempts = 6 // ~30 seconds at the shared 5s poll cadence; bounded before new convert.
        var lastSourceCount = 0
        for attempt in 0..<maxAttempts {
            guard serverPrepAttempts.isCurrentEmbyConvertAttempt(forRecordKey: ratingKey, id: attemptID),
                  activeJobs.contains(ratingKey) else { return nil }
            let sources = await embyFileSources(server: server, token: token, identity: identity,
                                                userId: userId, itemId: itemId)
            lastSourceCount = sources.count
            let eligibleSources = sources.filter { source in
                guard !excludedSourceIds.isEmpty else { return true }
                guard let id = source.id, !id.isEmpty else { return true }
                return !excludedSourceIds.contains(id)
            }
            if let reuse = EmbyConvertedSourcePolicy.reusableSource(eligibleSources, requestedHeight: requestedHeight,
                                                                    primaryMediaSourceID: primaryMediaSourceId,
                                                                    requestedAudioStreamIndex: requestedAudioStreamIndex) {
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
        recordDownloadDiagnostic("downloads.convert_reuse_refresh_miss", fields: [
            "download_id": .identifier(ratingKey),
            "phase": .label(phase),
            "initial_source_count": .int(initialSourceCount),
            "source_count": .int(lastSourceCount),
            "requested_height": .int(requestedHeight ?? -1),
        ])
        return nil
    }

}
