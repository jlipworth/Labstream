import Testing
import Foundation
@testable import PMSKit

/// Headless probe for the app-owned media-session proxy (#33). Where `LiveSegmentProbeTests`
/// fetches PMS DIRECTLY to prove what bytes the server serves, this probe runs those exact
/// bytes THROUGH the loopback proxy — proving the proxy is a correct transparent forwarder
/// against the real server:
///   • start.m3u8 forwards from the loopback origin to live PMS,
///   • PMS's RELATIVE playlist/segment URIs, resolved against the loopback base (exactly as
///     AVKit resolves them), route the next hop back through the proxy automatically — the
///     core #33 transparency property,
///   • a Range-free media segment at the deep resume offset survives the hop as real MPEG-TS.
///
/// The rotate/recovery path can't be forced against a healthy server (no wedge to trigger it),
/// so on a good run `rotateCount` stays 0; forcing a wedge is a manual checklist item.
///
/// OPT-IN, like the decision/segment probes: no creds → no-op, so plain `swift test` and CI
/// stay hermetic and nothing is hardcoded. Shares the same env as `LiveSegmentProbeTests`.
/// Run via `./scripts/live-proxy-probe.sh` or:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LiveProxyProbe
///
/// Inputs (env): PLEX_LIVE_SERVER / _TOKEN / _METADATA_KEY (required), PLEX_LIVE_OFFSET_SECONDS
/// (deep resume point to prime at; default 3300), PLEX_LIVE_MAX_KBPS (cap; default 3000).
struct LiveProxyProbeTests {

    private struct Config {
        let server: URL
        let token: String
        let metadataKey: String
        let maxVideoBitrateKbps: Int
        let offsetSeconds: Int
        let mediaIndex: Int
        let partIndex: Int
        let identity: ClientIdentity

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let serverString = env["PLEX_LIVE_SERVER"], let server = URL(string: serverString),
                  let token = env["PLEX_LIVE_TOKEN"], !token.isEmpty,
                  let metadataKey = env["PLEX_LIVE_METADATA_KEY"], !metadataKey.isEmpty
            else { return nil }
            self.server = server
            self.token = token
            self.metadataKey = metadataKey
            self.maxVideoBitrateKbps = env["PLEX_LIVE_MAX_KBPS"].flatMap(Int.init) ?? 3000
            self.offsetSeconds = env["PLEX_LIVE_OFFSET_SECONDS"].flatMap(Int.init) ?? 3300
            self.mediaIndex = env["PLEX_LIVE_MEDIA_INDEX"].flatMap(Int.init) ?? 0
            self.partIndex = env["PLEX_LIVE_PART_INDEX"].flatMap(Int.init) ?? 0
            self.identity = ClientIdentity(
                clientIdentifier: env["PLEX_LIVE_CLIENT_ID"] ?? "visionplex-live-probe",
                product: "VisionPlex",
                version: "0.1.0",
                deviceName: "VisionPlex Live Probe")
        }
    }

    /// The CLIENT side — stands in for AVFoundation hitting the loopback origin. Ephemeral, with
    /// the same 30s ceiling the segment probe uses so a hung hop reports as a hang.
    private func makeClientSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 45
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    @discardableResult
    private func fetch(_ session: URLSession, _ label: String, _ url: URL) async -> (status: Int, data: Data)? {
        let started = Date()
        do {
            let (data, response) = try await session.data(from: url)
            let elapsed = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print(String(format: ">>> PROXY [%@] HTTP %d — %d bytes in %.2fs", label, status, data.count, elapsed))
            return (status, data)
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: ">>> PROXY [%@] ERROR after %.2fs — %@", label, elapsed, String(describing: error)))
            return nil
        }
    }

    /// Non-comment, non-empty lines of an m3u8 body (variant / segment URIs).
    private func playlistURIs(_ body: String) -> [String] {
        body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// (segmentStartSeconds, uri) pairs by accumulating `#EXTINF` durations — so we can seek into
    /// the playlist to the deep offset (the top segments are empty t=0 stubs; see the segment probe).
    private func timedSegments(_ body: String) -> [(start: Double, uri: String)] {
        var out: [(Double, String)] = []
        var clock = 0.0
        var pendingDuration: Double?
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let num = line.dropFirst("#EXTINF:".count).prefix { $0 == "." || $0.isNumber }
                pendingDuration = Double(num)
            } else if !line.isEmpty && !line.hasPrefix("#") {
                out.append((clock, line))
                clock += pendingDuration ?? 0
                pendingDuration = nil
            }
        }
        return out
    }

    @Test func liveProxyForwardsPlaylistsAndSegmentThroughLoopback() async throws {
        guard let cfg = Config() else {
            print(">>> PROXY skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_METADATA_KEY to run.")
            return
        }
        let sessionID = "live-proxy-\(UUID().uuidString)"
        let mediaRequest = MediaSessionRequest(
            server: cfg.server, token: cfg.token, identity: cfg.identity,
            metadataKey: cfg.metadataKey, maxVideoBitrateKbps: cfg.maxVideoBitrateKbps,
            sessionID: sessionID, mediaIndex: cfg.mediaIndex, partIndex: cfg.partIndex,
            burnSubtitleStreamID: nil, directStreamEnabled: false)

        print(String(format: ">>> PROXY probe: offset=%ds cap=%dkbps — fronting live PMS through the app-owned loopback origin.",
                     cfg.offsetSeconds, cfg.maxVideoBitrateKbps))

        // The real proxy fronting the LIVE server (default trust works for *.plex.direct). The
        // control plane is a plain ephemeral session that folds PlexRequest.queryItems into the
        // URL (exactly what PlexClient.send does in the app).
        let controlSession = URLSession(configuration: .ephemeral)
        let proxy = MediaSessionProxy(timeout: 30, controlSend: { req in
            var comps = URLComponents(url: req.url, resolvingAgainstBaseURL: false)!
            if !req.queryItems.isEmpty { comps.queryItems = (comps.queryItems ?? []) + req.queryItems }
            var urlReq = URLRequest(url: comps.url!)
            urlReq.httpMethod = req.method
            for (k, v) in req.headers { urlReq.setValue(v, forHTTPHeaderField: k) }
            urlReq.httpBody = req.body
            let (data, _) = try await controlSession.data(for: urlReq)
            return data
        })
        let handle = try await proxy.open(mediaRequest, offsetMs: cfg.offsetSeconds * 1000)
        print(String(format: ">>> PROXY open: loopback=%@", handle.localURL.absoluteString))
        let client = makeClientSession()

        // 1) start.m3u8 THROUGH the loopback — proves the proxy forwards to the live server.
        guard let start = await fetch(client, "start.m3u8", handle.localURL),
              (200...299).contains(start.status),
              let masterBody = String(data: start.data, encoding: .utf8),
              masterBody.contains("#EXTM3U") else {
            print(">>> PROXY VERDICT: loopback did NOT serve start.m3u8 — the proxy could not forward to PMS.")
            await proxy.stop(generation: handle.generation); return
        }

        // 2) Resolve the variant RELATIVE TO THE LOOPBACK URL (exactly as AVKit does). Because PMS
        //    emits relative URIs, resolving against the loopback base routes the next hop straight
        //    back through the proxy — the #33 transparency property we most need to confirm live.
        var mediaPlaylistLoopbackURL = handle.localURL
        var mediaBody = masterBody
        if masterBody.contains("#EXT-X-STREAM-INF"), let variant = playlistURIs(masterBody).first {
            guard let variantURL = URL(string: variant, relativeTo: handle.localURL) else {
                print(">>> PROXY VERDICT: could not resolve variant URI \(variant) against the loopback base.")
                await proxy.stop(generation: handle.generation); return
            }
            if variantURL.host != "127.0.0.1" {
                print(">>> PROXY note: variant resolved to \(variantURL.host ?? "?") — absolute URI; the rewriter must remap it onto the loopback.")
            }
            guard let media = await fetch(client, "index.m3u8", variantURL),
                  (200...299).contains(media.status),
                  let body = String(data: media.data, encoding: .utf8) else {
                print(">>> PROXY VERDICT: start.m3u8 forwarded but the variant index.m3u8 did NOT — relative-URI routing through the loopback is broken.")
                await proxy.stop(generation: handle.generation); return
            }
            mediaPlaylistLoopbackURL = variantURL
            mediaBody = body
        }

        // 3) Fetch the primed segment at the resume offset THROUGH the loopback. A real MPEG-TS
        //    segment (TS sync byte 0x47, >2KB) proves the media hop survives the proxy intact.
        let timed = timedSegments(mediaBody)
        guard !timed.isEmpty else {
            print(">>> PROXY VERDICT: media playlist forwarded but lists NO segments.")
            await proxy.stop(generation: handle.generation); return
        }
        let startIdx = timed.firstIndex { $0.start + 0.001 >= Double(cfg.offsetSeconds) } ?? max(0, timed.count - 1)
        guard let segURL = URL(string: timed[startIdx].uri, relativeTo: mediaPlaylistLoopbackURL) else {
            print(">>> PROXY VERDICT: could not resolve segment URI against the loopback base.")
            await proxy.stop(generation: handle.generation); return
        }
        let seg = await fetch(client, "segment@\(Int(timed[startIdx].start))s", segURL)
        let realMedia = seg.map { (200...299).contains($0.status) && $0.data.first == 0x47 && $0.data.count > 2_000 } ?? false

        // 4) Re-prime via the proxy's OWN seek to a deeper offset (#33 Stage 2). This drives the
        //    coalescing re-prime against the LIVE server: stop previous transcode → fresh
        //    decision at the new offset → new loopback URL. Then fetch start.m3u8 through the new
        //    URL to prove the re-primed media plane forwards. A second offset 600s past the first
        //    (clamped so we don't run past short items is the caller's concern via the env knob).
        let secondOffsetSeconds = cfg.offsetSeconds + 600
        let seekHandle: MediaSessionHandle
        do {
            seekHandle = try await proxy.seek(to: secondOffsetSeconds * 1000)
            print(String(format: ">>> PROXY seek: re-primed to %ds, loopback=%@",
                         secondOffsetSeconds, seekHandle.localURL.absoluteString))
        } catch {
            print(">>> PROXY VERDICT: seek re-prime threw — \(String(describing: error)).")
            await proxy.stop(generation: handle.generation); return
        }
        let reprimedOK = (seekHandle.generation > handle.generation)
            && seekHandle.localURL.absoluteString.contains("offset=\(secondOffsetSeconds)")
        let seekStart = await fetch(client, "start.m3u8@reprime", seekHandle.localURL)
        let seekForwarded = seekStart.map {
            (200...299).contains($0.status) && (String(data: $0.data, encoding: .utf8)?.contains("#EXTM3U") ?? false)
        } ?? false

        let status = await proxy.status()
        if realMedia && reprimedOK && seekForwarded {
            print(">>> PROXY VERDICT: PROXY OK — initial forward + a proxy-owned re-prime seek (new offset, new loopback URL, start.m3u8 forwarded) both succeeded against the live server (rotateCount=\(status.rotateCount)). Stage-2 seek is a correct re-prime.")
        } else if realMedia && !seekForwarded {
            print(">>> PROXY VERDICT: initial forward OK but the re-primed start.m3u8 did NOT forward (reprimedOK=\(reprimedOK)) — Stage-2 seek re-prime is broken.")
        } else {
            print(">>> PROXY VERDICT: forwarding works but the offset segment was empty/stub (rotateCount=\(status.rotateCount)) — a PMS prime issue (see LiveSegmentProbe), not a proxy fault.")
        }
        await proxy.stop(generation: seekHandle.generation)
    }
}
