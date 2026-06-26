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
            self.identity = EmbyClientIdentity(
                client: "VisionPlay",
                device: "Apple Vision Pro",
                deviceId: env["EMBY_LIVE_DEVICE_ID"] ?? "visionplay-emby-live-probe",
                version: "0.1.0")
        }
    }

    // Scrubbing is centralized in `LiveProbeConfig.redact` (shared by every Plex + Emby probe);
    // its default credential-key set already covers `api_key`.

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
    }

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
        let (_, stopStatus) = try await send(stop)
        print(">>> LIVE [\(label)] ActiveEncodings DELETE HTTP \(stopStatus)")
        #expect((200..<300).contains(stopStatus) || [400, 404, 410].contains(stopStatus),
                "active encoding cleanup should return success or already-gone status, got \(stopStatus)")
    }

    @Test func liveEmbyProbe() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> LIVE skipped: set EMBY_LIVE_SERVER / EMBY_LIVE_TOKEN / EMBY_LIVE_USER_ID / EMBY_LIVE_ITEM_ID to run.")
            return
        }

        // (a) GET /System/Info/Public — UNAUTHENTICATED pre-login validation.
        do {
            let req = try EmbyAuth.serverInfoRequest(server: cfg.server)
            let (data, status) = try await send(req)
            print(">>> LIVE [serverInfo] HTTP \(status), \(data.count) bytes")
            #expect(status == 200, "serverInfo expected HTTP 200, got \(status)")
            let info = try JSONDecoder().decode(EmbyServerInfo.self, from: data)
            print(">>> LIVE [serverInfo] decoded: name=\(info.serverName ?? "nil") version=\(info.version ?? "nil") id=\(info.id != nil ? "<set>" : "nil")")
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
            let (data, status) = try await send(req)
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
            let (data, status) = try await send(req)
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
            let (discoverData, discoverStatus) = try await send(discoverReq)
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
            let (subData, subStatus) = try await send(subReq)
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
                let (_, fetchStatus) = try await send(fetch)
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
}
