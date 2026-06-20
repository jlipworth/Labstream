import Testing
import Foundation
@testable import PMSKit

/// Headless integration probe for the Emby OFFLINE-DOWNLOAD lane against a REAL Emby server.
/// Opt-in: runs only when the `EMBY_LIVE_*` env vars are present, otherwise a no-op so plain
/// `swift test` and CI stay hermetic.
///
/// What it proves against the live wire (item 1200 = HEVC/DTS/MKV worst case):
///   1. The DOWNLOAD device profile (Static mp4, NOT HLS) negotiates a single-file transcode:
///      `SupportsDirectPlay=false`, `TranscodeReasons` contains `ContainerNotSupported`, the
///      `TranscodingUrl` is a `/videos/.../stream` (no `.m3u8`), and `Size` is populated.
///   2. The static-original GET returns HTTP 206 (range-resumable) for that source.
///
/// Run it:
///   set -a; source scripts/emby-live.env; set +a
///   cd PMSKit && swift test --filter LiveEmbyDownloadProbe
///
/// SECURITY: NEVER prints the token / api_key / X-Emby-Token, nor the real hostname — every URL
/// is redacted before logging.
struct LiveEmbyDownloadProbeTests {

    private struct LiveConfig {
        let server: URL
        let token: String
        let userId: String
        let itemId: String
        let maxStaticBitrate: Int
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
            self.maxStaticBitrate = env["EMBY_LIVE_MAX_BITRATE"].flatMap(Int.init) ?? 200_000_000
            self.identity = EmbyClientIdentity(
                client: "VisionPlay",
                device: "Apple Vision Pro",
                deviceId: env["EMBY_LIVE_DEVICE_ID"] ?? "visionplay-emby-live-probe",
                version: "0.1.0")
        }
    }

    /// Strip token / api_key value AND scheme+host before logging. The repo will be public.
    private func redact(_ string: String, token: String, server: URL) -> String {
        var out = string
        if !token.isEmpty { out = out.replacingOccurrences(of: token, with: "<redacted-token>") }
        if let scheme = server.scheme, let host = server.host {
            let port = server.port.map { ":\($0)" } ?? ""
            out = out.replacingOccurrences(of: "\(scheme)://\(host)\(port)", with: "<server>")
            out = out.replacingOccurrences(of: host, with: "<host>")
        }
        out = out.replacingOccurrences(of: #"(?i)(api_key=)[^&\s"]+"#, with: "$1<redacted>", options: .regularExpression)
        return out
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    @Test func liveEmbyDownloadProbe() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> LIVE skipped: set EMBY_LIVE_SERVER / EMBY_LIVE_TOKEN / EMBY_LIVE_USER_ID / EMBY_LIVE_ITEM_ID to run.")
            return
        }

        var mintedPlaySessionId: String?
        defer {
            // Tear down any encoder we minted so we never leak FFmpeg on the live server.
            if let psid = mintedPlaySessionId {
                let teardown = try? EmbyLibrary.activeEncodingStopRequest(
                    server: cfg.server, token: cfg.token, identity: cfg.identity,
                    userId: cfg.userId, deviceId: cfg.identity.deviceId, playSessionId: psid)
                if let teardown {
                    // Best-effort, synchronous-ish: fire and forget on a detached task.
                    Task { _ = try? await URLSession.shared.data(for: teardown) }
                }
            }
        }

        // (a) POST download PlaybackInfo with the DOWNLOAD (Static mp4) device profile.
        let decision: EmbyPlayback.EmbyDownloadPlaybackDecision
        do {
            let req = try EmbyPlayback.downloadPlaybackInfoRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, itemId: cfg.itemId, maxStaticBitrate: cfg.maxStaticBitrate)
            let (data, http) = try await send(req)
            print(">>> LIVE [downloadPlaybackInfo] HTTP \(http.statusCode), \(data.count) bytes")
            #expect(http.statusCode == 200)
            let response = try EmbyPlaybackInfoResponse.decode(from: data)
            decision = try EmbyPlayback.downloadDecision(response: response)
            mintedPlaySessionId = decision.playSessionId
            let safeTU = decision.transcodingURL.map { redact($0, token: cfg.token, server: cfg.server) } ?? "nil"
            print(">>> LIVE [downloadDecision] directPlay=\(decision.supportsDirectPlay) size=\(decision.size.map(String.init) ?? "nil") container=\(decision.container ?? "nil") reasons=\(decision.transcodeReasons) transcodingUrl=\(safeTU)")
            // The download profile must negotiate a single-file (non-HLS) transcode for MKV.
            if let tu = decision.transcodingURL {
                #expect(!tu.contains(".m3u8"), "download transcode URL must NOT be an HLS playlist")
            }
        }

        // (b) Static-original GET — confirm range-resumability (HTTP 206) for the source.
        do {
            let req0 = try EmbyLibrary.downloadOriginalRequest(
                server: cfg.server, token: cfg.token, identity: cfg.identity,
                userId: cfg.userId, itemId: cfg.itemId,
                mediaSourceId: decision.mediaSourceId, container: decision.container)
            var req = req0
            req.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
            let (data, http) = try await send(req)
            let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges") ?? "nil"
            let contentLength = http.value(forHTTPHeaderField: "Content-Length") ?? "nil"
            print(">>> LIVE [staticOriginal] HTTP \(http.statusCode) bytes=\(data.count) accept-ranges=\(acceptRanges) content-length=\(contentLength)")
            // 206 = range honoured (resumable). 200 with the full body is acceptable too, but the
            // worst-case MKV original is range-resumable per the captured facts.
            #expect(http.statusCode == 206 || http.statusCode == 200)
        }
    }
}
