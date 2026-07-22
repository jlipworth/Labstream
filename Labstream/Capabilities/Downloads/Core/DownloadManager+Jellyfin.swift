import Foundation
import PMSKit
import os

// GH #135 Stage 5c: the Jellyfin download entry points, split out of the DownloadManager
// god-object into their own file. Behavior-unchanged — the same @MainActor methods (an extension
// of a @MainActor class inherits its isolation), relocated verbatim:
//   downloadJellyfin (.original static stream / .optimize + .optimizeCompatible server-rendered
//   MP4 via the negotiated PlaybackInfo session) → downloadJellyfinOriginal + the trickplay cache.
// Both paths share the same background transfer + completion-validation pipeline as Plex/Emby.

extension DownloadManager {

    /// Jellyfin download entry point. Original downloads use Jellyfin's static video stream
    /// endpoint; optimized choices stream a server-rendered MP4 from the
    /// video transcoder with auth in headers. Both paths use the same background transfer +
    /// validation pipeline as Plex downloads.
    public func downloadJellyfin(_ item: MediaItem, choice: DownloadChoice,
                                 mediaIndex: Int = 0,
                                 partIndex: Int = 0,
                                 audioStreamIndex: Int? = nil,
                                 mediaSourceIDOverride: String? = nil,
                                 allowReplacingExistingActiveRow: Bool = false) async {
        let itemId = item.ratingKey
        let ratingKey = DownloadRecordIdentity.recordKey(for: itemId, backend: .jellyfin)
        // #84: capture the Jellyfin session from its own lane; never re-read `appModel.jellyfin*`
        // or `activeBackend` for the rest of this job.
        // (Named `backendSession` to avoid shadowing the instance `session` URLSession wrapper.)
        guard let backendSession = appModel.backendSession(for: .jellyfin) else {
            recordDownloadDiagnostic("downloads.enqueue_failed", fields: [
                "backend": .label("Jellyfin"),
                "reason": .label("not_authenticated"),
            ])
            lastError[ratingKey] = .notAuthenticated
            return
        }
        let server = backendSession.baseURL
        let token = backendSession.token
        // Capture continuity before the attempt seed replaces the visible row. Retry payloads may
        // omit media/part arrays; the prior original-lane extension is then the only trustworthy
        // container and request shape.
        let existingOriginalPath = store.record(for: ratingKey).flatMap { record in
            record.metadata?.resolvedDownloadLane() == .original
                ? record.localURL.lastPathComponent
                : nil
        }
        guard let startAttempt = acquireStartAttempt(ratingKey: ratingKey,
                                                     backend: "Jellyfin",
                                                     allowReplacingExistingActiveRow: allowReplacingExistingActiveRow) else { return }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey,
                                            attemptID: startAttempt.attemptID)
        lastError[ratingKey] = nil
        // No `defer { activeJobs.remove }` — same in-flight-lifetime fix as the Plex path:
        // `session.start` only kicks off the transfer, so protection is released terminally
        // from `refreshRecords` (on `.complete`/`.failed`) plus the explicit no-start exits.

        if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Jellyfin",
                                    expectedBytes: estimatedBytes(for: item, choice: choice,
                                                                  mediaIndex: mediaIndex,
                                                                  partIndex: partIndex,
                                                                  backend: .jellyfin)) {
            releaseInFlight(for: attemptKey)
            return
        }

        let selection = DownloadMediaSelectionPolicy.selection(item: item, mediaIndex: mediaIndex, partIndex: partIndex)
        let media = selection.media
        let part = selection.part
        let resolutionLabel = DownloadPresetPolicy.displayResolutionLabel(choice: choice, chosenMedia: media)
        let jellyfinMediaSourceID = mediaSourceIDOverride ?? selection.mediaSourceID
        var resolvedJellyfinMediaSourceID = jellyfinMediaSourceID
        var metadata = DownloadOfflineMetadataBuilder.metadata(from: item, resolutionLabel: resolutionLabel,
                                            requestedProfileLabel: DownloadChoicePolicy.requestedProfileLabel(for: choice),
                                            mediaIndex: mediaIndex, partIndex: partIndex,
                                            optimizeTargetName: {
                                                if case .optimize(let targetName) = choice { return targetName }
                                                return nil
                                            }(),
                                            session: backendSession,
                                            mediaSourceID: jellyfinMediaSourceID,
                                            audioStreamIndex: audioStreamIndex,
                                            downloadLane: DownloadChoicePolicy.downloadLane(for: choice),
                                            serverPreparedVersion: DownloadChoicePolicy.isServerPreparedVersion(for: choice))
        let seedDestination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        guard persistAttemptSeed(
            DownloadRecord(ratingKey: ratingKey, attemptID: startAttempt.attemptID,
                           title: item.title, localURL: seedDestination,
                           bytes: 0, progress: 0, metadata: metadata),
            for: startAttempt,
            backend: "Jellyfin"
        ) else {
            releaseInFlight(for: attemptKey)
            return
        }
        recordDownloadDiagnostic("downloads.enqueue", fields: downloadDiagnosticFields(
            item: item,
            choice: choice,
            backend: "Jellyfin",
            backendKind: .jellyfin,
            mediaIndex: mediaIndex,
            partIndex: partIndex
        ))
        let identity = appModel.identity.jellyfin
        var request: URLRequest
        var destination: URL
        var expectedBytes: Int?
        var transferRoute = JellyfinDownloadRouter.route(intent: .original,
                                                          videoCodec: nil,
                                                          audioCodec: nil,
                                                          container: part?.container ?? media?.container)
        // #84: captured here so the minted PlaySessionId can be PERSISTED after the row is seeded
        // (below), enabling encoder teardown after a hard app kill — not just in-memory teardown.
        var mintedPlaySessionId: String?
        do {
            switch choice {
            case .original, .existingVersion:
                // #112: `.existingVersion` is a Plex-only lane (server-generated Plex Versions). It
                // is never produced for Jellyfin, but the switch must be exhaustive — treat it as a
                // plain original static download here.
                // Retry/rebuild reconstructs `item` without media/part arrays, so the selection
                // alone would collapse to ".mp4" and abandon an in-progress non-MP4 partial (its
                // checkpoint reads 0 against the new destination). The existing ORIGINAL-lane row's
                // on-disk extension is authoritative for what this transfer already wrote.
                let ext = DownloadMediaSelectionPolicy.containerExtension(
                    selection: selection, existingRelativePath: existingOriginalPath)
                destination = store.destinationURL(ratingKey: ratingKey, ext: ext)
                request = try JellyfinLibrary.downloadRequest(server: server,
                                                              token: token,
                                                              identity: identity,
                                                              itemId: itemId,
                                                              mediaSourceId: jellyfinMediaSourceID,
                                                              container: ext)
                let sourcePlan = JellyfinDownloadSourcePlan.staticOriginal(sourcePartBytes: part?.size)
                expectedBytes = sourcePlan.expectedBytes
                transferRoute = sourcePlan.route

            case .optimize(let targetName):
                // Ask Jellyfin for a real PlaybackInfo session before starting the progressive
                // transcode. A locally-minted/random PlaySessionId can make some Jellyfin
                // servers return an immediate HTTP 500 from /Videos/{id}/stream.mp4 even though
                // the item is otherwise streamable. The compatible-remux lane already does this;
                // keep the bitrate-preset lane on the same server-minted session path.
                guard let userId = backendSession.userID, !userId.isEmpty else {
                    throw DownloadError.notAuthenticated
                }
                let profile = DownloadPresetPolicy.jellyfinTranscodeProfile(named: targetName)
                destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                expectedBytes = TranscodeSizeEstimator.bytes(durationMs: item.duration,
                                                             videoBitrateBps: profile.videoBitrateBps)
                let infoReq = try JellyfinPlayback.downloadPlaybackInfoRequest(
                    server: server, token: token, identity: identity,
                    itemId: itemId, userId: userId,
                    mediaSourceId: jellyfinMediaSourceID,
                    maxStaticBitrate: max(profile.videoBitrateBps, 200_000_000),
                    audioStreamIndex: audioStreamIndex)
                let (data, response) = try await URLSession.shared.data(for: infoReq)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    recordDownloadDiagnostic("downloads.playback_info_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "backend": .label("Jellyfin"),
                        "status_code": .int(http.statusCode),
                        "phase": .label("download_negotiation"),
                    ])
                    throw DownloadError.transferFailed("PlaybackInfo HTTP \(http.statusCode)")
                }
                let info = try JellyfinPlaybackInfoResponse.decode(from: data)
                let decision = try JellyfinPlayback.downloadDecision(response: info,
                                                                     preferredMediaSourceId: jellyfinMediaSourceID)
                let sourcePlan = JellyfinDownloadSourcePlan.transcode(decision: decision,
                                                                      durationMs: item.duration,
                                                                      profile: profile)
                resolvedJellyfinMediaSourceID = sourcePlan.mediaSourceID
                let transcodedRequest = try JellyfinLibrary.transcodedDownloadRequest(
                    server: server,
                    token: token,
                    identity: identity,
                    itemId: itemId,
                    mediaSourceId: sourcePlan.mediaSourceID,
                    playSessionId: decision.playSessionId,
                    maxVideoBitrate: profile.videoBitrateBps,
                    maxWidth: profile.maxWidth,
                    maxHeight: profile.maxHeight,
                    audioStreamIndex: audioStreamIndex)
                request = transcodedRequest
                jellyfinPlaySessionByAttempt[attemptKey] = decision.playSessionId
                mintedPlaySessionId = sourcePlan.playSessionID
                expectedBytes = sourcePlan.expectedBytes
                transferRoute = sourcePlan.route
                recordDownloadDiagnostic("downloads.jellyfin_transcode_decision", fields: [
                    "download_id": .identifier(ratingKey),
                    "route": .label(transferRoute.diagnosticLabel),
                    "container": .label(decision.container ?? "unknown"),
                    "source_video_codec": .label(decision.videoCodec ?? "unknown"),
                    "source_audio_codec": .label(decision.audioCodec ?? "unknown"),
                    "reasons": .label(decision.transcodeReasons.joined(separator: ",")),
                ])

            case .optimizeCompatible:
                // #83: original-quality compatible remux. Re-probe PlaybackInfo here instead of
                // trusting the in-memory `Part` streams: retry after relaunch reconstructs a lean
                // `MediaItem` without stream arrays, and the server's codec/container verdict
                // is the authoritative remux gate.
                guard let userId = backendSession.userID, !userId.isEmpty else {
                    throw DownloadError.notAuthenticated
                }
                destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                let infoReq = try JellyfinPlayback.downloadPlaybackInfoRequest(
                    server: server, token: token, identity: identity,
                    itemId: itemId, userId: userId,
                    mediaSourceId: jellyfinMediaSourceID,
                    maxStaticBitrate: 200_000_000,
                    audioStreamIndex: audioStreamIndex)
                let (data, response) = try await URLSession.shared.data(for: infoReq)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    recordDownloadDiagnostic("downloads.playback_info_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "backend": .label("Jellyfin"),
                        "status_code": .int(http.statusCode),
                        "phase": .label("download_negotiation"),
                    ])
                    throw DownloadError.transferFailed("PlaybackInfo HTTP \(http.statusCode)")
                }
                let info = try JellyfinPlaybackInfoResponse.decode(from: data)
                let decision = try JellyfinPlayback.downloadDecision(response: info,
                                                                     preferredMediaSourceId: jellyfinMediaSourceID)
                let fallbackProfile = DownloadPresetPolicy.jellyfinTranscodeProfile(named: DownloadPresetPolicy.jellyfinDefaultDownloadPreset)
                let sourcePlan = JellyfinDownloadSourcePlan.compatible(
                    decision: decision,
                    sourcePartBytes: part?.size,
                    durationMs: item.duration,
                    fallbackProfile: fallbackProfile)
                resolvedJellyfinMediaSourceID = sourcePlan.mediaSourceID
                transferRoute = sourcePlan.route
                expectedBytes = sourcePlan.expectedBytes
                recordDownloadDiagnostic("downloads.jellyfin_decision", fields: [
                    "download_id": .identifier(ratingKey),
                    "negotiated_direct_play": .bool(decision.supportsDirectPlay),
                    "negotiated_direct_stream": .bool(decision.supportsDirectStream),
                    "container": .label(decision.container ?? "unknown"),
                    "route": .label(transferRoute.diagnosticLabel),
                    "reasons": .label(decision.transcodeReasons.joined(separator: ",")),
                ])
                if sourcePlan.isCompatibleRemux,
                   let eligibility = sourcePlan.compatibleEligibility,
                   let videoCodec = eligibility.videoCodec {
                    request = try JellyfinLibrary.compatibleRemuxDownloadRequest(
                        server: server, token: token, identity: identity, itemId: itemId,
                        mediaSourceId: decision.mediaSourceId,
                        videoCodec: videoCodec, audioCodec: eligibility.audioCodec,
                        copyAudio: eligibility.copiesAudio,
                        playSessionId: decision.playSessionId,
                        audioStreamIndex: audioStreamIndex)
                } else {
                    // Stale UI/retry fallback: keep the download safe and playable when the
                    // source video cannot be copied into the compatible MP4 lane. Persist the
                    // ACTUAL transfer route as `.optimize` so the offline UI says Transcode (not
                    // Remux) and retry follows the same non-resumable transcode lane.
                    metadata.downloadLane = sourcePlan.metadataLaneOverride
                    metadata.optimizeTargetName = sourcePlan.metadataOptimizeTargetNameOverride
                    request = try JellyfinLibrary.transcodedDownloadRequest(
                        server: server,
                        token: token,
                        identity: identity,
                        itemId: itemId,
                        mediaSourceId: decision.mediaSourceId,
                        playSessionId: decision.playSessionId,
                        maxVideoBitrate: fallbackProfile.videoBitrateBps,
                        maxWidth: fallbackProfile.maxWidth,
                        maxHeight: fallbackProfile.maxHeight,
                        audioStreamIndex: audioStreamIndex)
                }
                jellyfinPlaySessionByAttempt[attemptKey] = decision.playSessionId
                mintedPlaySessionId = sourcePlan.playSessionID
            }
            // Lens 6 F1: both transcode lanes awaited PlaybackInfo above with NO currency check —
            // a delete/pause landing during that await used to be fully undone (the seed upsert
            // below re-created the row `.queued`, persisted the psid, started keepalives, and
            // started the transfer). Exit WITHOUT touching the store; release only what this
            // chain minted.
            guard startAttemptStillCurrent(startAttempt, backend: "Jellyfin",
                                           phase: "post_negotiation") else {
                jellyfinPlaySessionByAttempt.removeValue(forKey: attemptKey)
                stopSupersededMediaBrowserEncoder(ratingKey: ratingKey,
                                                  playSessionID: mintedPlaySessionId,
                                                  backendKind: .jellyfin,
                                                  backendSession: backendSession)
                return
            }
        } catch {
            guard store.ownsAttempt(attemptKey) else {
                jellyfinPlaySessionByAttempt.removeValue(forKey: attemptKey)
                stopSupersededMediaBrowserEncoder(ratingKey: ratingKey,
                                                  playSessionID: mintedPlaySessionId,
                                                  backendKind: .jellyfin,
                                                  backendSession: backendSession)
                return
            }
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Jellyfin"),
                "error": .error(error),
            ])
            lastError[ratingKey] = .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer"))
            _ = store.setStatus(for: attemptKey, .failed)
            clearStaticRangePendingResume(ratingKey: ratingKey)
            releaseInFlight(for: attemptKey)
            refreshRecords()
            return
        }

        let publishResult = store.createAttemptOwnedRecord(
            DownloadRecord(ratingKey: ratingKey, attemptID: startAttempt.attemptID,
                           title: item.title, localURL: destination,
                           bytes: 0, progress: 0, metadata: metadata),
            attemptID: startAttempt.attemptID)
        guard case .committed(let publishedKey) = publishResult,
              publishedKey == attemptKey else {
            jellyfinPlaySessionByAttempt.removeValue(forKey: attemptKey)
            stopSupersededMediaBrowserEncoder(ratingKey: ratingKey,
                                              playSessionID: mintedPlaySessionId,
                                              backendKind: .jellyfin,
                                              backendSession: backendSession)
            if store.ownsAttempt(attemptKey) {
                _ = store.setStatus(for: attemptKey, .failed)
                releaseInFlight(for: attemptKey)
            }
            return
        }
        // #84: persist the minted PlaySessionId onto the now-seeded row so a hard app kill can
        // still tear the encoder down on next launch (was in-memory only).
        if let mintedPlaySessionId {
            guard jellyfinMutationAccepted(
                store.setPlaySessionID(for: attemptKey, mintedPlaySessionId),
                key: attemptKey, phase: "play_session") else {
                jellyfinPlaySessionByAttempt.removeValue(forKey: attemptKey)
                stopSupersededMediaBrowserEncoder(ratingKey: ratingKey,
                                                  playSessionID: mintedPlaySessionId,
                                                  backendKind: .jellyfin,
                                                  backendSession: backendSession)
                if store.ownsAttempt(attemptKey) {
                    _ = store.setStatus(for: attemptKey, .failed)
                    releaseInFlight(for: attemptKey)
                }
                return
            }
            if let mediaSourceID = resolvedJellyfinMediaSourceID,
               let userID = backendSession.userID, !userID.isEmpty {
                startJellyfinDownloadKeepalive(
                    attemptKey: attemptKey,
                    itemId: itemId,
                    mediaSourceId: mediaSourceID,
                    playSessionId: mintedPlaySessionId,
                    userId: userID,
                    durationMs: item.duration)
            }
        }
        if let resolvedJellyfinMediaSourceID,
           resolvedJellyfinMediaSourceID != jellyfinMediaSourceID {
            guard jellyfinMutationAccepted(
                store.updateMetadata(for: attemptKey) {
                    $0.mediaSourceID = resolvedJellyfinMediaSourceID
                }, key: attemptKey, phase: "media_source") else {
                if store.ownsAttempt(attemptKey) {
                    _ = store.setStatus(for: attemptKey, .failed)
                    releaseInFlight(for: attemptKey)
                }
                return
            }
        }
        refreshRecords()
        // #102: cache the poster locally (best-effort) so artwork shows offline. Unlike the
        // Plex lane this MUST use the authenticated MediaBrowser image request.
        cacheJellyfinPoster(for: attemptKey, item: item, server: server,
                            token: token, identity: identity)
        cacheJellyfinTrickPlay(for: attemptKey, itemId: itemId, mediaSourceId: resolvedJellyfinMediaSourceID,
                               server: server, token: token, identity: identity)
        cacheChapterImages(for: attemptKey, item: item, backend: .jellyfin,
                           server: server, token: token)
        cacheJellyfinTextSubtitles(for: attemptKey, itemId: itemId, mediaSourceId: resolvedJellyfinMediaSourceID,
                                   part: part, server: server, token: token, identity: identity)

        beginBackgroundTransfer(DownloadTransferStartPlan(
            attemptKey: attemptKey,
            backendLabel: "Jellyfin",
            choiceLabel: DownloadChoicePolicy.diagnosticChoiceLabel(choice),
            urlShape: request.url,
            expectedBytes: expectedBytes,
            releaseInFlightOnFailure: true
        )) {
            guard store.ownsAttempt(attemptKey) else { throw CancellationError() }
            // A Jellyfin `.optimize`/`.optimizeCompatible` download streams the file directly from
            // the transcoder/remuxer — there is no separate "render then static download" phase, so
            // the byte rate is encoder-gated and the stream is forward-only (not range-resumable).
            // Mark it so the rate isn't misread as a network problem. `.original` is a static file
            // stream → network-bound, range-resumable, not marked.
            if transferRoute.isLiveForwardOnly {
                transcodeSourcedDownloads.insert(attemptKey)
            }
            try session.start(ratingKey: ratingKey,
                              with: request,
                              to: destination,
                              expectedBytes: expectedBytes,
                              byteRangeCheckpoint: transferRoute.usesByteRangeCheckpoint,
                              resetRangeRestartCounters: !consumeRangeRestartCounterPreservation(ratingKey: ratingKey))
        }
    }

    private func jellyfinMutationAccepted(_ result: DownloadStore.AttemptMutationResult,
                                           key: DownloadAttemptKey,
                                           phase: String) -> Bool {
        switch result {
        case .applied, .noChange:
            return true
        case .staleOrMissing, .persistenceFailed:
            recordDownloadDiagnostic("downloads.jellyfin_attempt_mutation_rejected", fields: [
                "download_id": .identifier(key.ratingKey),
                "phase": .label(phase),
            ])
            return false
        }
    }

    public func downloadJellyfinOriginal(_ item: MediaItem,
                                         mediaIndex: Int = 0,
                                         partIndex: Int = 0) async {
        await downloadJellyfin(item, choice: .original, mediaIndex: mediaIndex, partIndex: partIndex)
    }

    /// Best-effort cache of Jellyfin trickplay assets for offline scrubbing (#79). Fetches the
    /// playlist, downloads each referenced tile through header auth (stripping ApiKey from tile
    /// URLs in the request builder), then writes a sanitized local playlist whose tile lines are
    /// only local filenames. A miss/corrupt playlist never fails the media download.
    func cacheJellyfinTrickPlay(for attemptKey: DownloadAttemptKey,
                                        itemId: String,
                                        mediaSourceId: String?,
                                        server: URL,
                                        token: String,
                                        identity: JellyfinClientIdentity,
                                        width: Int = 320) {
        guard let mediaSourceId, !mediaSourceId.isEmpty else { return }
        let store = self.store
        guard let sourceIdentity = store.sideAssetSourceIdentity(for: attemptKey) else { return }
        downloadWorkRegistry.startIfAbsent(for: attemptKey, kind: .sideCache(.jellyfinTrickPlay)) { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let playlistReq = try JellyfinLibrary.trickPlayPlaylistRequest(server: server,
                                                                               token: token,
                                                                               identity: identity,
                                                                               itemId: itemId,
                                                                               mediaSourceId: mediaSourceId,
                                                                               width: width)
                let playlistData = try await self.fetchOptionalSideAsset(
                    playlistReq, for: attemptKey, source: sourceIdentity,
                    kind: .jellyfinTrickPlay, resource: "playlist")
                guard let parsed = await DownloadSideAssetService.parseJellyfinPlaylist(playlistData),
                      !Task.isCancelled else { return }
                let playlistText = parsed.text
                let playlist = parsed.playlist
                var tileRelativeByIndex: [Int: String] = [:]
                var tileFilenamesByURI: [String: String] = [:]
                var missing: [(index: Int, uri: String, request: URLRequest, destination: URL)] = []
                for (index, tile) in playlist.tiles.enumerated() {
                    let destination = store.jellyfinTrickPlayTileDestinationURL(
                        ratingKey: attemptKey.ratingKey, index: index)
                    if let relative = store.reusableSideAssetRelativePath(
                        for: attemptKey, destination: destination) {
                        tileRelativeByIndex[index] = relative
                        tileFilenamesByURI[tile.uri] = relative
                        continue
                    }
                    guard let request = try? JellyfinLibrary.trickPlayTileRequest(
                        server: server, token: token, identity: identity, itemId: itemId,
                        mediaSourceId: mediaSourceId, width: width, tileURI: tile.uri) else { continue }
                    missing.append((index, tile.uri, request, destination))
                }

                await withTaskGroup(of: (Int, String, URL, Data)?.self) { group in
                    for entry in missing {
                        group.addTask { [weak self] in
                            guard let self,
                                  let data = try? await self.fetchOptionalSideAsset(
                                    entry.request, for: attemptKey, source: sourceIdentity,
                                    kind: .jellyfinTrickPlay,
                                    resource: entry.destination.lastPathComponent) else { return nil }
                            return (entry.index, entry.uri, entry.destination, data)
                        }
                    }
                    for await result in group {
                        guard let (index, uri, destination, data) = result,
                              !Task.isCancelled,
                              let staging = store.attemptStagingURL(
                                for: attemptKey, stableURL: destination) else { continue }
                        defer { try? FileManager.default.removeItem(at: staging) }
                        guard await DownloadSideAssetService.prepare(
                                data, as: .image, at: staging),
                              Self.promoteSideAsset(store: store, key: attemptKey,
                                                    expectedSource: sourceIdentity,
                                                    stagingURL: staging, stableURL: destination) else { continue }
                        let relative = destination.lastPathComponent
                        tileRelativeByIndex[index] = relative
                        tileFilenamesByURI[uri] = relative
                    }
                }
                let tileRelatives = tileRelativeByIndex.sorted { $0.key < $1.key }.map(\.value)
                guard !tileRelatives.isEmpty else { return }
                let sanitized = JellyfinTrickPlayOfflineCachePlanner.sanitizedPlaylist(playlistText, tileFilenamesByURI: tileFilenamesByURI)
                guard !sanitized.localizedCaseInsensitiveContains("apikey=") else { return }
                let playlistURL = store.jellyfinTrickPlayPlaylistDestinationURL(
                    ratingKey: attemptKey.ratingKey)
                guard let playlistStaging = store.attemptStagingURL(
                    for: attemptKey, stableURL: playlistURL) else { return }
                defer { try? FileManager.default.removeItem(at: playlistStaging) }
                guard let sanitizedData = sanitized.data(using: .utf8),
                      await DownloadSideAssetService.prepare(
                        sanitizedData, as: .jellyfinPlaylist, at: playlistStaging),
                      Self.promoteSideAsset(store: store, key: attemptKey,
                                            expectedSource: sourceIdentity,
                                            stagingURL: playlistStaging,
                                            stableURL: playlistURL) else { return }
                let batch = DownloadSideAssetPublicationBatch(
                    jellyfinTiles: tileRelatives,
                    jellyfinPlaylist: playlistURL.lastPathComponent)
                await MainActor.run {
                    let result = store.updateMetadata(
                        for: attemptKey, expectedSideAssetSource: sourceIdentity) {
                        batch.apply(to: &$0)
                    }
                    if result == .applied || result == .noChange { self.refreshRecords() }
                }
            } catch {
                // Optional asset cache. Never log token-bearing playlist/tile URLs.
            }
        }
    }
}
