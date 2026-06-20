import Testing
import Foundation
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

    /// Strip any token / api_key value AND the live server scheme+host from a string before
    /// logging it. The repo will be public — we log the URL *shape* (path + query keys), never
    /// the real hostname or any credential.
    private func redact(_ string: String, token: String, server: URL) -> String {
        var out = string
        if !token.isEmpty {
            out = out.replacingOccurrences(of: token, with: "<redacted-token>")
        }
        // Replace the live scheme://host[:port] prefix with a placeholder.
        if let scheme = server.scheme, let host = server.host {
            let port = server.port.map { ":\($0)" } ?? ""
            out = out.replacingOccurrences(of: "\(scheme)://\(host)\(port)", with: "<server>")
            // Also catch a bare host occurrence (defensive).
            out = out.replacingOccurrences(of: host, with: "<host>")
        }
        // Belt-and-braces: scrub any api_key=… query value even if the token differs.
        out = out.replacingOccurrences(
            of: #"(?i)(api_key=)[^&\s"]+"#,
            with: "$1<redacted>",
            options: .regularExpression)
        return out
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
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
            let safeURL = redact(resolved.url.absoluteString, token: cfg.token, server: cfg.server)
            print(">>> LIVE [resolveStream] playMethod=\(resolved.playMethod) usesServerEncoding=\(resolved.usesServerEncoding) headerKeys=\(resolved.requiredHTTPHeaders.keys.sorted()) url=\(safeURL)")
            print(">>> LIVE [resolveStream] sourceMeta: container=\(resolved.sourceMetadata.container ?? "nil") \(resolved.sourceMetadata.width.map(String.init) ?? "?")x\(resolved.sourceMetadata.height.map(String.init) ?? "?") bitrateKbps=\(resolved.sourceMetadata.bitrate.map(String.init) ?? "nil") video=\(resolved.sourceMetadata.videoCodec ?? "nil") audio=\(resolved.sourceMetadata.audioCodec ?? "nil")")
            #expect(resolved.url.scheme != nil, "resolved stream URL should be absolute")
            #expect(!resolved.playSessionId.isEmpty, "resolved result should carry a PlaySessionId")
        }
    }
}
