import Testing
import Foundation
@testable import PMSKit

/// Headless PTS-continuity probe (#33 proxy-owned playlist). Decides the ONE architectural
/// unknown behind serving AVKit a single stable full-timeline playlist while the proxy re-primes
/// PMS underneath on a far-segment request:
///
///   When PMS is primed at offset X it serves real MPEG-TS for segment `0X.ts` and PAT-only stubs
///   before it (proven by LiveSegmentProbe). The segment URI is ABSOLUTE TIME — `0NNNNN.ts` is
///   second N in EVERY session regardless of prime offset. So if the proxy re-primes at the seek
///   target T and serves the new session's `0T.ts` into AVKit's ongoing playback WITHOUT a reload,
///   that splice is seamless **iff** PMS stamps segments with ABSOLUTE PTS (≈ T seconds). If PMS
///   instead RESETS PTS per prime (each session starts ~0), two sessions' segments collide on the
///   timeline and the no-reload splice is impossible — we'd need a playlist reload + EXT-X-DISCONTINUITY.
///
/// Method: prime two sessions a fixed gap apart, fetch each session's FIRST REAL segment (the one
/// at its own prime offset), parse the first video PES PTS out of the MPEG-TS, and compare. If the
/// PTS delta ≈ the offset gap, PTS is absolute → no-reload splice works. If the delta ≈ 0, PTS
/// resets → it doesn't.
///
/// OPT-IN like the other live probes: no creds → no-op, so plain `swift test` / CI stay hermetic
/// and nothing is hardcoded. Shares the same env. Run via `./scripts/live-pts-probe.sh` or:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LivePTSProbe
///
/// Inputs (env): PLEX_LIVE_SERVER / _TOKEN / _METADATA_KEY (required), PLEX_LIVE_OFFSET_SECONDS
/// (first prime offset; default 3300), PLEX_LIVE_PTS_GAP_SECONDS (gap to the second prime; default
/// 600), PLEX_LIVE_MAX_KBPS (cap; default 3000).
struct LivePTSProbeTests {

    private struct Config {
        let server: URL
        let token: String
        let metadataKey: String
        let maxVideoBitrateKbps: Int
        let offsetSeconds: Int
        let gapSeconds: Int
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
            self.gapSeconds = env["PLEX_LIVE_PTS_GAP_SECONDS"].flatMap(Int.init) ?? 600
            self.mediaIndex = env["PLEX_LIVE_MEDIA_INDEX"].flatMap(Int.init) ?? 0
            self.partIndex = env["PLEX_LIVE_PART_INDEX"].flatMap(Int.init) ?? 0
            self.identity = ClientIdentity(
                clientIdentifier: env["PLEX_LIVE_CLIENT_ID"] ?? "visionplex-live-probe",
                product: "VisionPlex",
                version: "0.1.0",
                deviceName: "VisionPlex Live Probe")
        }
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 45
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    @discardableResult
    private func fetch(_ session: URLSession, _ label: String, _ url: URL,
                       range: String? = nil) async -> Data? {
        var req = URLRequest(url: url)
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        let started = Date()
        do {
            let (data, response) = try await session.data(for: req)
            let elapsed = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print(String(format: ">>> PTS [%@] HTTP %d — %d bytes in %.2fs", label, status, data.count, elapsed))
            return (200...299).contains(status) ? data : nil
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: ">>> PTS [%@] ERROR after %.2fs — %@", label, elapsed, String(describing: error)))
            return nil
        }
    }

    private func playlistURIs(_ body: String) -> [String] {
        body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

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

    /// Scan an MPEG-TS byte stream for the FIRST video PES (stream_id 0xE0–0xEF) carrying a PTS,
    /// and return its PTS in 90 kHz ticks. nil if none found in the bytes provided. Skips PSI
    /// (PAT/PMT) naturally — those aren't PES and don't begin with the 00 00 01 start code.
    private func firstVideoPTS(_ data: Data) -> UInt64? {
        let bytes = [UInt8](data)
        let pkt = 188
        var i = 0
        // Align to the first sync byte (a Range fetch should start clean at 0x47, but be safe).
        while i + pkt <= bytes.count && bytes[i] != 0x47 { i += 1 }
        while i + pkt <= bytes.count {
            guard bytes[i] == 0x47 else { i += 1; continue }   // re-sync if a packet was malformed
            let pusi = (bytes[i + 1] & 0x40) != 0
            let afc = (bytes[i + 3] >> 4) & 0x3
            var p = i + 4
            if afc == 0b10 { i += pkt; continue }              // adaptation only, no payload
            if afc == 0b11 { p += 1 + Int(bytes[i + 4]) }      // skip adaptation field
            if afc == 0b00 { i += pkt; continue }              // reserved
            // Need PUSI + a PES start code + a video stream_id + room for the PTS bytes.
            if pusi, p + 14 <= i + pkt,
               bytes[p] == 0x00, bytes[p + 1] == 0x00, bytes[p + 2] == 0x01,
               (0xE0...0xEF).contains(bytes[p + 3]) {
                let ptsDtsFlags = (bytes[p + 7] >> 6) & 0x3
                if ptsDtsFlags == 0b10 || ptsDtsFlags == 0b11 {
                    let b0 = UInt64(bytes[p + 9]), b1 = UInt64(bytes[p + 10]),
                        b2 = UInt64(bytes[p + 11]), b3 = UInt64(bytes[p + 12]), b4 = UInt64(bytes[p + 13])
                    let pts = (((b0 >> 1) & 0x07) << 30)
                            | (b1 << 22)
                            | (((b2 >> 1) & 0x7F) << 15)
                            | (b3 << 7)
                            | ((b4 >> 1) & 0x7F)
                    return pts
                }
            }
            i += pkt
        }
        return nil
    }

    /// Prime one transcode session at `offset` and return the first video PTS (in seconds) of the
    /// first real segment at that offset — i.e. what timeline position PMS stamps onto `0offset.ts`.
    private func firstSegmentPTSSeconds(_ session: URLSession, _ cfg: Config, offset: Int) async -> Double? {
        let transcode = TranscodeRequest(
            server: cfg.server, token: cfg.token, identity: cfg.identity,
            metadataKey: cfg.metadataKey, maxVideoBitrateKbps: cfg.maxVideoBitrateKbps,
            sessionID: "live-pts-\(UUID().uuidString)",
            mediaIndex: cfg.mediaIndex, partIndex: cfg.partIndex,
            startOffsetSeconds: offset)

        guard let masterData = await fetch(session, "start@\(offset)s", transcode.startM3U8URL()),
              let masterBody = String(data: masterData, encoding: .utf8) else {
            print(">>> PTS note: start.m3u8 failed at offset \(offset)s.")
            return nil
        }
        var mediaPlaylistURL = transcode.startM3U8URL()
        var mediaBody = masterBody
        if masterBody.contains("#EXT-X-STREAM-INF"), let variant = playlistURIs(masterBody).first {
            guard let variantURL = URL(string: variant, relativeTo: mediaPlaylistURL),
                  let data = await fetch(session, "index@\(offset)s", variantURL),
                  let body = String(data: data, encoding: .utf8) else {
                print(">>> PTS note: variant index.m3u8 failed at offset \(offset)s.")
                return nil
            }
            mediaPlaylistURL = variantURL
            mediaBody = body
        }
        let timed = timedSegments(mediaBody)
        let startIdx = timed.firstIndex { $0.start + 0.001 >= Double(offset) } ?? max(0, timed.count - 1)
        guard !timed.isEmpty, let segURL = URL(string: timed[startIdx].uri, relativeTo: mediaPlaylistURL) else {
            print(">>> PTS note: no segment at offset \(offset)s.")
            return nil
        }
        // 512 KB is far more than enough to reach the first video PES past the PAT/PMT.
        guard let seg = await fetch(session, "seg@\(offset)s", segURL, range: "bytes=0-524287") else {
            return nil
        }
        guard seg.first == 0x47, seg.count > 2_000 else {
            print(">>> PTS note: segment at offset \(offset)s is a stub/non-TS (\(seg.count) bytes) — PMS did not prime here.")
            return nil
        }
        guard let ticks = firstVideoPTS(seg) else {
            print(">>> PTS note: no video PES PTS found in segment at offset \(offset)s.")
            return nil
        }
        let seconds = Double(ticks) / 90_000.0
        print(String(format: ">>> PTS sample: prime=%ds → first video PTS = %llu ticks = %.3fs", offset, ticks, seconds))
        return seconds
    }

    @Test func livePTSContinuityAcrossReprime() async throws {
        guard let cfg = Config() else {
            print(">>> PTS skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_METADATA_KEY to run.")
            return
        }
        let session = makeSession()
        let offsetA = cfg.offsetSeconds
        let offsetB = cfg.offsetSeconds + cfg.gapSeconds
        print(String(format: ">>> PTS probe: priming two sessions at %ds and %ds (gap %ds) to test absolute-vs-reset PTS.",
                     offsetA, offsetB, cfg.gapSeconds))

        guard let ptsA = await firstSegmentPTSSeconds(session, cfg, offset: offsetA) else {
            print(">>> PTS VERDICT: could not sample PTS at offset \(offsetA)s — inconclusive.")
            return
        }
        guard let ptsB = await firstSegmentPTSSeconds(session, cfg, offset: offsetB) else {
            print(">>> PTS VERDICT: could not sample PTS at offset \(offsetB)s — inconclusive.")
            return
        }

        let observedDelta = ptsB - ptsA
        let expectedDelta = Double(cfg.gapSeconds)
        // Offset-tracking PTS: the two samples differ by ~the prime gap. Reset PTS: they're ~equal.
        let tracksOffset = abs(observedDelta - expectedDelta) < 2.0
        let resets = abs(observedDelta) < 2.0

        print(String(format: ">>> PTS measure: pts@%ds=%.3fs  pts@%ds=%.3fs  Δ=%.3fs  (expected Δ if absolute = %.1fs)",
                     offsetA, ptsA, offsetB, ptsB, observedDelta, expectedDelta))

        if tracksOffset {
            print(">>> PTS VERDICT: ABSOLUTE PTS — segment PTS tracks the prime offset 1:1. A re-primed session's 0NNNNN.ts splices seamlessly into AVKit's timeline with NO reload. The proxy-owned full-timeline playlist + segment-level re-prime-on-demand is viable as designed.")
        } else if resets {
            print(">>> PTS VERDICT: RESET PTS — each prime restarts PTS near the same base, so two sessions' segments collide on the timeline. The no-reload splice is IMPOSSIBLE: serving a re-primed segment under one stable playlist needs a playlist reload + #EXT-X-DISCONTINUITY (design change).")
        } else {
            print(String(format: ">>> PTS VERDICT: PTS neither tracks the offset nor resets cleanly (Δ=%.3fs, expected %.1fs). PMS may add a base offset or wrap the 33-bit clock — inspect the raw samples above before committing to the no-reload splice.", observedDelta, expectedDelta))
        }
    }
}
