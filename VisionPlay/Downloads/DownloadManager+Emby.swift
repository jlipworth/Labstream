import Foundation
import PMSKit
import os

// GH #135 Stage 5c: the Emby download ENTRY POINT, split out of the DownloadManager god-object into
// its own file (symmetric with +Jellyfin; the convert-then-download server-prep half already lives in
// +EmbyConvert). Behavior-unchanged — the same @MainActor methods (an extension of a @MainActor class
// inherits its isolation), relocated verbatim: downloadEmby negotiates an authoritative download
// PlaybackInfo verdict, classifies the route via EmbyDownloadRouter (.original static / .compatibleRemux
// / reroute-to-convert for .transcode), seeds the row, caches side assets, and starts the transfer.

extension DownloadManager {

    /// Emby download entry point. Mirrors `downloadJellyfin`'s structure, with the Emby-specific
    /// corrections proven live against the worst-case MKV item:
    ///
    /// - The route is decided by an AUTHORITATIVE download PlaybackInfo POST (the naked-item
    ///   `SupportsDirectPlay` is optimistic garbage). We advertise a Static-mp4 DOWNLOAD device
    ///   profile (NOT the HLS playback profile) so the negotiated transcode URL is a single
    ///   downloadable file rather than a `.m3u8` playlist.
    /// - Original ⇔ negotiated `SupportsDirectPlay && isLocallyPlayableOriginal(container)`.
    ///   Original uses the static `stream.{container}?static=true` GET (HTTP 206, resumable);
    ///   expected bytes = `MediaSource.Size` (Emby's `Part.size` is always nil).
    /// - Everything else downloads the SERVER-MINTED `TranscodingUrl` (you cannot hand-build it —
    ///   Emby requires the PlaybackInfo-minted `PlaySessionId`). Transcoded streams are not
    ///   range-resumable, so they restart on failure (like Jellyfin), expected bytes are the
    ///   quality×runtime estimate, and the minted `PlaySessionId` is persisted so the FFmpeg
    ///   encoder is torn down on every terminal transition (`releaseInFlight`).
    public func downloadEmby(_ item: MediaItem, choice: DownloadChoice,
                             mediaIndex: Int = 0,
                             partIndex: Int = 0,
                             mediaSourceIDOverride: String? = nil) async {
        let itemId = item.ratingKey
        let ratingKey = Self.embyRecordKey(itemId)
        // #84: capture the Emby session from its own lane; never re-read `appModel.emby*` or
        // `activeBackend` for the rest of this job.
        // (Named `backendSession` to avoid shadowing the instance `session` URLSession wrapper.)
        guard let backendSession = appModel.backendSession(for: .emby),
              let userId = backendSession.userID else {
            recordDownloadDiagnostic("downloads.enqueue_failed", fields: [
                "backend": .label("Emby"),
                "reason": .label("not_authenticated"),
            ])
            lastError[ratingKey] = .notAuthenticated
            return
        }
        let server = backendSession.baseURL
        let token = backendSession.token
        guard acquireInFlightSlotForStart(ratingKey: ratingKey, backend: "Emby") else { return }
        lastError[ratingKey] = nil
        // No `defer { activeJobs.remove }` — same in-flight-lifetime contract as the other lanes:
        // `session.start` only kicks off the transfer, so protection (and the encoder-teardown
        // PlaySessionId) is released terminally from `refreshRecords`/`releaseInFlight`.

        if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Emby",
                                    expectedBytes: estimatedBytes(for: item, choice: choice,
                                                                  mediaIndex: mediaIndex,
                                                                  partIndex: partIndex,
                                                                  backend: .emby)) {
            releaseInFlight(ratingKey: ratingKey)
            return
        }

        let media = item.media?[safe: mediaIndex]
        let part = media?.part[safe: partIndex]
        let resolutionLabel = Self.displayResolutionLabel(choice: choice, chosenMedia: media)
        // Pre-decision media-source hint; the authoritative id (from PlaybackInfo) is persisted
        // onto the row after the decision is known (see below).
        let embyMediaSourceHint = mediaSourceIDOverride ?? Self.embyMediaSourceID(media: media, part: part)
        var metadata = Self.offlineMetadata(from: item, resolutionLabel: resolutionLabel,
                                            mediaIndex: mediaIndex, partIndex: partIndex,
                                            optimizeTargetName: {
                                                if case .optimize(let targetName) = choice { return targetName }
                                                return nil
                                            }(),
                                            session: backendSession,
                                            mediaSourceID: embyMediaSourceHint,
                                            downloadLane: Self.downloadLane(for: choice),
                                            serverPreparedVersion: Self.isServerPreparedVersion(for: choice))
        recordDownloadDiagnostic("downloads.enqueue", fields: downloadDiagnosticFields(
            item: item,
            choice: choice,
            backend: "Emby",
            backendKind: .emby,
            mediaIndex: mediaIndex,
            partIndex: partIndex
        ))
        let identity = appModel.identity.emby
        // Authoritative negotiation: POST the DOWNLOAD device profile and read the negotiated
        // verdict. ~200 Mbps ceiling so a high-bitrate-but-compatible file still qualifies for an
        // original download — a bitrate cap must NEVER force a transcode verdict for a download.
        let decision: EmbyPlayback.EmbyDownloadPlaybackDecision
        do {
            let infoReq: URLRequest
            if case .optimizeCompatible = choice {
                // #83: keep the normal download profile conservative for the forced-transcode lane,
                // but use a remux profile here so HEVC stream-copy eligibility is visible.
                infoReq = try EmbyPlayback.compatibleRemuxDownloadPlaybackInfoRequest(
                    server: server, token: token, identity: identity,
                    userId: userId, itemId: itemId,
                    mediaSourceId: embyMediaSourceHint,
                    maxStaticBitrate: 200_000_000)
            } else {
                infoReq = try EmbyPlayback.downloadPlaybackInfoRequest(
                    server: server, token: token, identity: identity,
                    userId: userId, itemId: itemId,
                    mediaSourceId: embyMediaSourceHint,
                    maxStaticBitrate: 200_000_000)
            }
            let (data, response) = try await URLSession.shared.data(for: infoReq)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DownloadError.transferFailed("PlaybackInfo HTTP \(http.statusCode)")
            }
            let info = try EmbyPlaybackInfoResponse.decode(from: data)
            decision = try EmbyPlayback.downloadDecision(response: info,
                                                         preferredMediaSourceId: embyMediaSourceHint)
        } catch {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Emby"),
                "phase": .label("playback_info"),
                "error": .error(error),
            ])
            lastError[ratingKey] = (error as? DownloadError) ?? .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
            return
        }

        // The resolution label built above came from the item's PRIMARY media — wrong for a
        // server-prepared version, which downloads the CONVERTED source (e.g. a 720p copy of a 4K
        // original). Re-label from the negotiated source's real height so the caption shows the
        // ACTUAL downloaded resolution, not the original's. Only for server-prepared/existing
        // versions; a genuine original keeps its primary-media label.
        if Self.isServerPreparedVersion(for: choice),
           let correctedResolution = Self.resolutionLabel(forHeight: decision.height) {
            metadata.resolutionLabel = correctedResolution
        }

        // Three-way route detection against the AUTHORITATIVE negotiated verdict:
        //   .original          ⇔ negotiated DirectPlay AND locally playable container
        //   .compatibleRemux   ⇔ user chose it AND source video copyable (#83)
        //   .transcode         ⇔ otherwise (forced h264/aac re-encode)
        // The user's `.optimize` choice always forces the transcode lane.
        let containerGate = Self.isLocallyPlayableOriginal(part: part)
            || ["mp4", "m4v", "mov"].contains((decision.container ?? "").lowercased())
        let remuxEligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
            videoCodec: decision.videoCodec, audioCodec: decision.audioCodec,
            sourceContainer: decision.container)
        // #135 Stage 5a: the three-way route decision (#112/#126 existing-version + #83 compatible
        // remux, all against the AUTHORITATIVE negotiated verdict) lives in the pure, tested
        // `EmbyDownloadRouter`. `.original`/`.existingVersion` negotiate identically (a directly
        // playable local-container file downloads byte-for-byte, else transcode); `.optimizeCompatible`
        // stays a remux only while the source video is stream-copy eligible; `.optimize` always transcodes.
        let intent: EmbyDownloadRouter.Intent
        switch choice {
        case .original: intent = .original
        case .existingVersion: intent = .existingVersion
        case .optimizeCompatible: intent = .compatible
        case .optimize: intent = .transcode
        }
        let route = EmbyDownloadRouter.route(intent: intent,
                                             supportsDirectPlay: decision.supportsDirectPlay,
                                             container: decision.container,
                                             videoCodec: decision.videoCodec,
                                             audioCodec: decision.audioCodec,
                                             part: part)
        recordDownloadDiagnostic("downloads.emby_decision", fields: [
            "download_id": .identifier(ratingKey),
            "negotiated_direct_play": .bool(decision.supportsDirectPlay),
            "negotiated_direct_stream": .bool(decision.supportsDirectStream),
            "container": .label(decision.container ?? "unknown"),
            "container_gate": .bool(containerGate),
            "route": .label(route == .original ? "original" : route == .compatibleRemux ? "compatible_remux" : "transcode"),
            "reasons": .label(decision.transcodeReasons.joined(separator: ",")),
        ])

        // Emby convert-then-download (default for non-direct downloads): ANY choice that negotiated
        // `.transcode` would otherwise be a LIVE streaming transcode — ephemeral, no stable byte
        // range, so a dropped connection restarts from scratch (multi-GB never finishes). Instead,
        // redirect to the server-side "Convert Media" job: render a persistent file, then download it
        // via the resumable `.original` static lane (and KEEP it, so #126's reuse serves the next
        // download for free). This covers BOTH `.optimize` AND `.optimizeCompatible`: the compatible
        // lane only stays a remux when the source video is stream-copy eligible (route == .original/
        // .compatibleRemux); when it falls through to `route == .transcode` (video not copyable) it
        // is exactly the non-resumable live transcode this feature removes. Direct-play (.original),
        // compatible-remux (route == .compatibleRemux), and #126 reuse (the `.existingVersion`/
        // override handoff, which negotiates `.original`) are untouched — `.existingVersion` is
        // intentionally excluded here so the convert handoff never re-triggers this reroute (no
        // recursion). A would-be transcode of an `.existingVersion` source is failed, not rerouted,
        // by the eligibility guard below.
        if route == .transcode {
            switch choice {
            case .optimize(let targetName):
                await triggerConvertAndDownload(item: item, targetName: targetName,
                                                metadata: metadata, session: backendSession)
                return
            case .optimizeCompatible:
                // No explicit preset for the compatible lane — derive one from the user's stored
                // default download quality so the converted bitrate matches their intent.
                let targetName = Self.jellyfinDefaultDownloadPreset
                await triggerConvertAndDownload(item: item, targetName: targetName,
                                                metadata: metadata, session: backendSession)
                return
            case .existingVersion:
                // The convert handoff (.existingVersion + override) must land on the resumable
                // `.original` lane; if the converted source still negotiates a transcode (e.g. an
                // audio codec the device profile re-encodes), silently streaming it would be a
                // non-resumable live transcode of the just-converted file. Fail loudly instead.
                recordDownloadDiagnostic("downloads.convert_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "phase": .label("converted_not_directly_downloadable"),
                    "reasons": .label(decision.transcodeReasons.joined(separator: ",")),
                ])
                lastError[ratingKey] = .transferFailed("Converted source not directly downloadable.")
                store.setStatus(ratingKey: ratingKey, .failed)
                releaseInFlight(ratingKey: ratingKey)
                refreshRecords()
                return
            case .original:
                // A user/source `.original` row is only range-resumable when PlaybackInfo still
                // negotiates a static direct download. Do not silently fall into the live encoder
                // path while leaving the row stamped `.original`, or URLSession resume blobs can
                // later be accepted for a forward-only stream. The user can delete/re-download via
                // an optimize/convert choice if the server no longer exposes a direct file route.
                recordDownloadDiagnostic("downloads.start_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "backend": .label("Emby"),
                    "phase": .label("original_not_directly_downloadable"),
                    "reasons": .label(decision.transcodeReasons.joined(separator: ",")),
                ])
                lastError[ratingKey] = .transferFailed("Original source no longer directly downloadable.")
                store.setStatus(ratingKey: ratingKey, .failed)
                releaseInFlight(ratingKey: ratingKey)
                refreshRecords()
                return
            }
        }

        var request: URLRequest
        var destination: URL
        var expectedBytes: Int?
        // Both the transcode and compatible-remux lanes are encoder-served, forward-only, and mint a
        // server-side session that MUST be torn down on a terminal transition.
        let useServerSession = (route != .original)
        do {
            switch route {
            case .original:
                let ext = decision.container ?? part?.container ?? media?.container ?? "mp4"
                destination = store.destinationURL(ratingKey: ratingKey,
                                                   ext: ext.isEmpty ? "mp4" : ext)
                request = try EmbyLibrary.downloadOriginalRequest(
                    server: server, token: token, identity: identity, userId: userId,
                    itemId: itemId, mediaSourceId: decision.mediaSourceId, container: ext)
                // Emby's Part.size is nil — MediaSource.Size is the only storage signal.
                expectedBytes = decision.size

            case .compatibleRemux:
                // #83: copy the original video into MP4, transcode audio→AAC as needed. Output keeps
                // original video bytes → expected size ≈ source size (the AVPlayer probe + HEVC tag
                // fixup are the correctness gate; a server copy failure falls to a retry, not silent
                // corruption).
                destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                request = try EmbyLibrary.compatibleRemuxDownloadRequest(
                    server: server, token: token, identity: identity, userId: userId,
                    itemId: itemId, mediaSourceId: decision.mediaSourceId,
                    playSessionId: decision.playSessionId,
                    videoCodec: remuxEligibility.videoCodec ?? "h264",
                    copyAudio: remuxEligibility.copiesAudio,
                    audioBitrate: 192_000)
                expectedBytes = decision.size

            case .transcode:
                // Emby mints a codecless `/videos/{id}/stream` URL that ffmpeg stream-COPIES and
                // fails on (HTTP 500) for HEVC/DTS sources; build the EXPLICIT static `stream.mp4`
                // transcode URL with the minted PlaySessionId instead (see transcodedDownloadRequest).
                destination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                // Transcode is rendered as it downloads → estimate, no Content-Length.
                let profile = Self.jellyfinTranscodeProfile(named: {
                    if case .optimize(let targetName) = choice { return targetName }
                    return Self.jellyfinDefaultDownloadPreset
                }())
                request = try EmbyLibrary.transcodedDownloadRequest(
                    server: server, token: token, identity: identity, userId: userId,
                    itemId: itemId, mediaSourceId: decision.mediaSourceId,
                    playSessionId: decision.playSessionId,
                    videoBitrate: profile.videoBitrateBps,
                    audioBitrate: 192_000)
                expectedBytes = TranscodeSizeEstimator.bytes(durationMs: item.duration,
                                                             videoBitrateBps: profile.videoBitrateBps)
            }
        } catch {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Emby"),
                "error": .error(error),
            ])
            lastError[ratingKey] = (error as? DownloadError) ?? .transferFailed(String(describing: error))
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
            return
        }

        store.upsert(DownloadRecord(ratingKey: ratingKey, title: item.title,
                                    localURL: destination, bytes: 0, progress: 0,
                                    metadata: metadata))
        // #84: the authoritative media-source id comes from the PlaybackInfo decision; persist it
        // (replacing the pre-decision hint) so a retry can re-issue without re-deriving.
        if !decision.mediaSourceId.isEmpty, decision.mediaSourceId != embyMediaSourceHint {
            store.setMediaSourceID(ratingKey: ratingKey, decision.mediaSourceId)
        }
        refreshRecords()
        // #102: cache the poster locally (best-effort) so artwork shows offline. The Emby image
        // endpoint needs the authenticated request (token + userId in the header), unlike Plex.
        cacheEmbyPoster(ratingKey: ratingKey, item: item, server: server,
                        token: token, identity: identity, userId: userId)
        // #88/#89: cache per-chapter images for the offline Chapters rail AND the Emby offline
        // scrubber. This is a static `/Items/{id}/Images/Chapter/{index}` GET — no PlaySessionId /
        // encoder negotiation — so it is safe to fire here independent of the media transfer.
        cacheChapterImages(ratingKey: ratingKey, item: item, backend: .emby,
                           server: server, token: token)

        beginBackgroundTransfer(ratingKey: ratingKey, backendLabel: "Emby",
                                choiceLabel: route == .original ? "original"
                                    : route == .compatibleRemux ? "optimize_compatible"
                                    : Self.diagnosticChoiceLabel(choice),
                                urlShape: request.url, expectedBytes: expectedBytes,
                                releaseInFlightOnFailure: true) {
            if useServerSession {
                // Transcode/remux download: rate is encoder-gated (served as it renders), forward-only
                // (not range-resumable), and the minted PlaySessionId MUST be torn down on terminal
                // transition. #84: persist it onto the row so a hard app kill can still tear the
                // encoder down on next launch.
                transcodeSourcedDownloads.insert(ratingKey)
                embyPlaySessionByRatingKey[ratingKey] = decision.playSessionId
                store.setPlaySessionID(ratingKey: ratingKey, decision.playSessionId)
            }
            try session.start(ratingKey: ratingKey,
                              with: request,
                              to: destination,
                              expectedBytes: expectedBytes,
                              byteRangeCheckpoint: route == .original)
        }
    }

    /// Extract an Emby `mediaSourceId` from a `MediaItem`'s synthesized part keys
    /// (`emby://item/{itemId}/media/{mediaSourceId}`). The authoritative id comes from the
    /// download PlaybackInfo decision; this only seeds the PlaybackInfo `MediaSourceId` hint.
    private static func embyMediaSourceID(media: Media?, part: Part?) -> String? {
        let keys = [part?.key] + (media?.part.map(\.key) ?? [])
        for key in keys.compactMap({ $0 }) {
            guard let marker = key.range(of: "/media/") else { continue }
            let source = String(key[marker.upperBound...])
            if !source.isEmpty { return source }
        }
        return nil
    }
}
