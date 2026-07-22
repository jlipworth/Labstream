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
                             audioStreamIndex: Int? = nil,
                             mediaSourceIDOverride: String? = nil,
                             deferStaticStartWhenQueuePaused: Bool = false,
                             requestedProfileLabelOverride: String? = nil,
                             allowReplacingExistingActiveRow: Bool = false) async {
        let itemId = item.ratingKey
        let ratingKey = DownloadRecordIdentity.recordKey(for: itemId, backend: .emby)
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
        guard let startAttempt = acquireStartAttempt(ratingKey: ratingKey,
                                                     backend: "Emby",
                                                     allowReplacingExistingActiveRow: allowReplacingExistingActiveRow) else { return }
        let attemptKey = DownloadAttemptKey(
            ratingKey: ratingKey, attemptID: startAttempt.attemptID)
        lastError[ratingKey] = nil
        // No `defer { activeJobs.remove }` — same in-flight-lifetime contract as the other lanes:
        // `session.start` only kicks off the transfer, so protection (and the encoder-teardown
        // PlaySessionId) is released terminally from `refreshRecords`/`releaseInFlight`.

        if rejectIfOverStorageLimit(ratingKey: ratingKey, backend: "Emby",
                                    expectedBytes: estimatedBytes(for: item, choice: choice,
                                                                  mediaIndex: mediaIndex,
                                                                  partIndex: partIndex,
                                                                  backend: .emby)) {
            releaseInFlight(for: attemptKey)
            return
        }

        let selection = DownloadMediaSelectionPolicy.selection(item: item, mediaIndex: mediaIndex, partIndex: partIndex)
        let media = selection.media
        let part = selection.part
        let resolutionLabel = DownloadPresetPolicy.displayResolutionLabel(choice: choice, chosenMedia: media)
        // Pre-decision media-source hint; the authoritative id (from PlaybackInfo) is persisted
        // onto the row after the decision is known (see below).
        let embyMediaSourceHint = mediaSourceIDOverride ?? selection.mediaSourceID
        var metadata = DownloadOfflineMetadataBuilder.metadata(from: item, resolutionLabel: resolutionLabel,
                                            requestedProfileLabel: requestedProfileLabelOverride
                                                ?? DownloadChoicePolicy.requestedProfileLabel(for: choice),
                                            mediaIndex: mediaIndex, partIndex: partIndex,
                                            optimizeTargetName: {
                                                if case .optimize(let targetName) = choice { return targetName }
                                                return nil
                                            }(),
                                            session: backendSession,
                                            mediaSourceID: embyMediaSourceHint,
                                            audioStreamIndex: audioStreamIndex,
                                            downloadLane: DownloadChoicePolicy.downloadLane(for: choice),
                                            serverPreparedVersion: DownloadChoicePolicy.isServerPreparedVersion(for: choice))
        let seedDestination = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        guard persistAttemptSeed(
            DownloadRecord(ratingKey: ratingKey, attemptID: startAttempt.attemptID,
                           title: item.title, localURL: seedDestination,
                           bytes: 0, progress: 0, metadata: metadata),
            for: startAttempt,
            backend: "Emby"
        ) else {
            releaseInFlight(for: attemptKey)
            return
        }
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
                    maxStaticBitrate: 200_000_000,
                    audioStreamIndex: audioStreamIndex)
            } else {
                infoReq = try EmbyPlayback.downloadPlaybackInfoRequest(
                    server: server, token: token, identity: identity,
                    userId: userId, itemId: itemId,
                    mediaSourceId: embyMediaSourceHint,
                    maxStaticBitrate: 200_000_000,
                    audioStreamIndex: audioStreamIndex)
            }
            let (data, response) = try await URLSession.shared.data(for: infoReq)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                recordDownloadDiagnostic("downloads.playback_info_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "backend": .label("Emby"),
                    "status_code": .int(http.statusCode),
                    "phase": .label("download_negotiation"),
                ])
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
            _ = setEmbyAttemptStatus(.failed, for: attemptKey, context: "playback_info")
            clearStaticRangePendingResume(ratingKey: ratingKey)
            releaseInFlight(for: attemptKey)
            refreshRecords()
            return
        }

        // Lens 6 F2: the PlaybackInfo POST above is an await with NO currency check — a
        // delete/pause landing during it used to be fully undone (the row was re-seeded, the
        // minted PlaySessionId persisted, and the transfer started). Exit WITHOUT touching the
        // store; best-effort release of the session the negotiation just minted.
        guard startAttemptStillCurrent(startAttempt, backend: "Emby",
                                       phase: "playback_info") else {
            stopSupersededMediaBrowserEncoder(ratingKey: ratingKey,
                                              playSessionID: decision.playSessionId,
                                              backendKind: .emby,
                                              backendSession: backendSession)
            return
        }

        // EMBY-F6: `.existingVersion` and relaunch/retry handoffs carry an explicit persisted
        // MediaSource id. Emby PlaybackInfo can silently fall back to another source when that
        // version vanished; accepting it would download a different rendition under the old row's
        // intent. Ordinary negotiation (no explicit override) may still use the server's choice.
        guard EmbyDownloadSourceIdentityPolicy.accepts(
            explicitOverride: mediaSourceIDOverride,
            decidedMediaSourceID: decision.mediaSourceId
        ) else {
            stopSupersededMediaBrowserEncoder(ratingKey: ratingKey,
                                              playSessionID: decision.playSessionId,
                                              backendKind: .emby,
                                              backendSession: backendSession)
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label("Emby"),
                "phase": .label("media_source_override_mismatch"),
            ])
            lastError[ratingKey] = .transferFailed(
                "The requested server version is no longer available. Choose another version and retry.")
            _ = setEmbyAttemptStatus(.failed, for: attemptKey, context: "source_mismatch")
            clearStaticRangePendingResume(ratingKey: ratingKey)
            releaseInFlight(for: attemptKey)
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
                                            metadata: metadata, session: backendSession,
                                            attemptKey: attemptKey,
                                            audioStreamIndex: audioStreamIndex)
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
            _ = setEmbyAttemptStatus(.failed, for: attemptKey, context: "route_rejected")
            clearStaticRangePendingResume(ratingKey: ratingKey)
            releaseInFlight(for: attemptKey)
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
                    audioCodec: remuxEligibility.audioCodec,
                    copyAudio: remuxEligibility.copiesAudio,
                    audioBitrate: 192_000,
                    audioStreamIndex: audioStreamIndex)
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
                    audioBitrate: 192_000,
                    audioStreamIndex: audioStreamIndex)
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
            _ = setEmbyAttemptStatus(.failed, for: attemptKey, context: "request_build")
            clearStaticRangePendingResume(ratingKey: ratingKey)
            releaseInFlight(for: attemptKey)
            refreshRecords()
            return
        }

        guard persistEmbyAttemptRecord(
            DownloadRecord(ratingKey: ratingKey, attemptID: startAttempt.attemptID,
                           title: item.title,
                           localURL: destination, bytes: 0, progress: 0,
                           metadata: metadata),
            for: attemptKey, context: "resolved_destination") else {
            releaseInFlight(for: attemptKey)
            return
        }
        // #84: the authoritative media-source id comes from the PlaybackInfo decision; persist it
        // (replacing the pre-decision hint) so a retry can re-issue without re-deriving.
        if !decision.mediaSourceId.isEmpty, decision.mediaSourceId != embyMediaSourceHint {
            guard updateEmbyAttemptMetadata(
                for: attemptKey, context: "media_source", mutate: {
                    $0.mediaSourceID = decision.mediaSourceId
                }) else {
                releaseInFlight(for: attemptKey)
                return
            }
        }
        refreshRecords()
        // #102: cache the poster locally (best-effort) so artwork shows offline. The Emby image
        // endpoint needs the authenticated request (token + userId in the header), unlike Plex.
        cacheEmbyPoster(for: attemptKey, item: item, server: server,
                        token: token, identity: identity, userId: userId)
        cacheEmbyBIF(for: attemptKey, itemId: itemId,
                     mediaSourceId: decision.mediaSourceId,
                     server: server, token: token, identity: identity, userId: userId)
        // #88/#89: cache per-chapter images for the offline Chapters rail AND the Emby offline
        // scrubber. This is a static `/Items/{id}/Images/Chapter/{index}` GET — no PlaySessionId /
        // encoder negotiation — so it is safe to fire here independent of the media transfer.
        cacheChapterImages(for: attemptKey, item: item, backend: .emby,
                           server: server, token: token, userID: userId)
        // Emby optimized/converted downloads are often handed off as a new static MediaSource that
        // does not carry subtitle streams. Cache compatible text sidecars from the source
        // MediaSource when this call is a convert-then-static override; otherwise use the
        // negotiated download source. This mirrors Jellyfin's sidecar path without relying on the
        // server to bake subtitles into the optimized MP4.
        let subtitleMediaSourceID = mediaSourceIDOverride == nil ? decision.mediaSourceId
            : (selection.mediaSourceID ?? decision.mediaSourceId)
        cacheEmbyTextSubtitles(for: attemptKey, itemId: itemId,
                               mediaSourceId: subtitleMediaSourceID, part: part,
                               server: server, token: token, identity: identity, userId: userId)

        if deferStaticStartWhenQueuePaused, isQueuePaused, route == .original {
            guard setEmbyAttemptStatus(
                .paused, for: attemptKey, context: "queue_paused") else { return }
            lastError[ratingKey] = .interruptedResumable
            releaseInFlight(for: attemptKey)
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
            attemptKey: attemptKey,
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
                transcodeSourcedDownloads.insert(attemptKey)
                embyPlaySessionByAttempt[attemptKey] = decision.playSessionId
                guard updateEmbyAttemptMetadata(
                    for: attemptKey, context: "play_session", mutate: {
                        $0.playSessionID = decision.playSessionId
                    }) else {
                    throw DownloadError.transferFailed(
                        "Download ownership changed before transfer start.")
                }
            }
            try session.start(ratingKey: ratingKey,
                              with: request,
                              to: destination,
                              expectedBytes: expectedBytes,
                              byteRangeCheckpoint: EmbyDownloadRoutePlan.usesByteRangeCheckpoint(for: route),
                              resetRangeRestartCounters: !consumeRangeRestartCounterPreservation(ratingKey: ratingKey))
            if useServerSession {
                // The row now has its persisted PlaySessionId and the transfer is registered.
                // Refresh starts the compatible-remux keepalive from the same relaunch-safe
                // candidate path used when a background task is reattached after process death.
                refreshRecords()
            }
        }
    }

    @discardableResult
    func setEmbyAttemptStatus(
        _ status: DownloadStatus,
        for key: DownloadAttemptKey,
        context: String
    ) -> Bool {
        switch store.setStatus(for: key, status) {
        case .applied, .noChange:
            return true
        case .staleOrMissing:
            recordDownloadDiagnostic("downloads.emby_status_owner_stale", fields: [
                "download_id": .identifier(key.ratingKey),
                "context": .label(context),
            ])
            return false
        case .persistenceFailed(let failure):
            recordDownloadDiagnostic("downloads.emby_status_persist_failed", fields: [
                "download_id": .identifier(key.ratingKey),
                "context": .label(context),
                "failure": .label(String(describing: failure)),
            ])
            return false
        }
    }

    @discardableResult
    func updateEmbyAttemptMetadata(
        for key: DownloadAttemptKey,
        context: String,
        mutate: (inout OfflineMetadata) -> Void
    ) -> Bool {
        switch store.updateMetadata(for: key, mutate: mutate) {
        case .applied, .noChange:
            return true
        case .staleOrMissing:
            recordDownloadDiagnostic("downloads.emby_metadata_owner_stale", fields: [
                "download_id": .identifier(key.ratingKey), "context": .label(context),
            ])
            return false
        case .persistenceFailed:
            recordDownloadDiagnostic("downloads.emby_metadata_persist_failed", fields: [
                "download_id": .identifier(key.ratingKey), "context": .label(context),
            ])
            return false
        }
    }

    @discardableResult
    func persistEmbyAttemptRecord(
        _ record: DownloadRecord,
        for key: DownloadAttemptKey,
        context: String
    ) -> Bool {
        switch store.createAttemptOwnedRecord(record, attemptID: key.attemptID) {
        case .committed:
            return true
        case .rejectedOwnership:
            recordDownloadDiagnostic("downloads.emby_record_owner_stale", fields: [
                "download_id": .identifier(key.ratingKey), "context": .label(context),
            ])
            return false
        case .failed:
            recordDownloadDiagnostic("downloads.emby_record_persist_failed", fields: [
                "download_id": .identifier(key.ratingKey), "context": .label(context),
            ])
            return false
        }
    }

}
