import Foundation
import PMSKit
import os

// GH #135 Stage 5c: the Plex server-side "Optimize" kickoff/render/queue-management half, split out
// of the DownloadManager god-object into its own file. Behavior-unchanged — the same @MainActor
// methods (an extension of a @MainActor class inherits its isolation), relocated verbatim:
//   triggerOptimizeAndDownload → triggerOptimize (POST the Item[...] optimize grammar) →
//   startOptimizedPartDownload, plus the background-queue hygiene helpers (prioritize / clean stale
//   / unpause) and optimizerSource resolution.
// The metadata-polling half (pollForOptimizedPart / pollOptimizeActivity / the ETA helpers) stays
// in DownloadManager.swift for now and is reached via the now-internal lane services.

extension DownloadManager {

    // MARK: - Optimize path (HIGH UNCERTAINTY — isolated; Phase 0 confirms the contract)

    /// Render a compatible MP4 server-side, poll for the rendered Part, then download it.
    ///
    /// Real contract (python-plexapi `Video.optimize`), implemented to the best-known shape:
    ///   1. GET /playlists?type=42  → read `backgroundProcessing.key` (e.g. /playlists/9/items)
    ///   2. GET /media/processing/targets → resolve the chosen preset NAME to its server
    ///      `targetTagID` (NOT a hardcoded 2/1/3; those are version-specific)
    ///   3. POST {key}  with the Item[...] grammar
    ///   4. poll item metadata for the new Part, then download it (static file, real size).
    ///
    /// // TODO(live, Phase 0): the background-processing key, the targets endpoint/shape, and
    /// the accepted POST grammar are confirmed by `scripts/live-optimize-probe.sh`. Until then
    /// this is the best-known contract and is NOT live-verified. Failures are recorded as
    /// `.optimizeFailed`; we still poll metadata so an out-of-band optimized part is picked up.
    func triggerOptimizeAndDownload(item: MediaItem, targetName: String,
                                            metadata: OfflineMetadata,
                                            session: BackendSession) async {
        let ratingKey = item.ratingKey
        guard let pollerID = beginServerPrepPoller(ratingKey: ratingKey, source: "start") else { return }
        // Audit B.9: run the chain inside a Task registered in `serverPrepPollerTasks` (exactly
        // like the resume path) so a delete's `releaseInFlight` can CANCEL the fresh-start poll
        // loop too. Previously only the resume path stored a handle; a fresh start ran inline
        // with nothing to cancel, so after delete it kept polling the server every ~5s.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runOptimizeAndDownload(item: item, targetName: targetName,
                                              metadata: metadata, session: session,
                                              ratingKey: ratingKey, pollerID: pollerID)
        }
        registerServerPrepPollerTask(task, ratingKey: ratingKey)
        await task.value
        endServerPrepPoller(ratingKey: ratingKey, id: pollerID)
    }

    private func runOptimizeAndDownload(item: MediaItem, targetName: String,
                                        metadata: OfflineMetadata,
                                        session: BackendSession,
                                        ratingKey: String,
                                        pollerID: UUID) async {
        // #84: the whole optimize/poll/download chain runs off the captured Plex session — the
        // server/token come from it, not from any `appModel.active*` re-read.
        let server = session.baseURL
        let token = session.token
        let identity = appModel.identity
        let queueTitle = metadata.optimizeQueueTitle
            ?? "\(item.title) [Labstream \(UUID().uuidString.prefix(8))]"
        var optimizeMetadata = metadata
        optimizeMetadata.optimizeTargetName = targetName
        optimizeMetadata.optimizeQueueTitle = queueTitle
        // The original→optimize fallback chains hand in metadata built for the `.original` lane
        // (`.staticByteRange`). Until the post-fetch rebuild below lands, that stale seed would
        // let a delete-time cancel miss the server-prep job and a crash/relaunch Retry re-download
        // the raw original (sourcePartID is the SOURCE part) that just failed preflight. Stamp the
        // optimize lane/resume class before the first upsert so the whole window is server-prep.
        optimizeMetadata.downloadLane = .optimize
        optimizeMetadata.resumeMode = .serverPrepThenStatic
        recordDownloadDiagnostic("downloads.optimize_start", fields: [
            "download_id": .identifier(ratingKey),
            "target": .label(targetName),
        ])
        // Seed a 0% record so the UI shows the job immediately while we set up the optimize.
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                    bytes: 0, progress: 0, metadata: optimizeMetadata))
        refreshRecords()

        do {
            // Protect this job's queue item from the stale-job cleanup (and any concurrent
            // download's), so cleanup only ever removes abandoned items. CRITICAL: do NOT
            // release this with a `defer` — that fired when this function returned, i.e. right
            // after `session.start` KICKS OFF the URLSession transfer (it does not await the
            // file finishing), leaving the rendered Part unprotected mid-download so a
            // concurrent job's `cleanStaleOptimizeJobs` could delete the very Part being
            // downloaded. Protection is instead released terminally (on `.complete`/`.failed`)
            // via `releaseInFlight`, driven from `refreshRecords`, plus the explicit
            // error-path release below.
            serverPrepAttempts.protectQueueTitle(queueTitle, forRecordKey: ratingKey)
            let sourceItem = await fetchCurrentMediaItem(ratingKey: ratingKey, server: server,
                                                         token: token, identity: identity) ?? item
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: optimizeMetadata,
                                             targetName: targetName)
            let sourceMediaIndex = metadata.mediaIndex ?? 0
            let sourcePartIndex = metadata.partIndex ?? 0
            let refreshedResolutionLabel = DownloadPresetPolicy.displayResolutionLabel(
                choice: .optimize(targetName: targetName),
                chosenMedia: sourceItem.media?[safe: sourceMediaIndex])
            let existingMetadata = records.first { $0.ratingKey == ratingKey }?.metadata
            optimizeMetadata = DownloadOfflineMetadataBuilder.metadata(from: sourceItem,
                                                    resolutionLabel: refreshedResolutionLabel,
                                                    requestedProfileLabel: metadata.requestedProfileLabel,
                                                    mediaIndex: sourceMediaIndex,
                                                    partIndex: sourcePartIndex,
                                                    optimizeTargetName: targetName,
                                                    optimizeQueueTitle: queueTitle,
                                                    session: session)
            optimizeMetadata.posterRelativePath = existingMetadata?.posterRelativePath
            optimizeMetadata.plexBIFRelativePath = existingMetadata?.plexBIFRelativePath
            // #88: carry forward already-cached chapter images so an optimize re-fetch doesn't drop
            // the offline Chapters rail thumbnails.
            optimizeMetadata.chapterImageRelativePaths = existingMetadata?.chapterImageRelativePaths
            optimizeMetadata.optimizeBaselinePartIDs = DownloadOptimizeSourcePolicy.sourcePartIDs(
                item: sourceItem,
                fallbackItem: item,
                mediaIndex: sourceMediaIndex,
                partIndex: sourcePartIndex
            )
            store.upsert(DownloadRecord(ratingKey: ratingKey, title: sourceItem.title,
                                        localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
                                        bytes: 0, progress: 0, metadata: optimizeMetadata))
            refreshRecords()
            cacheChapterImages(ratingKey: ratingKey, item: sourceItem, backend: .plex,
                               server: server, token: token)
            if let sourcePart = sourceItem.media?[safe: sourceMediaIndex]?.part[safe: sourcePartIndex] {
                cachePlexTextSubtitles(ratingKey: ratingKey, part: sourcePart,
                                       server: server, token: token)
            }
            let originalPartIDs = Set(optimizeMetadata.optimizeBaselinePartIDs ?? [])
            guard !originalPartIDs.isEmpty else {
                throw DownloadError.optimizeFailed("No source media parts found before optimize.")
            }
            // Do not silently reuse older Plex Versions for a newly-requested transcode. Existing
            // server-rendered versions may have a lower resolution/bitrate than the user's selected
            // preset (notably Original video quality on a 4K source). If we surface reuse later, it
            // should be an explicit menu item, not an implicit substitute for this request.
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: optimizeMetadata,
                                             targetName: targetName)
            let backgroundProcessingKey = await bgKeyForPolling(server: server,
                                                                       token: token,
                                                                       identity: identity)
            do {
                try await triggerOptimize(item: sourceItem, targetName: targetName,
                                          queueTitle: queueTitle,
                                          server: server, token: token, identity: identity)
            } catch {
                // Do not flash a terminal failed row here. Plex may reject duplicate/odd optimize
                // creates (HTTP 400) while an already-rendered Plex Version is still discoverable
                // from metadata. Keep the visible row in server-prep state and let the metadata/
                // queue polling path decide whether a downloadable Part appears or the server job
                // truly failed.
                recordDownloadDiagnostic("downloads.optimize_create_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(targetName),
                    "error": .error(error),
                ])
            }
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: optimizeMetadata,
                                             targetName: targetName)
            let sourceHeight = sourceItem.media?[safe: sourceMediaIndex]?.height
            let part = try await pollForOptimizedPart(ratingKey: ratingKey,
                                                      originalPartIDs: originalPartIDs,
                                                      targetName: targetName,
                                                      sourceHeight: sourceHeight,
                                                      backgroundProcessingKey: backgroundProcessingKey,
                                                      queueTitle: queueTitle,
                                                      mediaTitle: item.title,
                                                      server: server, token: token,
                                                      identity: identity)
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: optimizeMetadata,
                                             targetName: targetName)
            try startOptimizedPartDownload(ratingKey: ratingKey,
                                           title: item.title,
                                           part: part,
                                           metadata: optimizeMetadata,
                                           server: server,
                                           token: token)
        } catch DownloadLifecycleCancellation.staleOptimizeAttempt {
            recordDownloadDiagnostic("downloads.optimize_stale", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
            ])
        } catch let error as DownloadError {
            guard resumeOptimizePollerIsCurrent(ratingKey: ratingKey, pollerID: pollerID,
                                                phase: "start_error") else { return }
            recordDownloadDiagnostic("downloads.optimize_failed", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "error": .error(error),
            ])
            lastError[ratingKey] = error
            store.setStatus(ratingKey: ratingKey, .failed)
            clearOptimizeProgress(ratingKey: ratingKey)
            refreshRecords()
        } catch is CancellationError {
            // Same stale-poller race as the resume chain: pause/delete already released this
            // attempt, and a quick re-download may own a NEW attempt on this key by now —
            // never strip the new attempt's slot from a superseded chain's handler.
            guard resumeOptimizePollerIsCurrent(ratingKey: ratingKey, pollerID: pollerID,
                                                phase: "start_cancelled") else { return }
            releaseInFlight(ratingKey: ratingKey)
            clearOptimizeProgress(ratingKey: ratingKey)
            refreshRecords()
        } catch {
            guard resumeOptimizePollerIsCurrent(ratingKey: ratingKey, pollerID: pollerID,
                                                phase: "start_error") else { return }
            recordDownloadDiagnostic("downloads.optimize_failed", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "error": .error(error),
            ])
            lastError[ratingKey] = .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer"))
            store.setStatus(ratingKey: ratingKey, .failed)
            clearOptimizeProgress(ratingKey: ratingKey)
            refreshRecords()
        }
    }

    func startOptimizedPartDownload(ratingKey: String,
                                            title: String,
                                            part: Part,
                                            metadata: OfflineMetadata,
                                            server: URL,
                                            token: String) throws {
        let targetName = metadata.optimizeTargetName ?? "unknown"
        let ext = part.container ?? (part.file as NSString?)?.pathExtension ?? "mp4"
        let destination = store.destinationURL(ratingKey: ratingKey,
                                               ext: ext.isEmpty ? "mp4" : ext)
        if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Plex", expectedBytes: part.size) {
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            throw lastError[ratingKey] ?? DownloadError.storageLimitExceeded("Storage limit exceeded.")
        }
        try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                         metadata: metadata,
                                         targetName: targetName)
        var downloadMetadata = metadata
        // Once server prep has handed off to a concrete static Plex Part, retry/relaunch should
        // resume the file bytes with Range rather than restart the optimize workflow. Persist the
        // final Part id as the static retry target.
        downloadMetadata.sourcePartID = part.id
        downloadMetadata.resumeMode = .staticByteRange
        // From here on the transfer is the RENDERED part, so byte-completeness must be judged
        // against ITS size — the enqueue metadata still carries the SOURCE part size, and a
        // transfer that completes via an adopted whole-file 200 never gets a Content-Range total
        // to heal it, which made `demoteIncompleteCompletedStaticRows` fail genuinely complete
        // optimize downloads. (Merge-from-previous restores a nil, so only overwrite with a real
        // size.)
        if let renderedSize = part.size, renderedSize > 0 {
            downloadMetadata.sourcePartSize = renderedSize
        }
        downloadMetadata.serverPreparedVersion = true
        // If the #88 chapter-image cache landed while the Plex optimize job was rendering, preserve
        // it across this final "start the rendered Part" upsert instead of racing it back to nil.
        if downloadMetadata.chapterImageRelativePaths == nil {
            downloadMetadata.chapterImageRelativePaths = store.records.first { $0.ratingKey == ratingKey }?
                .metadata?.chapterImageRelativePaths
        }
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: title,
                                    localURL: destination, bytes: 0, progress: 0,
                                    metadata: downloadMetadata))
        refreshRecords()
        try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                         metadata: downloadMetadata,
                                         targetName: targetName)
        let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
        try startBackgroundTransfer(DownloadTransferStartPlan(
            ratingKey: ratingKey,
            backendLabel: "Plex",
            choiceLabel: "optimize",
            urlShape: url,
            expectedBytes: part.size,
            releaseInFlightOnFailure: false,
            extraDiagnosticFields: [
                "target": .label(targetName),
            ]
        )) {
            // Plex often exposes downloadable text subtitle streams only on the rendered optimized
            // Part, not on the original source Part (where subtitle `key` can be nil). Cache from the
            // exact Part we are downloading so optimized offline playback has the same sidecars.
            cachePlexTextSubtitles(ratingKey: ratingKey, part: part, server: server, token: token)
            // The rendered Part is a static file by this point (the poll waited for it to
            // appear), so a Plex optimize download is usually network-bound — but the server
            // can still be finalizing/serving it as it writes, so mark it transcode-sourced and
            // let `isDownloadTranscodeLimited` decide from the live rate.
            transcodeSourcedDownloads.insert(ratingKey)
            try session.start(ratingKey: ratingKey, from: url, to: destination,
                              expectedBytes: part.size,
                              byteRangeCheckpoint: true,
                              resetRangeRestartCounters: !consumeRangeRestartCounterPreservation(ratingKey: ratingKey))
        }
    }

    /// Ensure an async Plex optimize poller still owns the visible row before it mutates the store
    /// or starts a file transfer.
    ///
    /// This closes the delete/retry race where an old poller survives row deletion, later observes a
    /// completed Plex Part, and overwrites a newer retry's row or downloads to the same destination.
    /// The queue title is the per-attempt identity; the target check catches stale rows from older
    /// builds that may not have a queue-title mapping.
    func assertCurrentOptimizeAttempt(ratingKey: String,
                                              metadata: OfflineMetadata,
                                              targetName: String) throws {
        guard activeJobs.contains(ratingKey) else {
            throw DownloadLifecycleCancellation.staleOptimizeAttempt
        }
        if let queueTitle = metadata.optimizeQueueTitle {
            guard serverPrepAttempts.queueTitle(forRecordKey: ratingKey) == queueTitle else {
                throw DownloadLifecycleCancellation.staleOptimizeAttempt
            }
        }
        guard let current = store.records.first(where: { $0.ratingKey == ratingKey }),
              current.status == .queued,
              current.bytes == 0,
              current.progress == 0 else {
            throw DownloadLifecycleCancellation.staleOptimizeAttempt
        }
        let currentMetadata = current.metadata
        let expectedMode = metadata.resolvedResumeMode(ratingKey: ratingKey)
        if expectedMode == .serverPrepThenStatic {
            guard DownloadRetryPolicy.isPlexServerPrepResumeCandidate(current) else {
                throw DownloadLifecycleCancellation.staleOptimizeAttempt
            }
        } else if currentMetadata?.resolvedResumeMode(ratingKey: ratingKey) != expectedMode {
            throw DownloadLifecycleCancellation.staleOptimizeAttempt
        }
        if let queueTitle = metadata.optimizeQueueTitle,
           currentMetadata?.optimizeQueueTitle != queueTitle {
            throw DownloadLifecycleCancellation.staleOptimizeAttempt
        }
        guard currentMetadata?.optimizeTargetName == targetName else {
            throw DownloadLifecycleCancellation.staleOptimizeAttempt
        }
    }

    /// Steps 1–3 of the optimize contract: fetch the background-processing key, resolve the
    /// target tag id from the server's targets, POST the optimize job. Isolated so the live
    /// (server-specific) path is the only thing Phase 0 needs to confirm.
    func triggerOptimize(item: MediaItem, targetName: String,
                                 queueTitle: String,
                                 server: URL, token: String,
                                 identity: ClientIdentity) async throws {
        // 1. Background-processing playlist key.
        let bgKey: String
        do {
            let pl = try await appModel.client.send(
                OptimizeRequest.backgroundProcessingRequest(server: server, token: token, identity: identity),
                as: BackgroundProcessingPlaylist.self)
            guard let key = pl.key else {
                throw DownloadError.optimizeFailed("No background-processing playlist key.")
            }
            bgKey = key
        } catch let e as DownloadError {
            throw e
        } catch {
            throw DownloadError.optimizeFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error,
                                                              operation: "Background queue lookup"))
        }

        // Clear our own abandoned optimize jobs first so this new one isn't stuck waiting
        // behind a backlog of dead items in the server's background-processing queue.
        await cleanStaleOptimizeJobs(backgroundProcessingKey: bgKey, server: server,
                                     token: token, identity: identity)

        // The real candidate fix: if the server's background conversion queue is idle-PAUSED,
        // queued optimize jobs never run while the user is connected (the queue sits, no
        // `media.download` activity ever appears). Mirror python-plexapi `conversions(pause=False)`
        // and clear it — but only when a read confirms it IS paused (conditional write, so we
        // never needlessly mutate a server that's already fine).
        await unpauseBackgroundQueueIfNeeded(server: server, token: token, identity: identity)

        // 2. Resolve built-in PMS target tags from the server. Custom iPad-style
        //    quality rows intentionally leave targetTagID empty and instead send
        //    Item[Device][profile] + Item[MediaSettings], matching python-plexapi.
        let originalQuality = DownloadPresetPolicy.isPlexOriginalQualityTarget(targetName)
        let custom = originalQuality ? nil : DownloadPresetPolicy.customDownloadProfile(named: targetName)
        let serverTargetName = originalQuality ? DownloadPresetPolicy.plexOriginalQualityTargetName : targetName
        var targetTagID: Int? = custom == nil ? DownloadPresetPolicy.conventionalPlexTagID(forName: serverTargetName) : nil
        if custom == nil,
           let targets = try? await appModel.client.send(
            OptimizeRequest.mediaProcessingTargetsRequest(server: server, token: token, identity: identity),
            as: MediaProcessingTargets.self),
           let resolved = targets.tagID(forName: serverTargetName) {
            targetTagID = resolved
        }

        let source = await optimizerSource(for: item, server: server, token: token, identity: identity)

        // 3. PUT the optimize job to the background-processing playlist.
        let settings = custom?.settings ?? DownloadPresetPolicy.mediaSettings(forTargetName: serverTargetName)
        let create = OptimizeRequest.createOnPlaylist(
            server: server, token: token, identity: identity,
            backgroundProcessingKey: bgKey, ratingKey: item.ratingKey,
            sourceURI: source?.uri, locationID: source?.locationID ?? -1,
            title: queueTitle, targetTagID: targetTagID,
            targetName: custom == nil ? serverTargetName : "Custom: \(custom!.deviceProfile)",
            deviceProfile: custom?.deviceProfile, mediaSettings: settings)
        do {
            try await appModel.client.send(create)
        } catch {
            throw DownloadError.optimizeFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error,
                                                              operation: "Optimize request"))
        }

        // 4. Optionally jump this just-enqueued conversion ahead of the PENDING items (but never
        //    the one currently transcoding). Opt-in via Settings; best-effort — never fails the
        //    download. The optimize POST above must have run first so our item already exists in
        //    the conversion queue when we re-fetch it.
        await prioritizeConversionIfEnabled(ratingKey: item.ratingKey, server: server,
                                            token: token, identity: identity)
    }

    /// When the "Prioritize quick downloads" setting is on, move OUR just-enqueued conversion to
    /// immediately AFTER the active conversion (so it is next up), never displacing the in-flight
    /// transcode — mirroring python-plexapi `Conversion.move(after:)`. If no conversion is active,
    /// move to the front (`after=-1`). Strictly scoped: only acts on the conversion whose
    /// `ratingKey` matches the item we just created; unrelated jobs are never reordered. Any
    /// failure (setting off, perms, shape mismatch, item not found) degrades to a no-op and is
    /// recorded via `downloads.conversion_prioritized`. NEVER throws.
    private func prioritizeConversionIfEnabled(ratingKey: String, server: URL, token: String,
                                               identity: ClientIdentity) async {
        guard PlaybackPreferences.prioritizeQuickDownloads() else {
            recordDownloadDiagnostic("downloads.conversion_prioritized", fields: [
                "download_id": .identifier(ratingKey),
                "moved": .bool(false),
                "reason": .label("disabled"),
            ])
            return
        }

        // Re-fetch the ordered conversion queue so our newly-created item is present.
        guard let queue = try? await appModel.client.send(
            BackgroundQueueRequest.conversionQueueRequest(server: server, token: token, identity: identity),
            as: ConversionQueue.self) else {
            recordDownloadDiagnostic("downloads.conversion_prioritized", fields: [
                "download_id": .identifier(ratingKey),
                "moved": .bool(false),
                "reason": .label("queue_fetch_failed"),
            ])
            return
        }

        let active = queue.activeItem
        let wasActivePresent = active != nil

        // Locate OUR item by ratingKey. Gate hard: only ever reorder this one.
        guard let mine = queue.items.first(where: { $0.ratingKey == ratingKey }),
              let mineItemID = mine.playQueueItemID else {
            recordDownloadDiagnostic("downloads.conversion_prioritized", fields: [
                "download_id": .identifier(ratingKey),
                "moved": .bool(false),
                "was_active_present": .bool(wasActivePresent),
                "queue_count": .int(queue.count),
                "reason": .label("item_not_found"),
            ])
            return
        }

        // If our item IS the active conversion, there is nothing to do — never preempt/restart it.
        if active?.playQueueItemID == mineItemID {
            recordDownloadDiagnostic("downloads.conversion_prioritized", fields: [
                "download_id": .identifier(ratingKey),
                "moved": .bool(false),
                "was_active_present": .bool(wasActivePresent),
                "queue_count": .int(queue.count),
                "reason": .label("already_active"),
            ])
            return
        }

        // Move target: immediately after the active conversion (next up, no preemption); if no
        // active conversion, move to absolute front via python-plexapi's `-1` marker.
        let afterItemID = active?.playQueueItemID ?? "-1"
        let ok = (try? await appModel.client.send(
            BackgroundQueueRequest.moveConversionRequest(
                server: server, token: token, identity: identity,
                playQueueItemID: mineItemID, afterItemID: afterItemID))) != nil

        recordDownloadDiagnostic("downloads.conversion_prioritized", fields: [
            "download_id": .identifier(ratingKey),
            "moved": .bool(ok),
            "was_active_present": .bool(wasActivePresent),
            "queue_count": .int(queue.count),
            "reason": .label(ok ? "moved" : "move_put_failed"),
        ])
    }

    /// Delete this client's abandoned, non-completed items from the server's type-42
    /// background-processing queue. Completed optimize items are server-side artifacts that may
    /// contain the rendered file a relaunched app still needs to discover/download; deleting the
    /// queue item deletes that optimized version in Plex. Scoped hard: only items carrying our
    /// `[Labstream …]` title marker, not currently in-flight (`serverPrepAttempts`), and not in a
    /// completed state are removed — never another client's jobs or completed server renders.
    private func cleanStaleOptimizeJobs(backgroundProcessingKey: String, server: URL,
                                        token: String, identity: ClientIdentity) async {
        let trimmed = backgroundProcessingKey.hasPrefix("/")
            ? String(backgroundProcessingKey.dropFirst()) : backgroundProcessingKey
        let listReq = PlexRequest(url: server.appendingPathComponent(trimmed), method: "GET",
                                  queryItems: [],
                                  headers: PlexHeaders.standard(identity: identity, token: token))
        guard let queue = try? await appModel.client.send(listReq, as: BackgroundProcessingItems.self)
        else {
            recordDownloadDiagnostic("downloads.optimize_queue_cleaned", fields: [
                "queue_items": .int(-1), "fetch": .string("failed"),
            ])
            return
        }
        let marker = "[Labstream "
        let persistedProtectedTitles = Set(records.compactMap { record -> String? in
            guard record.status != .complete else { return nil }
            return record.metadata?.optimizeQueueTitle
        })
        let protectedTitles = serverPrepAttempts.allProtectedQueueTitles.union(persistedProtectedTitles)
        // Server-truth policy: remove only our marked pending/failed clutter. NEVER delete a
        // completed optimized item here — Plex removes the rendered server-side version when the
        // type-42 item is deleted, and a completed item may be the exact Part a relaunched app
        // still needs to discover and download. Also protect persisted queue titles so relaunches
        // do not briefly expose still-valid server work before serverPrepAttempts is rebuilt.
        let stale = queue.staleItemIDs(marker: marker, protectedTitles: protectedTitles)
        var removed = 0
        for id in stale {
            let del = OptimizeRequest.removeBackgroundItem(server: server, token: token,
                                                           identity: identity,
                                                           backgroundProcessingKey: backgroundProcessingKey,
                                                           itemID: id)
            if (try? await appModel.client.send(del)) != nil { removed += 1 }
        }
        // Always record — including the zero-match case — so we can tell "server didn't keep our
        // marker" (marked_count 0 while pending_count high) from "matched but all protected".
        recordDownloadDiagnostic("downloads.optimize_queue_cleaned", fields: [
            "queue_items": .int(queue.items.count),
            "marked_count": .int(queue.markedCount(marker: marker)),
            "pending_count": .int(queue.pendingCount),
            "protected": .int(protectedTitles.count),
            "stale_found": .int(stale.count),
            "removed": .int(removed),
        ])
    }

    /// Delete-time (audit B.9): best-effort removal of ONE optimize job — the type-42 item whose
    /// title is the deleted row's persisted queue title. Unlike `cleanStaleOptimizeJobs` (a broad
    /// sweep that runs only on the NEXT optimize kickoff), this fires immediately when the user
    /// deletes a row still in server prep, so the server stops transcoding work nobody wants.
    /// Same completed-state safety as the sweep: `cancellableItemID` returns nil for a completed
    /// item because deleting it would destroy the rendered server-side version. NEVER throws or
    /// blocks the delete; every outcome is recorded via `downloads.optimize_cancel`.
    func removePlexOptimizeQueueItem(ratingKey: String, queueTitle: String,
                                     server: URL, token: String,
                                     identity: ClientIdentity) async {
        func record(_ removed: Bool, _ reason: String) {
            recordDownloadDiagnostic("downloads.optimize_cancel", fields: [
                "download_id": .identifier(ratingKey),
                "removed": .bool(removed),
                "reason": .label(reason),
            ])
        }
        guard let bgKey = await bgKeyForPolling(server: server, token: token, identity: identity) else {
            record(false, "bg_key_unavailable")
            return
        }
        let trimmed = bgKey.hasPrefix("/") ? String(bgKey.dropFirst()) : bgKey
        let listReq = PlexRequest(url: server.appendingPathComponent(trimmed), method: "GET",
                                  queryItems: [],
                                  headers: PlexHeaders.standard(identity: identity, token: token))
        guard let queue = try? await appModel.client.send(listReq, as: BackgroundProcessingItems.self) else {
            record(false, "queue_fetch_failed")
            return
        }
        guard let itemID = queue.cancellableItemID(queueTitle: queueTitle) else {
            // Not found (already reaped / server dropped the title) or completed (rendered
            // version present — deliberately preserved).
            record(false, "no_cancellable_item")
            return
        }
        let del = OptimizeRequest.removeBackgroundItem(server: server, token: token,
                                                       identity: identity,
                                                       backgroundProcessingKey: bgKey,
                                                       itemID: itemID)
        let ok = (try? await appModel.client.send(del)) != nil
        record(ok, ok ? "removed" : "delete_failed")
    }

    /// If the server's background conversion queue is idle-paused, clear it so queued optimize
    /// jobs actually run. Conditional write: reads `BackgroundQueueIdlePaused` via `GET /:/prefs`
    /// first and only issues the `PUT /:/prefs?BackgroundQueueIdlePaused=0` when it is truthy —
    /// an unknown/absent setting or an already-unpaused queue is left untouched. Mirrors
    /// python-plexapi `PlexServer.conversions(pause=False)`. Emits `downloads.background_queue_unpaused`
    /// only when we actually attempted the toggle (so the human can see was_paused + whether the
    /// PUT succeeded). Best-effort: a failed read or PUT never fails the download.
    private func unpauseBackgroundQueueIfNeeded(server: URL, token: String,
                                                identity: ClientIdentity) async {
        guard let prefs = try? await appModel.client.send(
            BackgroundQueueRequest.prefsRequest(server: server, token: token, identity: identity),
            as: ServerPrefs.self),
              prefs.backgroundQueueIdlePaused == true else {
            return
        }
        let ok = (try? await appModel.client.send(
            BackgroundQueueRequest.setBackgroundQueueIdlePausedRequest(
                server: server, token: token, identity: identity, paused: false))) != nil
        recordDownloadDiagnostic("downloads.background_queue_unpaused", fields: [
            "was_paused": .bool(true),
            "ok": .bool(ok),
        ])
    }

    private struct LibrarySectionsResponse: Decodable {
        struct Container: Decodable {
            let directory: [Directory]
            enum CodingKeys: String, CodingKey { case directory = "Directory" }
        }
        struct Directory: Decodable {
            struct Location: Decodable { let id: Int; let path: String }
            let key: String
            let uuid: String?
            let location: [Location]
            enum CodingKeys: String, CodingKey {
                case key
                case uuid
                case location = "Location"
            }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                key = try container.decode(String.self, forKey: .key)
                uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
                location = try container.decodeIfPresent([Location].self, forKey: .location) ?? []
            }
        }
        let mediaContainer: Container
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    }

    private struct OptimizerSource {
        let uri: String
        let locationID: Int
    }

    private func optimizerSource(for item: MediaItem, server: URL, token: String,
                                 identity: ClientIdentity) async -> OptimizerSource? {
        let sectionID = item.librarySectionID.map(String.init)
            ?? item.librarySectionKey?.split(separator: "/").last.map(String.init)
        guard let sectionID else { return nil }
        let request = PlexRequest(url: server.appendingPathComponent("library/sections"),
                                  method: "GET", queryItems: [],
                                  headers: PlexHeaders.standard(identity: identity, token: token))
        guard let response = try? await appModel.client.send(request, as: LibrarySectionsResponse.self),
              let section = response.mediaContainer.directory.first(where: { $0.key == sectionID }),
              let uuid = section.uuid,
              let metadataKey = item.key ?? Optional("/library/metadata/\(item.ratingKey)")
        else { return nil }

        let sourceFiles = (item.media ?? []).flatMap { $0.part.compactMap(\.file) }
        let libraryLocations = section.location.map { (id: $0.id, path: $0.path) }
        // PlexAPI's `locationID = -1` means "beside the original file". If the library has
        // an extra location (for example a writable optimized-version mount), prefer that so
        // read-only media libraries do not force optimizer failures.
        let alternateLocationID = DownloadOptimizeSourcePolicy.alternateOptimizerLocationID(
            sourceFiles: sourceFiles,
            libraryLocations: libraryLocations)

        return OptimizerSource(uri: "library://\(uuid)/item/\(metadataKey.urlQueryEscapedForPlexPath)",
                               locationID: alternateLocationID ?? -1)
    }
}
