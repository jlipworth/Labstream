import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Headless integration probe against a REAL Emby Media Server (Emby backend lane). This hits
/// the network, so it is OPT-IN: it runs only when the required env vars are present and
/// otherwise returns immediately, leaving plain `swift test` and CI hermetic. NOTHING here is
/// hardcoded — server, token, user id and item id all arrive via the environment, so no secret
/// is ever committed.
///
/// Why this faithfully reproduces the app: the Emby request builders (`EmbyAuth`,
/// `EmbyLibrary`, `EmbyPlayback`) produce the exact `URLRequest`s the app will send, and we
/// dispatch them through a bare `URLSession.shared.data(for:)` — the same shape the client
/// uses. So decoding the responses here proves the PMSKit Emby decoders match the live wire.
///
/// The point is to confirm the Emby decoders (`EmbyServerInfo`, `EmbyBaseItemDto`,
/// `EmbyPlaybackInfoResponse`) parse the REAL server bodies and that `resolveStream` produces a
/// playable URL — the live body is the source of truth, and the decoders are fixed against it.
///
/// Run it (creds live in a gitignored env file — see scripts/emby-live.env):
///   ./scripts/live-emby-probe.sh
/// or directly:
///   set -a; source scripts/emby-live.env; set +a
///   cd PMSKit && swift test --filter LiveEmbyProbe
///
/// SECURITY: this NEVER prints the token, api_key, or any `X-Emby-Token` value — every URL and
/// header set is redacted before logging.
struct LiveEmbyProbeTests {

    /// Required env inputs. Returns nil (→ test is a no-op) when any are absent.
    private struct LiveConfig {
        let server: URL
        let token: String
        let userId: String
        let itemId: String
        let maxStreamingBitrate: Int
        let timelineOffsetTicks: Int?
        let identity: EmbyClientIdentity

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let serverString = env["EMBY_LIVE_SERVER"],
                  let server = try? EmbyServerURL.normalized(serverString),
                  let token = env["EMBY_LIVE_TOKEN"], !token.isEmpty,
                  let userId = env["EMBY_LIVE_USER_ID"], !userId.isEmpty,
                  let itemId = env["EMBY_LIVE_ITEM_ID"], !itemId.isEmpty
            else { return nil }
            self.server = server
            self.token = token
            self.userId = userId
            self.itemId = itemId
            self.maxStreamingBitrate = env["EMBY_LIVE_MAX_BITRATE"].flatMap(Int.init) ?? 200_000_000
            self.timelineOffsetTicks = env["EMBY_LIVE_TIMELINE_OFFSET_SECONDS"]
                .flatMap(Int.init)
                .map { max(0, $0) * 10_000_000 }
            self.identity = EmbyClientIdentity(
                client: "Labstream",
                device: "Apple Vision Pro",
                deviceId: env["EMBY_LIVE_DEVICE_ID"] ?? "labstream-emby-live-probe",
                version: "0.1.0")
        }
    }

    // Scrubbing is centralized in `LiveProbeConfig.redact` (shared by every Plex + Emby probe);
    // its default credential-key set already covers `api_key`.
    private let transport = LiveProbeTransport()

    private func stopActiveEncodingIfNeeded(_ result: EmbyPlaybackOpenResult,
                                            cfg: LiveConfig,
                                            label: String) async throws {
        guard result.usesServerEncoding else { return }
        let stop = try EmbyLibrary.activeEncodingStopRequest(
            server: cfg.server,
            token: cfg.token,
            identity: cfg.identity,
            userId: cfg.userId,
            deviceId: cfg.identity.deviceId,
            playSessionId: result.playSessionId)
        let (_, stopStatus) = try await transport.send(stop)
        print(">>> LIVE [\(label)] ActiveEncodings DELETE HTTP \(stopStatus)")
        #expect((200..<300).contains(stopStatus) || [400, 404, 410].contains(stopStatus),
                "active encoding cleanup should return success or already-gone status, got \(stopStatus)")
    }

    @Test func liveEmbyProbe() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> EMBY VERDICT: SKIP — set EMBY_LIVE_SERVER / EMBY_LIVE_TOKEN / EMBY_LIVE_USER_ID / EMBY_LIVE_ITEM_ID to run.")
            return
        }

        // (a) GET /System/Info/Public — UNAUTHENTICATED pre-login validation.
        do {
            let req = try EmbyAuth.serverInfoRequest(server: cfg.server)
            let (data, status) = try await transport.send(req)
            print(">>> LIVE [serverInfo] HTTP \(status), \(data.count) bytes")
            #expect(status == 200, "serverInfo expected HTTP 200, got \(status)")
            let info = try JSONDecoder().decode(EmbyServerInfo.self, from: data)
            print(">>> LIVE [serverInfo] decoded: name=\(LiveProbeLogger.serverNameSummary(info.serverName)) version=\(info.version ?? "nil") id=\(LiveProbeLogger.idPresence(info.id))")
            #expect(info.version != nil, "serverInfo should decode a Version")
        }

        // (b) GET /Users/{UserId}/Items — decode via EmbyBaseItemDto.
        do {
            let req = try EmbyLibrary.itemsRequest(
                server: cfg.server,
                token: cfg.token,
                identity: cfg.identity,
                userId: cfg.userId,
                recursive: true,
                includeItemTypes: "Movie",
                fields: "MediaSources,Overview,Chapters,Genres")
            let (data, status) = try await transport.send(req)
            print(">>> LIVE [items] HTTP \(status), \(data.count) bytes")
            #expect(status == 200, "items expected HTTP 200, got \(status)")
            let response = try EmbyItemsResponse.decode(from: data)
            print(">>> LIVE [items] decoded: count=\(response.items.count) totalRecordCount=\(response.totalRecordCount ?? -1)")
            #expect(!response.items.isEmpty, "items list should not be empty")
            if let first = response.items.first {
                let mediaItem = first.toMediaItem()
                let durationSecs = first.runTimeTicks.map { $0 / 10_000_000 }
                print(">>> LIVE [items] first: type=\(first.type ?? "nil") year=\(first.productionYear.map(String.init) ?? "nil") durationSecs=\(durationSecs.map(String.init) ?? "nil") mediaSources=\(first.mediaSources.count) primaryTag=\(first.imageTags["Primary"] != nil ? "<set>" : "nil") toMediaItem=\(mediaItem != nil ? "ok" : "nil")")
                if let src = first.mediaSources.first {
                    let video = src.mediaStreams.first { $0.type == "Video" }
                    let audio = src.mediaStreams.first { $0.type == "Audio" }
                    print(">>> LIVE [items] firstSource: container=\(src.container ?? "nil") bitrate=\(src.bitrate.map(String.init) ?? "nil") directPlay=\(src.supportsDirectPlay.map(String.init) ?? "nil") streams=\(src.mediaStreams.count) video=\(video?.codec ?? "nil") audio=\(audio?.codec ?? "nil")")
                }
                #expect(mediaItem != nil, "first Movie should map to a MediaItem")
            }
        }

        // (c) POST /Items/{itemId}/PlaybackInfo — decode and resolveStream.
        do {
            let req = try EmbyPlayback.playbackInfoRequest(
                server: cfg.server,
                token: cfg.token,
                identity: cfg.identity,
                userId: cfg.userId,
                itemId: cfg.itemId,
                maxStreamingBitrate: cfg.maxStreamingBitrate)
            let (data, status) = try await transport.send(req)
            print(">>> LIVE [playbackInfo] HTTP \(status), \(data.count) bytes")
            #expect(status == 200, "playbackInfo expected HTTP 200, got \(status)")
            let response = try EmbyPlaybackInfoResponse.decode(from: data)
            print(">>> LIVE [playbackInfo] decoded: playSessionId=\(response.playSessionId != nil ? "<set>" : "nil") mediaSources=\(response.mediaSources.count)")
            #expect(response.playSessionId != nil, "playbackInfo should return a PlaySessionId")
            #expect(!response.mediaSources.isEmpty, "playbackInfo should return MediaSources")
            for (i, src) in response.mediaSources.enumerated() {
                print(">>> LIVE [playbackInfo] source[\(i)]: id=\(src.id != nil ? "<set>" : "nil") container=\(src.container ?? "nil") directPlay=\(src.supportsDirectPlay) directStream=\(src.supportsDirectStream) transcode=\(src.supportsTranscoding) hasTranscodingUrl=\(src.transcodingURL != nil) hasDirectStreamUrl=\(src.directStreamURL != nil) subProtocol=\(src.transcodingSubProtocol ?? "nil") transcodeContainer=\(src.transcodingContainer ?? "nil") addApiKey=\(src.addApiKeyToDirectStreamURL.map(String.init) ?? "nil") liveStreamId=\(src.liveStreamID != nil ? "<set>" : "nil")")
            }

            let resolved = try EmbyPlayback.resolveStream(
                response: response,
                server: cfg.server,
                identity: cfg.identity,
                token: cfg.token,
                userId: cfg.userId,
                itemId: cfg.itemId)
            // Redact api_key / token before printing the resolved URL.
            let safeURL = LiveProbeConfig.redact(resolved.url.absoluteString, token: cfg.token, server: cfg.server)
            print(">>> LIVE [resolveStream] playMethod=\(resolved.playMethod) usesServerEncoding=\(resolved.usesServerEncoding) headerKeys=\(resolved.requiredHTTPHeaders.keys.sorted()) url=\(safeURL)")
            print(">>> LIVE [resolveStream] sourceMeta: container=\(resolved.sourceMetadata.container ?? "nil") \(resolved.sourceMetadata.width.map(String.init) ?? "?")x\(resolved.sourceMetadata.height.map(String.init) ?? "?") bitrateKbps=\(resolved.sourceMetadata.bitrate.map(String.init) ?? "nil") video=\(resolved.sourceMetadata.videoCodec ?? "nil") audio=\(resolved.sourceMetadata.audioCodec ?? "nil")")
            #expect(resolved.url.scheme != nil, "resolved stream URL should be absolute")
            #expect(!resolved.playSessionId.isEmpty, "resolved result should carry a PlaySessionId")
        }

        // (d) Subtitle burn-in reopen: discover a subtitle stream index, POST PlaybackInfo WITH
        // that SubtitleStreamIndex (mirrors `PlaybackController.selectSubtitle`'s Emby path), and
        // confirm the server returns a usable stream that fetches 200. Emby 4.9.3 does not embed
        // subtitle renditions in its HLS, so the only way to render a subtitle is server burn-in,
        // which forces a transcode. Skips gracefully when the item carries no subtitle streams.
        do {
            // Discover a subtitle index from a no-subtitle PlaybackInfo.
            let discoverReq = try EmbyPlayback.playbackInfoRequest(
                server: cfg.server,
                token: cfg.token,
                identity: cfg.identity,
                userId: cfg.userId,
                itemId: cfg.itemId,
                maxStreamingBitrate: cfg.maxStreamingBitrate)
            let (discoverData, discoverStatus) = try await transport.send(discoverReq)
            #expect(discoverStatus == 200, "discover playbackInfo expected HTTP 200, got \(discoverStatus)")
            let discover = try EmbyPlaybackInfoResponse.decode(from: discoverData)
            let subtitleIndices = discover.mediaSources
                .flatMap { $0.mediaStreams }
                .filter { $0.type == "Subtitle" }
                .compactMap { $0.index }
            print(">>> LIVE [subtitle] discovered subtitle stream indices=\(subtitleIndices)")
            guard let subtitleIndex = subtitleIndices.first else {
                print(">>> LIVE [subtitle] item has no subtitle streams — skipping burn-in check.")
                return
            }

            let subReq = try EmbyPlayback.playbackInfoRequest(
                server: cfg.server,
                token: cfg.token,
                identity: cfg.identity,
                userId: cfg.userId,
                itemId: cfg.itemId,
                maxStreamingBitrate: cfg.maxStreamingBitrate,
                subtitleStreamIndex: subtitleIndex)
            let (subData, subStatus) = try await transport.send(subReq)
            print(">>> LIVE [subtitle] PlaybackInfo(subtitleStreamIndex=\(subtitleIndex)) HTTP \(subStatus), \(subData.count) bytes")
            #expect(subStatus == 200, "subtitle playbackInfo expected HTTP 200, got \(subStatus)")
            let subResponse = try EmbyPlaybackInfoResponse.decode(from: subData)

            let resolvedSub = try EmbyPlayback.resolveStream(
                response: subResponse,
                server: cfg.server,
                identity: cfg.identity,
                token: cfg.token,
                userId: cfg.userId,
                itemId: cfg.itemId,
                subtitleStreamIndex: subtitleIndex)
            print(">>> LIVE [subtitle] resolved playMethod=\(resolvedSub.playMethod) usesServerEncoding=\(resolvedSub.usesServerEncoding)")
            // Burning a subtitle into the picture requires re-encoding the video → transcode.
            #expect(resolvedSub.playMethod == .transcode,
                    "selecting a subtitle should force a transcode (server burn-in), got \(resolvedSub.playMethod)")

            // The burned-in stream URL must actually fetch. GET it and confirm a success status
            // (HLS playlists are small; this just proves the server accepts the burn-in request).
            do {
                var fetch = URLRequest(url: resolvedSub.url)
                for (k, v) in resolvedSub.requiredHTTPHeaders { fetch.setValue(v, forHTTPHeaderField: k) }
                let (_, fetchStatus) = try await transport.send(fetch)
                print(">>> LIVE [subtitle] burn-in stream GET HTTP \(fetchStatus)")
                #expect((200..<400).contains(fetchStatus),
                        "burn-in stream should fetch with a success status, got \(fetchStatus)")
            } catch {
                try? await stopActiveEncodingIfNeeded(resolvedSub, cfg: cfg, label: "subtitle")
                throw error
            }
            try await stopActiveEncodingIfNeeded(resolvedSub, cfg: cfg, label: "subtitle")
        }
    }

    /// Phase 3D/4A readiness proof through the public Emby wrappers that delegate to the shared
    /// MediaBrowser request factory and progress-plan implementations. A distinct resume mutation
    /// is opt-in and restored before the probe returns.
    @Test func liveEmbySharedBrowseAndTimeline() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> EMBY-SHARED VERDICT: SKIP — set EMBY_LIVE_SERVER / EMBY_LIVE_TOKEN / EMBY_LIVE_USER_ID / EMBY_LIVE_ITEM_ID to run.")
            return
        }

        let viewsRequest = try EmbyLibrary.userViewsRequest(server: cfg.server,
                                                            token: cfg.token,
                                                            identity: cfg.identity,
                                                            userId: cfg.userId)
        let (viewsData, viewsStatus) = try await transport.send(viewsRequest)
        print(">>> EMBY-SHARED [views] HTTP \(viewsStatus), \(viewsData.count) bytes")
        #expect((200..<300).contains(viewsStatus), "Emby views expected 2xx, got \(viewsStatus)")
        guard (200..<300).contains(viewsStatus) else { throw URLError(.badServerResponse) }
        let views = try JSONDecoder().decode(EmbyUserViewsResponse.self, from: viewsData)
        #expect(!views.items.isEmpty, "Emby account should expose at least one user view")
        guard !views.items.isEmpty else { throw URLError(.resourceUnavailable) }

        let originalItem = try await fetchTimelineItem(cfg)
        guard let mediaSourceID = originalItem.mediaSources.first?.id, !mediaSourceID.isEmpty else {
            Issue.record("Configured Emby item has no media-source id; timeline proof cannot run")
            return
        }
        let originalTicks = originalItem.userData?.playbackPositionTicks ?? 0
        let targetTicks = cfg.timelineOffsetTicks ?? originalTicks

        do {
            try await reportTimeline(positionTicks: targetTicks,
                                     mediaSourceID: mediaSourceID,
                                     playSessionID: UUID().uuidString,
                                     cfg: cfg)
            if cfg.timelineOffsetTicks != nil {
                let observed = try await waitForTimelinePosition(targetTicks, cfg: cfg)
                #expect(observed == targetTicks,
                        "Emby resume readback did not observe the explicitly requested offset")
                guard observed == targetTicks else { throw URLError(.cannotParseResponse) }
            } else {
                print(">>> EMBY-SHARED [timeline] READBACK SKIP — set EMBY_LIVE_TIMELINE_OFFSET_SECONDS on a test account for mutation proof.")
            }
        } catch {
            if targetTicks != originalTicks {
                try? await reportTimeline(positionTicks: originalTicks,
                                          mediaSourceID: mediaSourceID,
                                          playSessionID: UUID().uuidString,
                                          cfg: cfg,
                                          label: "restore")
            }
            throw error
        }

        if targetTicks != originalTicks {
            try await reportTimeline(positionTicks: originalTicks,
                                     mediaSourceID: mediaSourceID,
                                     playSessionID: UUID().uuidString,
                                     cfg: cfg,
                                     label: "restore")
            let restored = try await waitForTimelinePosition(originalTicks, cfg: cfg)
            #expect(restored == originalTicks, "Emby probe did not restore the original resume offset")
            guard restored == originalTicks else { throw URLError(.cannotParseResponse) }
        }

        print(">>> EMBY-SHARED VERDICT: PASS — shared browse wrappers decoded live responses and timeline wrappers returned 2xx\(cfg.timelineOffsetTicks == nil ? "; resume readback not requested" : "; resume readback + restore passed").")
    }

    private func fetchTimelineItem(_ cfg: LiveConfig) async throws -> EmbyBaseItemDto {
        let request = try EmbyLibrary.itemRequest(server: cfg.server,
                                                  token: cfg.token,
                                                  identity: cfg.identity,
                                                  userId: cfg.userId,
                                                  itemId: cfg.itemId)
        let (data, status) = try await transport.send(request)
        print(">>> EMBY-SHARED [metadata] HTTP \(status), \(data.count) bytes")
        #expect((200..<300).contains(status), "Emby metadata expected 2xx, got \(status)")
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(EmbyBaseItemDto.self, from: data)
    }

    private func reportTimeline(positionTicks: Int,
                                mediaSourceID: String,
                                playSessionID: String,
                                cfg: LiveConfig,
                                label: String = "timeline") async throws {
        let requests = try [
            ("playing", EmbyPlayback.playingRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, itemId: cfg.itemId, mediaSourceId: mediaSourceID,
                playSessionId: playSessionID, playMethod: .directPlay, positionTicks: positionTicks)),
            ("progress", EmbyPlayback.progressRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, itemId: cfg.itemId, mediaSourceId: mediaSourceID,
                playSessionId: playSessionID, playMethod: .directPlay,
                positionTicks: positionTicks, isPaused: false)),
            ("paused", EmbyPlayback.progressRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, itemId: cfg.itemId, mediaSourceId: mediaSourceID,
                playSessionId: playSessionID, playMethod: .directPlay,
                positionTicks: positionTicks, isPaused: true)),
            ("stopped", EmbyPlayback.stoppedRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, itemId: cfg.itemId, mediaSourceId: mediaSourceID,
                playSessionId: playSessionID, playMethod: .directPlay, positionTicks: positionTicks)),
        ]

        for (event, request) in requests {
            let (_, status) = try await transport.send(request)
            print(">>> EMBY-SHARED [\(label).\(event)] HTTP \(status)")
            #expect((200..<300).contains(status), "Emby \(event) expected 2xx, got \(status)")
            guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        }
    }

    private func waitForTimelinePosition(_ expected: Int, cfg: LiveConfig) async throws -> Int {
        var observed = -1
        for attempt in 0..<8 {
            observed = try await fetchTimelineItem(cfg).userData?.playbackPositionTicks ?? 0
            if observed == expected { return observed }
            if attempt < 7 { try await Task.sleep(for: .milliseconds(500)) }
        }
        return observed
    }
}
