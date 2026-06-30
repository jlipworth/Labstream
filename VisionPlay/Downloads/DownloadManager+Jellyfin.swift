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
                                 mediaSourceIDOverride: String? = nil) async {
        let itemId = item.ratingKey
        let ratingKey = Self.jellyfinRecordKey(itemId)
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
        guard acquireInFlightSlotForStart(ratingKey: ratingKey, backend: "Jellyfin") else { return }
        lastError[ratingKey] = nil
        // No `defer { activeJobs.remove }` — same in-flight-lifetime fix as the Plex path:
        // `session.start` only kicks off the transfer, so protection is released terminally
        // from `refreshRecords` (on `.complete`/`.failed`) plus the explicit no-start exits.

        if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Jellyfin",
                                    expectedBytes: estimatedBytes(for: item, choice: choice,
                                                                  mediaIndex: mediaIndex,
                                                                  partIndex: partIndex,
                                                                  backend: .jellyfin)) {
            releaseInFlight(ratingKey: ratingKey)
            return
        }

        let media = item.media.flatMap { $0.indices.contains(mediaIndex) ? $0[mediaIndex] : nil }
        let part = media?.part.indices.contains(partIndex) == true ? media?.part[partIndex] : nil
        let resolutionLabel = Self.displayResolutionLabel(choice: choice, chosenMedia: media)
        let jellyfinMediaSourceID = mediaSourceIDOverride ?? Self.jellyfinMediaSourceID(media: media, part: part)
        var resolvedJellyfinMediaSourceID = jellyfinMediaSourceID
        var metadata = Self.offlineMetadata(from: item, resolutionLabel: resolutionLabel,
                                            mediaIndex: mediaIndex, partIndex: partIndex,
                                            optimizeTargetName: {
                                                if case .optimize(let targetName) = choice { return targetName }
                                                return nil
                                            }(),
                                            session: backendSession,
                                            mediaSourceID: jellyfinMediaSourceID,
                                            downloadLane: Self.downloadLane(for: choice),
                                            serverPreparedVersion: Self.isServerPreparedVersion(for: choice))
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
        // #84: captured here so the minted PlaySessionId can be PERSISTED after the row is seeded
        // (below), enabling encoder teardown after a hard app kill — not just in-memory teardown.
        var mintedPlaySessionId: String?
        do {
            switch choice {
            case .original, .existingVersion:
                // #112: `.existingVersion` is a Plex-only lane (server-generated Plex Versions). It
                // is never produced for Jellyfin, but the switch must be exhaustive — treat it as a
                // plain original static download here.
                let ext = part?.container ?? media?.container ?? "mp4"
                destination = store.destinationURL(ratingKey: ratingKey,
                                                   ext: ext.isEmpty ? "mp4" : ext)
                request = try JellyfinLibrary.downloadRequest(server: server,
                                                              token: token,
                                                              identity: identity,
                                                              itemId: itemId,
                                                              mediaSourceId: jellyfinMediaSourceID,
                                                              container: ext)
                expectedBytes = part?.size

            case .optimize(let targetName):
                // Ask Jellyfin for a real PlaybackInfo session before starting the progressive
                // transcode. A locally-minted/random PlaySessionId can make some Jellyfin
                // servers return an immediate HTTP 500 from /Videos/{id}/stream.mp4 even though
                // the item is otherwise streamable. The compatible-remux lane already does this;
                // keep the bitrate-preset lane on the same server-minted session path.
                guard let userId = backendSession.userID, !userId.isEmpty else {
                    throw DownloadError.notAuthenticated
                }
                let profile = Self.jellyfinTranscodeProfile(named: targetName)
                destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                expectedBytes = TranscodeSizeEstimator.bytes(durationMs: item.duration,
                                                             videoBitrateBps: profile.videoBitrateBps)
                let infoReq = try JellyfinPlayback.downloadPlaybackInfoRequest(
                    server: server, token: token, identity: identity,
                    itemId: itemId, userId: userId,
                    mediaSourceId: jellyfinMediaSourceID,
                    maxStaticBitrate: max(profile.videoBitrateBps, 200_000_000))
                let (data, response) = try await URLSession.shared.data(for: infoReq)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw DownloadError.transferFailed("PlaybackInfo HTTP \(http.statusCode)")
                }
                let info = try JellyfinPlaybackInfoResponse.decode(from: data)
                let decision = try JellyfinPlayback.downloadDecision(response: info,
                                                                     preferredMediaSourceId: jellyfinMediaSourceID)
                resolvedJellyfinMediaSourceID = decision.mediaSourceId
                let transcodedRequest: URLRequest = Self.jellyfinTranscodedDownloadRequest(
                    server, token, identity, itemId, decision.mediaSourceId, decision.playSessionId, profile)
                request = transcodedRequest
                jellyfinPlaySessionByRatingKey[ratingKey] = decision.playSessionId
                mintedPlaySessionId = decision.playSessionId
                recordDownloadDiagnostic("downloads.jellyfin_transcode_decision", fields: [
                    "download_id": .identifier(ratingKey),
                    "route": .label("transcode"),
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
                    maxStaticBitrate: 200_000_000)
                let (data, response) = try await URLSession.shared.data(for: infoReq)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw DownloadError.transferFailed("PlaybackInfo HTTP \(http.statusCode)")
                }
                let info = try JellyfinPlaybackInfoResponse.decode(from: data)
                let decision = try JellyfinPlayback.downloadDecision(response: info,
                                                                     preferredMediaSourceId: jellyfinMediaSourceID)
                resolvedJellyfinMediaSourceID = decision.mediaSourceId
                let eligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
                    videoCodec: decision.videoCodec,
                    audioCodec: decision.audioCodec,
                    sourceContainer: decision.container)
                let routeIsRemux = eligibility.isEligible
                recordDownloadDiagnostic("downloads.jellyfin_decision", fields: [
                    "download_id": .identifier(ratingKey),
                    "negotiated_direct_play": .bool(decision.supportsDirectPlay),
                    "negotiated_direct_stream": .bool(decision.supportsDirectStream),
                    "container": .label(decision.container ?? "unknown"),
                    "route": .label(routeIsRemux ? "compatible_remux" : "transcode"),
                    "reasons": .label(decision.transcodeReasons.joined(separator: ",")),
                ])
                if routeIsRemux, let videoCodec = eligibility.videoCodec {
                    // Output keeps original video bytes → expected size ≈ original source size.
                    expectedBytes = decision.size ?? part?.size
                    request = try JellyfinLibrary.compatibleRemuxDownloadRequest(
                        server: server, token: token, identity: identity, itemId: itemId,
                        mediaSourceId: decision.mediaSourceId,
                        videoCodec: videoCodec, copyAudio: eligibility.copiesAudio,
                        playSessionId: decision.playSessionId)
                } else {
                    // Stale UI/retry fallback: keep the download safe and playable when the
                    // source video cannot be copied into the compatible MP4 lane. Persist the
                    // ACTUAL transfer route as `.optimize` so the offline UI says Transcode (not
                    // Remux) and retry follows the same non-resumable transcode lane.
                    metadata.downloadLane = .optimize
                    metadata.optimizeTargetName = Self.jellyfinDefaultDownloadPreset
                    let profile = Self.jellyfinTranscodeProfile(named: Self.jellyfinDefaultDownloadPreset)
                    expectedBytes = TranscodeSizeEstimator.bytes(durationMs: item.duration,
                                                                 videoBitrateBps: profile.videoBitrateBps)
                    request = Self.jellyfinTranscodedDownloadRequest(
                        server, token, identity, itemId, decision.mediaSourceId,
                        decision.playSessionId, profile)
                }
                jellyfinPlaySessionByRatingKey[ratingKey] = decision.playSessionId
                mintedPlaySessionId = decision.playSessionId
            }
        } catch {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Jellyfin"),
                "error": .error(error),
            ])
            lastError[ratingKey] = .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer"))
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
            return
        }

        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: destination, bytes: 0, progress: 0,
                                    metadata: metadata))
        // #84: persist the minted PlaySessionId onto the now-seeded row so a hard app kill can
        // still tear the encoder down on next launch (was in-memory only).
        if let mintedPlaySessionId {
            store.setPlaySessionID(ratingKey: ratingKey, mintedPlaySessionId)
            if let mediaSourceID = resolvedJellyfinMediaSourceID,
               let userID = backendSession.userID, !userID.isEmpty {
                startJellyfinDownloadKeepalive(ratingKey: ratingKey,
                                               itemId: itemId,
                                               mediaSourceId: mediaSourceID,
                                               playSessionId: mintedPlaySessionId,
                                               session: backendSession,
                                               userId: userID,
                                               durationMs: item.duration)
            }
        }
        if let resolvedJellyfinMediaSourceID,
           resolvedJellyfinMediaSourceID != jellyfinMediaSourceID {
            store.setMediaSourceID(ratingKey: ratingKey, resolvedJellyfinMediaSourceID)
        }
        refreshRecords()
        // #102: cache the poster locally (best-effort) so artwork shows offline. Unlike the
        // Plex lane this MUST use the authenticated MediaBrowser image request.
        cacheJellyfinPoster(ratingKey: ratingKey, item: item, server: server,
                            token: token, identity: identity)
        cacheJellyfinTrickPlay(ratingKey: ratingKey, itemId: itemId, mediaSourceId: resolvedJellyfinMediaSourceID,
                               server: server, token: token, identity: identity)
        cacheChapterImages(ratingKey: ratingKey, item: item, backend: .jellyfin,
                           server: server, token: token)
        cacheJellyfinTextSubtitles(ratingKey: ratingKey, itemId: itemId, mediaSourceId: resolvedJellyfinMediaSourceID,
                                   part: part, server: server, token: token, identity: identity)

        beginBackgroundTransfer(ratingKey: ratingKey, backendLabel: "Jellyfin",
                                choiceLabel: Self.diagnosticChoiceLabel(choice),
                                urlShape: request.url, expectedBytes: expectedBytes,
                                releaseInFlightOnFailure: true) {
            // A Jellyfin `.optimize`/`.optimizeCompatible` download streams the file directly from
            // the transcoder/remuxer — there is no separate "render then static download" phase, so
            // the byte rate is encoder-gated and the stream is forward-only (not range-resumable).
            // Mark it so the rate isn't misread as a network problem. `.original` is a static file
            // stream → network-bound, range-resumable, not marked.
            switch choice {
            case .optimize, .optimizeCompatible: transcodeSourcedDownloads.insert(ratingKey)
            case .original, .existingVersion: break
            }
            try session.start(ratingKey: ratingKey,
                              with: request,
                              to: destination,
                              expectedBytes: expectedBytes,
                              byteRangeCheckpoint: {
                                  switch choice {
                                  case .original, .existingVersion: return true
                                  case .optimize, .optimizeCompatible: return false
                                  }
                              }(),
                              resetRangeRestartCounters: !consumeRangeRestartCounterPreservation(ratingKey: ratingKey))
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
    private func cacheJellyfinTrickPlay(ratingKey: String,
                                        itemId: String,
                                        mediaSourceId: String?,
                                        server: URL,
                                        token: String,
                                        identity: JellyfinClientIdentity,
                                        width: Int = 320) {
        guard let mediaSourceId, !mediaSourceId.isEmpty else { return }
        let store = self.store
        Task { [weak self] in
            do {
                let playlistReq = try JellyfinLibrary.trickPlayPlaylistRequest(server: server,
                                                                               token: token,
                                                                               identity: identity,
                                                                               itemId: itemId,
                                                                               mediaSourceId: mediaSourceId,
                                                                               width: width)
                let (playlistData, playlistResponse) = try await URLSession.shared.data(for: playlistReq)
                guard let playlistHTTP = playlistResponse as? HTTPURLResponse,
                      (200..<300).contains(playlistHTTP.statusCode),
                      let playlistText = String(data: playlistData, encoding: .utf8) else { return }
                let playlist = try JellyfinTrickPlayPlaylistParser.parse(playlistText)
                var tileRelatives: [String] = []
                var tileFilenamesByURI: [String: String] = [:]
                // Bound side-asset fanout (#187). A long movie can have many tile sheets; fetching all
                // at once and then retaining every Data blob until after the group completes can amplify
                // overnight memory pressure. Fetch in small concurrent batches and write each batch
                // before moving on.
                let batchSize = 4
                if playlist.tiles.count > batchSize {
                    await MainActor.run {
                        self?.recordDownloadDiagnostic("downloads.side_cache_throttled", fields: [
                            "download_id": .identifier(ratingKey),
                            "asset": .label("jellyfin_trickplay_tiles"),
                            "request_count": .int(playlist.tiles.count),
                            "batch_size": .int(batchSize),
                        ])
                    }
                }
                var start = 0
                while start < playlist.tiles.count {
                    let end = min(start + batchSize, playlist.tiles.count)
                    let batch = Array(playlist.tiles[start..<end].enumerated()).map { (offset, tile) in
                        (index: start + offset, tile: tile)
                    }
                    let fetched: [(index: Int, uri: String, data: Data)] = await withTaskGroup(of: (Int, String, Data)?.self) { group in
                        for entry in batch {
                            guard let tileReq = try? JellyfinLibrary.trickPlayTileRequest(server: server,
                                                                                          token: token,
                                                                                          identity: identity,
                                                                                          itemId: itemId,
                                                                                          mediaSourceId: mediaSourceId,
                                                                                          width: width,
                                                                                          tileURI: entry.tile.uri) else { continue }
                            let uri = entry.tile.uri
                            let index = entry.index
                            group.addTask {
                                guard let (tileData, tileResponse) = try? await URLSession.shared.data(for: tileReq),
                                      let tileHTTP = tileResponse as? HTTPURLResponse,
                                      (200..<300).contains(tileHTTP.statusCode),
                                      !tileData.isEmpty else { return nil }
                                return (index, uri, tileData)
                            }
                        }
                        var out: [(index: Int, uri: String, data: Data)] = []
                        for await result in group { if let result { out.append(result) } }
                        return out.sorted { $0.index < $1.index }
                    }
                    for entry in fetched {
                        let destination = store.jellyfinTrickPlayTileDestinationURL(ratingKey: ratingKey, index: entry.index)
                        try entry.data.write(to: destination, options: .atomic)
                        tileFilenamesByURI[entry.uri] = destination.lastPathComponent
                        tileRelatives.append(destination.lastPathComponent)
                    }
                    start = end
                }
                guard !tileRelatives.isEmpty else { return }
                let sanitized = JellyfinTrickPlayOfflineCachePlanner.sanitizedPlaylist(playlistText, tileFilenamesByURI: tileFilenamesByURI)
                guard !sanitized.localizedCaseInsensitiveContains("apikey=") else { return }
                let playlistURL = store.jellyfinTrickPlayPlaylistDestinationURL(ratingKey: ratingKey)
                try sanitized.data(using: .utf8)?.write(to: playlistURL, options: .atomic)
                await MainActor.run {
                    store.setJellyfinTrickPlayRelativePaths(ratingKey: ratingKey,
                                                            playlist: playlistURL.lastPathComponent,
                                                            tiles: tileRelatives)
                    self?.refreshRecords()
                }
            } catch {
                // Optional asset cache. Never log token-bearing playlist/tile URLs.
            }
        }
    }
}
