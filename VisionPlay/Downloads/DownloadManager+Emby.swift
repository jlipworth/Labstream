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
                             mediaSourceIDOverride: String? = nil,
                             deferStaticStartWhenQueuePaused: Bool = false) async {
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

        let selection = DownloadMediaSelectionPolicy.selection(item: item, mediaIndex: mediaIndex, partIndex: partIndex)
        let media = selection.media
        let part = selection.part
        let resolutionLabel = DownloadPresetPolicy.displayResolutionLabel(choice: choice, chosenMedia: media)
        // Pre-decision media-source hint; the authoritative id (from PlaybackInfo) is persisted
        // onto the row after the decision is known (see below).
        let embyMediaSourceHint = mediaSourceIDOverride ?? selection.mediaSourceID
        var metadata = Self.offlineMetadata(from: item, resolutionLabel: resolutionLabel,
                                            mediaIndex: mediaIndex, partIndex: partIndex,
                                            optimizeTargetName: {
                                                if case .optimize(let targetName) = choice { return targetName }
                                                return nil
                                            }(),
                                            session: backendSession,
                                            mediaSourceID: embyMediaSourceHint,
                                            downloadLane: DownloadChoicePolicy.downloadLane(for: choice),
                                            serverPreparedVersion: DownloadChoicePolicy.isServerPreparedVersion(for: choice))
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
            lastError[ratingKey] = (error as? DownloadError) ?? .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer"))
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
        if DownloadChoicePolicy.isServerPreparedVersion(for: choice),
           let correctedResolution = DownloadResolutionLabel.label(width: nil, height: decision.height) {
            metadata.resolutionLabel = correctedResolution
        }

        // Three-way route detection against the AUTHORITATIVE negotiated verdict:
        //   .original          ⇔ negotiated DirectPlay AND locally playable container
        //   .compatibleRemux   ⇔ user chose it AND source video copyable (#83)
        //   .transcode         ⇔ otherwise (forced h264/aac re-encode)
        // The user's `.optimize` choice always forces the transcode lane.
        let containerGate = EmbyDownloadRouter.containerGate(part: part, negotiatedContainer: decision.container)
        let remuxEligibility = OfflineDownloadDecision.compatibleRemuxEligibility(
            videoCodec: decision.videoCodec, audioCodec: decision.audioCodec,
            sourceContainer: decision.container)
        // #135 Stage 5a: the three-way route decision (#112/#126 existing-version + #83 compatible
        // remux, all against the AUTHORITATIVE negotiated verdict) lives in the pure, tested
        // `EmbyDownloadRouter`. `.original`/`.existingVersion` negotiate identically (a directly
        // playable local-container file downloads byte-for-byte, else transcode); `.optimizeCompatible`
        // stays a remux only while the source video is stream-copy eligible; `.optimize` always transcodes.
        let intent = EmbyDownloadRouter.intent(for: choice)
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

        // Emby convert-then-download (default for non-direct downloads): live transcodes are
        // ephemeral/non-resumable, so optimizer choices reroute to a persistent server Convert job,
        // while static-only choices fail closed instead of silently accepting a forward-only stream.
        switch EmbyDownloadRoutePlan.action(route: route, choice: choice) {
        case .startTransfer:
            break
        case .rerouteConvert(let targetName):
            await triggerConvertAndDownload(item: item, targetName: targetName,
                                            metadata: metadata, session: backendSession)
            return
        case .fail(let reason):
            var fields: [String: DiagnosticFieldValue] = [
                "download_id": .identifier(ratingKey),
                "phase": .label(reason.rawValue),
                "reasons": .label(decision.transcodeReasons.joined(separator: ",")),
            ]
            let event: String
            switch reason {
            case .convertedNotDirectlyDownloadable:
                event = "downloads.convert_failed"
            case .originalNotDirectlyDownloadable:
                event = "downloads.start_failed"
                fields["backend"] = .label("Emby")
            }
            recordDownloadDiagnostic(event, fields: fields)
            lastError[ratingKey] = .transferFailed(reason.userMessage)
            store.setStatus(ratingKey: ratingKey, .failed)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
            return
        }

        var request: URLRequest
        var destination: URL
        var expectedBytes: Int?
        // Both the transcode and compatible-remux lanes are encoder-served, forward-only, and mint a
        // server-side session that MUST be torn down on a terminal transition.
        let useServerSession = EmbyDownloadRoutePlan.useServerSession(for: route)
        do {
            switch route {
            case .original:
                let ext = decision.container.flatMap { $0.isEmpty ? nil : $0 }
                    ?? DownloadMediaSelectionPolicy.containerExtension(selection: selection)
                destination = store.destinationURL(ratingKey: ratingKey, ext: ext)
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
                let profile = DownloadPresetPolicy.jellyfinTranscodeProfile(named: {
                    if case .optimize(let targetName) = choice { return targetName }
                    return DownloadPresetPolicy.jellyfinDefaultDownloadPreset
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
            lastError[ratingKey] = (error as? DownloadError) ?? .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer"))
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
        // Emby optimized/converted downloads are often handed off as a new static MediaSource that
        // does not carry subtitle streams. Cache compatible text sidecars from the source
        // MediaSource when this call is a convert-then-static override; otherwise use the
        // negotiated download source. This mirrors Jellyfin's sidecar path without relying on the
        // server to bake subtitles into the optimized MP4.
        let subtitleMediaSourceID = mediaSourceIDOverride == nil ? decision.mediaSourceId
            : (selection.mediaSourceID ?? decision.mediaSourceId)
        cacheEmbyTextSubtitles(ratingKey: ratingKey, itemId: itemId,
                               mediaSourceId: subtitleMediaSourceID, part: part,
                               server: server, token: token, identity: identity, userId: userId)

        if deferStaticStartWhenQueuePaused, isQueuePaused, route == .original {
            store.setStatus(ratingKey: ratingKey, .paused)
            lastError[ratingKey] = .interruptedResumable
            releaseInFlight(ratingKey: ratingKey)
            recordDownloadDiagnostic("downloads.start_deferred_queue_paused", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Emby"),
                "choice": .label("existing_version"),
                "reason": .label("convert_handoff"),
                "expected_bytes": .bytes(expectedBytes),
            ])
            refreshRecords()
            return
        }

        beginBackgroundTransfer(DownloadTransferStartPlan(
            ratingKey: ratingKey,
            backendLabel: "Emby",
            choiceLabel: EmbyDownloadRoutePlan.diagnosticChoiceLabel(
                route: route,
                choice: choice,
                choiceLabel: DownloadChoicePolicy.diagnosticChoiceLabel(choice)),
            urlShape: request.url,
            expectedBytes: expectedBytes,
            releaseInFlightOnFailure: true
        )) {
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
                              byteRangeCheckpoint: EmbyDownloadRoutePlan.usesByteRangeCheckpoint(for: route),
                              resetRangeRestartCounters: !consumeRangeRestartCounterPreservation(ratingKey: ratingKey))
        }
    }

}
