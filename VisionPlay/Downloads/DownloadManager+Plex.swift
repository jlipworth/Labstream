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
                         mediaIndex: Int = 0, partIndex: Int = 0) async {
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
        guard acquireInFlightSlotForStart(ratingKey: ratingKey, backend: "Plex") else { return }
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
            releaseInFlight(ratingKey: ratingKey)
            return
        }

        let chosenMedia = item.media?[safe: mediaIndex]
        let resolutionLabel = Self.displayResolutionLabel(choice: choice, chosenMedia: chosenMedia)
        let optimizeTargetName: String?
        if case .optimize(let targetName) = choice {
            optimizeTargetName = targetName
        } else {
            optimizeTargetName = nil
        }
        let metadata = Self.offlineMetadata(from: item, resolutionLabel: resolutionLabel,
                                            mediaIndex: mediaIndex, partIndex: partIndex,
                                            optimizeTargetName: optimizeTargetName,
                                            session: backendSession,
                                            downloadLane: Self.downloadLane(for: choice),
                                            serverPreparedVersion: Self.isServerPreparedVersion(for: choice))
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
        cachePoster(ratingKey: ratingKey, thumb: Self.offlinePosterRef(for: item),
                    server: server, token: token)
        cachePlexBIF(ratingKey: ratingKey, item: item, mediaIndex: mediaIndex,
                     server: server, token: token)

        let staticPart = chosenMedia?.part[safe: partIndex]
        let initialRoute = PlexDownloadRouter.initialRoute(
            intent: Self.plexDownloadIntent(for: choice),
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
            releaseInFlight(ratingKey: ratingKey)
            return

        case .preflightOriginal:
            guard let part = staticPart else {
                releaseInFlight(ratingKey: ratingKey)
                return
            }
            // The original file is a STATIC GET with a real Content-Length + valid moov atom.
            let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            let preflight = await preflightOriginalPlayback(ratingKey: ratingKey, url: url,
                                                            token: token, expectedBytes: part.size,
                                                            durationMs: part.duration ?? item.duration)
            switch PlexDownloadRouter.routeAfterOriginalPreflight(
                passed: preflight,
                fallbackOptimizeTarget: Self.originalFallbackOptimizeTarget()
            ) {
            case .staticOriginal:
                startStaticPlexPartDownload(ratingKey: ratingKey, item: item, part: part, url: url,
                                            metadata: metadata, choiceLabel: "original",
                                            choice: choice, mediaIndex: mediaIndex, partIndex: partIndex,
                                            server: server, token: token)
            case .optimizeFallback(let fallback):
                recordDownloadDiagnostic("downloads.original_preflight_fallback", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(fallback),
                ])
                await triggerOptimizeAndDownload(item: item, targetName: fallback,
                                                 metadata: metadata, session: backendSession)
            }

        case .staticExistingVersion:
            // #112: download an EXISTING server-generated Plex Version exactly as-is. Same static
            // byte-for-byte transfer as `.original`, but the user explicitly picked a pre-rendered
            // server version, so we DELIBERATELY skip the original direct-play preflight (the
            // version is already a server-prepared file) and NEVER touch the optimize queue.
            guard let part = staticPart else {
                releaseInFlight(ratingKey: ratingKey)
                return
            }
            let url = OptimizeRequest.downloadURL(server: server, token: token, partKey: part.key)
            startStaticPlexPartDownload(ratingKey: ratingKey, item: item, part: part, url: url,
                                        metadata: metadata, choiceLabel: "existing_version",
                                        choice: choice, mediaIndex: mediaIndex, partIndex: partIndex,
                                        server: server, token: token)

        case .optimize(let targetName):
            await triggerOptimizeAndDownload(item: item, targetName: targetName,
                                             metadata: metadata, session: backendSession)
        }
    }

    private static func plexDownloadIntent(for choice: DownloadChoice) -> PlexDownloadRouter.Intent {
        switch choice {
        case .original:
            return .original
        case .existingVersion:
            return .existingVersion
        case .optimize(let targetName):
            return .optimize(targetName: targetName)
        case .optimizeCompatible:
            return .optimizeCompatible
        }
    }

    /// Shared tail for the two Plex STATIC part-download lanes (`.original` after its preflight, and
    /// `.existingVersion`): storage check, seed the row, cache side assets, then kick off the
    /// background transfer of a single `Part` byte-for-byte. Neither lane renders server-side, so
    /// the optimize queue is untouched. `choiceLabel` only tags diagnostics.
    private func startStaticPlexPartDownload(ratingKey: String, item: MediaItem, part: Part, url: URL,
                                             metadata: OfflineMetadata, choiceLabel: String,
                                             choice: DownloadChoice, mediaIndex: Int, partIndex: Int,
                                             server: URL, token: String) {
        let expectedBytes = estimatedBytes(for: item, choice: choice,
                                           mediaIndex: mediaIndex,
                                           partIndex: partIndex,
                                           backend: .plex) ?? part.size
        if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Plex", expectedBytes: expectedBytes) {
            releaseInFlight(ratingKey: ratingKey)
            return
        }
        let ext = part.container ?? (part.file as NSString?)?.pathExtension ?? "mp4"
        let destination = store.destinationURL(ratingKey: ratingKey,
                                               ext: ext.isEmpty ? "mp4" : ext)
        // Seed a 0% record so the UI shows the job immediately.
        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: destination, bytes: 0, progress: 0,
                                    metadata: metadata))
        refreshRecords()
        cacheChapterImages(ratingKey: ratingKey, item: item, backend: .plex,
                           server: server, token: token)
        cachePlexTextSubtitles(ratingKey: ratingKey, part: part, server: server, token: token)
        beginBackgroundTransfer(DownloadTransferStartPlan(
            ratingKey: ratingKey,
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
        let record = store.records.first(where: { $0.ratingKey == ratingKey })
        let backendSession = appModel.backendSession(for: .plex)
        guard PlexOriginalFallbackPolicy.shouldFallback(
            record: record,
            ratingKey: ratingKey,
            isTranscodeSourced: transcodeSourcedDownloads.contains(ratingKey),
            hasServerPrepQueueTitle: serverPrepAttempts.queueTitle(forRecordKey: ratingKey) != nil,
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
        lastError[ratingKey] = nil
        await triggerOptimizeAndDownload(item: item, targetName: target,
                                         metadata: metadata, session: backendSession)
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
