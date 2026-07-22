import Foundation
import PMSKit
import AVFoundation
import os

// GH #135 Stage 5c: the Plex download ENTRY POINT, split out of the DownloadManager god-object into
// its own file — completing the per-backend symmetry (+Plex / +Emby / +Jellyfin entries, with
// +PlexOptimize / +EmbyConvert holding the server-prep halves). Behavior-unchanged — the same
// @MainActor methods (an extension of a @MainActor class inherits its isolation), relocated verbatim:
// download() routes the sheet's choice (.original byte-for-byte after an AVPlayer preflight,
// .existingVersion static, .optimize/.optimizeCompatible → the optimize lane), startStaticPlexPartDownload
// kicks off the static transfer, and preflightOriginalPlayback is the second-stage direct-play gate.

extension DownloadManager {

    /// Probe-driven download entry point (offline-download redesign). `choice` comes from the
    /// sheet, which already ran the direct-play probe: `.original` direct-downloads the source
    /// file; `.optimize` renders a compatible MP4 server-side then downloads it. Both converge
    /// on the same background-`URLSession` + validation pipeline. Records state rather than
    /// throwing.
    public func download(_ item: MediaItem, choice: DownloadChoice,
                         mediaIndex: Int = 0,
                         partIndex: Int = 0,
                         audioStreamIndex: Int? = nil,
                         allowReplacingExistingActiveRow: Bool = false) async {
        let ratingKey = item.ratingKey
        // #84: resolve the Plex session ONCE from its own lane (never `appModel.activeBackend`),
        // then never re-read a per-lane credential field for the rest of this job.
        // (Named `backendSession` to avoid shadowing the instance `session` URLSession wrapper.)
        guard let backendSession = appModel.backendSession(for: .plex) else {
            recordDownloadDiagnostic("downloads.enqueue_failed", fields: [
                "backend": .label("Plex"),
                "reason": .label("not_authenticated"),
            ])
            lastError[ratingKey] = .notAuthenticated
            return
        }
        let token = backendSession.token
        let server = backendSession.baseURL
        guard let startAttempt = acquireStartAttempt(ratingKey: ratingKey,
                                                     backend: "Plex",
                                                     allowReplacingExistingActiveRow: allowReplacingExistingActiveRow) else { return }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey,
                                            attemptID: startAttempt.attemptID)
        lastError[ratingKey] = nil
        // NOTE: no `defer { activeJobs.remove }` here — that fired when this function returned,
        // which (for both choices) is right after `session.start` merely KICKS OFF the transfer,
        // dropping in-flight protection while the file was still downloading. The protection is
        // now released terminally from `refreshRecords` (on `.complete`/`.failed`) and explicitly
        // on the exit paths below that never start a transfer.

        if case .optimize = choice,
           rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Plex",
                                    expectedBytes: estimatedBytes(for: item, choice: choice,
                                                                  mediaIndex: mediaIndex,
                                                                  partIndex: partIndex,
                                                                  backend: .plex)) {
            releaseInFlight(for: attemptKey)
            return
        }

        let chosenMedia = item.media?[safe: mediaIndex]
        let resolutionLabel = DownloadPresetPolicy.displayResolutionLabel(choice: choice, chosenMedia: chosenMedia)
        let optimizeTargetName: String?
        if case .optimize(let targetName) = choice {
            optimizeTargetName = targetName
        } else {
            optimizeTargetName = nil
        }
        let metadata = DownloadOfflineMetadataBuilder.metadata(from: item, resolutionLabel: resolutionLabel,
                                            requestedProfileLabel: DownloadChoicePolicy.requestedProfileLabel(for: choice),
                                            mediaIndex: mediaIndex, partIndex: partIndex,
                                            optimizeTargetName: optimizeTargetName,
                                            session: backendSession,
                                            audioStreamIndex: audioStreamIndex,
                                            downloadLane: DownloadChoicePolicy.downloadLane(for: choice),
                                            serverPreparedVersion: DownloadChoicePolicy.isServerPreparedVersion(for: choice))
        let seedDestination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        guard persistAttemptSeed(
            DownloadRecord(ratingKey: ratingKey, attemptID: startAttempt.attemptID,
                           title: item.title, localURL: seedDestination,
                           bytes: 0, progress: 0, metadata: metadata),
            for: startAttempt,
            backend: "Plex"
        ) else {
            releaseInFlight(for: attemptKey)
            return
        }
        recordDownloadDiagnostic("downloads.enqueue", fields: downloadDiagnosticFields(
            item: item,
            choice: choice,
            backend: "Plex",
            backendKind: .plex,
            mediaIndex: mediaIndex,
            partIndex: partIndex
        ))
        // D5/#102: cache poster-shaped artwork locally so artwork shows offline. Episodes
        // often expose a landscape still as `thumb`, which looks wrong in the Offline tab's
        // small portrait tile; prefer the show/season poster when TV hierarchy provides it.
        cachePoster(for: attemptKey, thumb: DownloadSideAssetPolicy.offlinePosterRef(for: item),
                    server: server, token: token)
        cachePlexBIF(for: attemptKey, item: item, mediaIndex: mediaIndex,
                     server: server, token: token)

        let staticPart = chosenMedia?.part[safe: partIndex]
        let initialRoute = PlexDownloadRouter.initialRoute(
            intent: PlexDownloadRouter.intent(for: choice),
            hasPart: staticPart != nil,
            compatibleFallbackTarget: Self.originalFallbackOptimizeTarget()
        )
        switch initialRoute {
        case .missingPart(let reason):
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Plex"),
                "reason": .label(reason.rawValue),
            ])
            switch reason {
            case .noMediaPart:
                lastError[ratingKey] = .transferFailed("No media part to download.")
            case .noExistingVersionPart:
                lastError[ratingKey] = .transferFailed("No server version part to download.")
            }
            markStartAbortedBeforeTransfer(ratingKey: ratingKey)
            releaseInFlight(for: attemptKey)
            return

        case .preflightOriginal:
            guard let part = staticPart else {
                markStartAbortedBeforeTransfer(ratingKey: ratingKey)
                releaseInFlight(for: attemptKey)
                return
            }
            // The original file is a STATIC GET with a real Content-Length + valid moov atom.
            let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            let preflight = await preflightOriginalPlayback(ratingKey: ratingKey, url: url,
                                                            token: token, expectedBytes: part.size,
                                                            durationMs: part.duration ?? item.duration)
            // Lens 6 F3: the AVPlayer preflight can run for tens of seconds. A delete/pause
            // landing inside it must supersede BOTH continuations: the pass branch would
            // unconditionally upsert + session.start, and the fail branch would seed a zombie
            // `.queued` prep row that the server-prep refresh kick then reanimates into a full
            // optimize job. Exit without touching the store or the optimize queue.
            guard startAttemptStillCurrent(startAttempt, backend: "Plex",
                                           phase: "original_preflight") else { return }
            switch PlexDownloadRouter.routeAfterOriginalPreflight(
                passed: preflight,
                fallbackOptimizeTarget: Self.originalFallbackOptimizeTarget()
            ) {
            case .staticOriginal:
                startStaticPlexPartDownload(ratingKey: ratingKey, item: item, part: part, url: url,
                                            metadata: metadata, choiceLabel: "original",
                                            attemptID: startAttempt.attemptID,
                                            choice: choice, mediaIndex: mediaIndex, partIndex: partIndex,
                                            server: server, token: token)
            case .optimizeFallback(let fallback):
                recordDownloadDiagnostic("downloads.original_preflight_fallback", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(fallback),
                ])
                await selectPlexAudioForPreparedDownloadIfNeeded(
                    part: part, audioStreamIndex: audioStreamIndex,
                    server: server, token: token)
                await triggerOptimizeAndDownload(item: item, targetName: fallback,
                                                 metadata: metadata, session: backendSession,
                                                 attemptKey: attemptKey)
            }

        case .staticExistingVersion:
            // #112: download an EXISTING server-generated Plex Version exactly as-is. Same static
            // byte-for-byte transfer as `.original`, but the user explicitly picked a pre-rendered
            // server version, so we DELIBERATELY skip the original direct-play preflight (the
            // version is already a server-prepared file) and NEVER touch the optimize queue.
            guard let part = staticPart else {
                markStartAbortedBeforeTransfer(ratingKey: ratingKey)
                releaseInFlight(for: attemptKey)
                return
            }
            let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            startStaticPlexPartDownload(ratingKey: ratingKey, item: item, part: part, url: url,
                                        metadata: metadata, choiceLabel: "existing_version",
                                        attemptID: startAttempt.attemptID,
                                        choice: choice, mediaIndex: mediaIndex, partIndex: partIndex,
                                        server: server, token: token)

        case .optimize(let targetName):
            await selectPlexAudioForPreparedDownloadIfNeeded(
                part: staticPart, audioStreamIndex: audioStreamIndex,
                server: server, token: token)
            await triggerOptimizeAndDownload(item: item, targetName: targetName,
                                             metadata: metadata, session: backendSession,
                                             attemptKey: attemptKey)
        }
    }

    /// Plex optimizer output follows the Part's selected audio stream. Apply the user's preferred
    /// stream immediately before the bounded server-prep start; failure deliberately falls back to
    /// Plex's selected/default stream rather than failing an otherwise valid season episode.
    private func selectPlexAudioForPreparedDownloadIfNeeded(
        part: Part?, audioStreamIndex: Int?, server: URL, token: String
    ) async {
        guard let part, let audioStreamIndex,
              part.audioStreams.contains(where: {
                  $0.id == audioStreamIndex || $0.index == audioStreamIndex
              }) else { return }
        do {
            try await appModel.client.send(StreamSelectionRequest.selectAudioStream(
                server: server, token: token, identity: appModel.identity,
                partID: part.id, audioStreamID: audioStreamIndex))
        } catch {
            recordDownloadDiagnostic("downloads.audio_preference_fallback", fields: [
                "backend": .label("Plex"),
                "reason": .label("selection_request_failed"),
            ])
        }
    }

    /// Shared tail for the two Plex STATIC part-download lanes (`.original` after its preflight, and
    /// `.existingVersion`): storage check, seed the row, cache side assets, then kick off the
    /// background transfer of a single `Part` byte-for-byte. Neither lane renders server-side, so
    /// the optimize queue is untouched. `choiceLabel` only tags diagnostics.
    private func startStaticPlexPartDownload(ratingKey: String, item: MediaItem, part: Part, url: URL,
                                             metadata: OfflineMetadata, choiceLabel: String,
                                             attemptID: DownloadAttemptID,
                                             choice: DownloadChoice, mediaIndex: Int, partIndex: Int,
                                             server: URL, token: String) {
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        let expectedBytes = estimatedBytes(for: item, choice: choice,
                                           mediaIndex: mediaIndex,
                                           partIndex: partIndex,
                                           backend: .plex) ?? part.size
        if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Plex", expectedBytes: expectedBytes) {
            releaseInFlight(for: attemptKey)
            return
        }
        let ext = part.container ?? (part.file as NSString?)?.pathExtension ?? "mp4"
        let destination = store.destinationURL(ratingKey: ratingKey,
                                               ext: ext.isEmpty ? "mp4" : ext)
        // Publish the 0% row only while this exact seeded attempt still owns the key. A stale
        // preflight must never upsert over a delete/re-download B before side-cache or URLSession
        // work starts.
        let record = DownloadRecord(ratingKey: ratingKey, attemptID: attemptID, title: item.title,
                                    localURL: destination, bytes: 0, progress: 0,
                                    metadata: metadata)
        switch store.createAttemptOwnedRecord(record, attemptID: attemptID) {
        case .committed(let committed) where committed == attemptKey:
            break
        case .committed, .rejectedOwnership:
            recordDownloadDiagnostic("downloads.start_superseded_after_await", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Plex"),
                "phase": .label("static_publish"),
                "reason": .label("owner_changed"),
            ])
            return
        case .failed:
            lastError[ratingKey] = .transferFailed(
                "The download could not be saved safely. Check storage and try again.")
            _ = setAttemptStatus(.failed, for: attemptKey, context: "plex_static_publish")
            if store.ownsAttempt(attemptKey) { releaseInFlight(for: attemptKey) }
            refreshRecords()
            return
        }
        refreshRecords()
        cacheChapterImages(for: attemptKey, item: item, backend: .plex,
                           server: server, token: token)
        cachePlexTextSubtitles(for: attemptKey, part: part, server: server, token: token)
        beginBackgroundTransfer(DownloadTransferStartPlan(
            attemptKey: attemptKey,
            backendLabel: "Plex",
            choiceLabel: choiceLabel,
            urlShape: url,
            expectedBytes: part.size,
            releaseInFlightOnFailure: false
        )) {
            try session.start(ratingKey: ratingKey, from: url, to: destination,
                              expectedBytes: part.size, byteRangeCheckpoint: true,
                              resetRangeRestartCounters: !consumeRangeRestartCounterPreservation(ratingKey: ratingKey))
        }
    }

    func fallbackOriginalValidationFailureIfPossible(ratingKey: String) async {
        // If this was already an optimizer/transcode-sourced file, do not loop. The fallback is
        // only for a true-original transfer that downloaded successfully but failed the final
        // local AVPlayer startup validation.
        //
        // #84: gate on the ROW's own backend (via the migration fallback), not `activeBackend`,
        // and resolve the Plex session from its lane — so the original→optimize fallback fires
        // even if the user has since switched to Jellyfin/Emby, as long as the Plex lane is still
        // configured (lanes persist independently).
        let record = store.record(for: ratingKey)
        let backendSession = appModel.backendSession(for: .plex)
        guard let attemptID = record?.attemptID else { return }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard PlexOriginalFallbackPolicy.shouldFallback(
            record: record,
            ratingKey: ratingKey,
            isTranscodeSourced: transcodeSourcedDownloads.contains(attemptKey),
            hasServerPrepQueueTitle: serverPrepAttempts.queueTitle(for: attemptKey) != nil,
            hasPlexSession: backendSession != nil),
            let metadata = record?.metadata,
            let backendSession else { return }
        let item = metadata.makeMediaItem()
        let target = Self.originalFallbackOptimizeTarget()
        recordDownloadDiagnostic("downloads.original_validation_fallback", fields: [
            "download_id": .identifier(ratingKey),
            "target": .label(target),
        ])
        activeJobs.insert(ratingKey)
        inFlightAttempts.acquire(attemptKey)
        lastError[ratingKey] = nil
        await triggerOptimizeAndDownload(item: item, targetName: target,
                                         metadata: metadata, session: backendSession,
                                         attemptKey: attemptKey)
    }

    static func originalFallbackOptimizeTarget(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: PlaybackPreferences.Keys.defaultDownloadQuality)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PlexOriginalFallbackPolicy.fallbackTarget(
            storedPreference: stored,
            defaultPreference: PlaybackPreferences.defaultDownloadQuality)
    }

    /// Second-stage safety gate for user-selected Plex original downloads. The decision endpoint
    /// can say "direct play" but still not prove AVFoundation will open the static source URL as
    /// a local/offline-style file. Before committing a potentially huge transfer, briefly start
    /// the source in a muted `AVPlayer`. Passing means the original path continues; failing means
    /// we transparently fall back to the server optimizer.
    private func preflightOriginalPlayback(ratingKey: String, url: URL, token: String,
                                           expectedBytes: Int?, durationMs: Int?) async -> Bool {
        let policy = OfflinePlaybackValidationPolicy.make(durationMs: durationMs, isRemotePreflight: true)
        recordDownloadDiagnostic("downloads.original_playback_preflight", fields: [
            "download_id": .identifier(ratingKey),
            "phase": .label("start"),
            "url_shape": .urlShape(url),
            "expected_bytes": .bytes(expectedBytes),
            "required_playback_seconds": .secondsBucket(policy.requiredPlaybackSeconds),
            "timeout_seconds": .secondsBucket(policy.timeoutSeconds),
        ])

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": PlexHeaders.media(identity: appModel.identity, token: token),
        ])
        let assetPlayable = (try? await asset.load(.isPlayable)) ?? false
        guard assetPlayable else {
            recordDownloadDiagnostic("downloads.original_playback_preflight", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("failed"),
                "reason": .label("asset_not_playable"),
            ])
            return false
        }

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(policy.timeoutSeconds * 1000)))
        var sawReady = false
        while ContinuousClock.now < deadline {
            switch item.status {
            case .failed:
                recordDownloadDiagnostic("downloads.original_playback_preflight", fields: [
                    "download_id": .identifier(ratingKey),
                    "phase": .label("failed"),
                    "reason": .label("item_failed"),
                    "error": .error(item.error),
                ])
                return false
            case .readyToPlay:
                sawReady = true
            case .unknown:
                break
            @unknown default:
                break
            }

            let seconds = player.currentTime().seconds
            if sawReady, seconds.isFinite, seconds >= policy.requiredPlaybackSeconds {
                recordDownloadDiagnostic("downloads.original_playback_preflight", fields: [
                    "download_id": .identifier(ratingKey),
                    "phase": .label("passed"),
                    "played": .secondsBucket(seconds),
                ])
                return true
            }
            try? await Task.sleep(for: .milliseconds(policy.pollIntervalMilliseconds))
        }

        recordDownloadDiagnostic("downloads.original_playback_preflight", fields: [
            "download_id": .identifier(ratingKey),
            "phase": .label("failed"),
            "reason": .label(sawReady ? "no_playback_progress" : "timeout_not_ready"),
        ])
        return false
    }
}
