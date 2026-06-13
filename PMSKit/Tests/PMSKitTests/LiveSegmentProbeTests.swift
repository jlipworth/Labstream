import Testing
import Foundation
@testable import PMSKit

/// Headless segment-fetch probe (issue #25/#33 media-plane isolation). The decision probe
/// (`LiveDecisionProbeTests`) proves the CONTROL plane — but the failures that strand the
/// player (`-1008 resource unavailable`, CoreMedia `-16849`, stall-at-0.0-seekable-EMPTY) are
/// on the MEDIA plane: AVPlayer fetching `start.m3u8` + HLS segments at a deep resume offset.
/// #33's recovery only swaps the control-plane `PlexClient`; AVPlayer rides its own socket and
/// is NOT redirected, so when a deep seek lands in transcode territory PMS hasn't produced, the
/// rebuild loop keeps erroring and never recovers.
///
/// This probe reproduces the EXACT failing wire shape from the live logs — `maxVideoBitrate`,
/// `directPlay=0 directStream=1`, the `Safari` profile, and a deep `offset` — but fetches it
/// from the Mac via `URLSession` instead of through the simulator's AVFoundation. That splits
/// the question the simulator can't answer:
///   • Mac fetches start.m3u8 + the primed segment cleanly  → the SERVER is fine; the failure is
///     the simulator's AVFoundation/network behavior (likely a sim artifact — retest on device).
///   • Mac ALSO gets errors / multi-second hangs on the first primed segment → PMS isn't priming
///     the freshly-started session fast enough; fix the client to give it time before fetching.
///
/// OPT-IN, like the decision probe: no creds → no-op, so plain `swift test` and CI stay hermetic
/// and nothing is hardcoded. Run via `./scripts/live-segment-probe.sh` or:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LiveSegmentProbe
///
/// Inputs (env): PLEX_LIVE_SERVER / _TOKEN / _METADATA_KEY (required, shared with the decision
/// probe), PLEX_LIVE_OFFSET_SECONDS (deep resume point to prime at; default 3300 ≈ the live
/// failure), PLEX_LIVE_MAX_KBPS (cap; default 3000 to match the failing run), PLEX_LIVE_SEGMENTS
/// (consecutive segments to pull; default 3 — a deep-seek stall often serves segment 0 then dies).
struct LiveSegmentProbeTests {

    private struct Config {
        let server: URL
        let token: String
        let metadataKey: String
        let maxVideoBitrateKbps: Int
        let offsetSeconds: Int
        let segmentCount: Int
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
            // Default 3000 kbps + offset 3300s reproduces the live failure (3 Mbps/720p, deep seek).
            self.maxVideoBitrateKbps = env["PLEX_LIVE_MAX_KBPS"].flatMap(Int.init) ?? 3000
            self.offsetSeconds = env["PLEX_LIVE_OFFSET_SECONDS"].flatMap(Int.init) ?? 3300
            self.segmentCount = env["PLEX_LIVE_SEGMENTS"].flatMap(Int.init) ?? 3
            self.mediaIndex = env["PLEX_LIVE_MEDIA_INDEX"].flatMap(Int.init) ?? 0
            self.partIndex = env["PLEX_LIVE_PART_INDEX"].flatMap(Int.init) ?? 0
            self.identity = ClientIdentity(
                clientIdentifier: env["PLEX_LIVE_CLIENT_ID"] ?? "visionplex-live-probe",
                product: "VisionPlex",
                version: "0.1.0",
                deviceName: "VisionPlex Live Probe")
        }
    }

    /// A 30s per-request timeout so a media-plane HANG reports as a hang instead of blocking the
    /// whole run for URLSession's 60s default — the app's stall watchdog fires at ~15s, so a
    /// fetch that needs >30s is already "stalled" from the player's point of view.
    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 45
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    /// Fetch a URL, timing it, and report status + bytes (or the error). Returns the body bytes
    /// on a 2xx, else nil. `range` pulls only the first bytes of a (large) media segment — enough
    /// to prove PMS produced it without downloading the whole thing.
    @discardableResult
    private func fetch(_ session: URLSession, _ label: String, _ url: URL,
                       firstBytesOnly: Bool = false) async -> Data? {
        var req = URLRequest(url: url)
        if firstBytesOnly { req.setValue("bytes=0-65535", forHTTPHeaderField: "Range") }
        let started = Date()
        do {
            let (data, response) = try await session.data(for: req)
            let elapsed = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let verdict = (200...299).contains(status) ? "OK" : "BAD"
            print(String(format: ">>> SEG [%@] HTTP %d %@ — %d bytes in %.2fs",
                         label, status, verdict, data.count, elapsed))
            return (200...299).contains(status) ? data : nil
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: ">>> SEG [%@] ERROR after %.2fs — %@",
                         label, elapsed, String(describing: error)))
            return nil
        }
    }

    /// Pull the URIs (non-comment lines) out of an m3u8 body.
    private func playlistURIs(_ body: String) -> [String] {
        body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Parse a media playlist into (segmentStartSeconds, uri) pairs by accumulating `#EXTINF`
    /// durations. Needed because PMS lists EVERY segment from t=0, but with a deep `offset` it
    /// only transcodes from the offset onward — the segments at the TOP are empty 188-byte PAT
    /// stubs (proven live). The real media AVPlayer plays sits ~offset/segDuration entries deep,
    /// so we must seek to the offset within the playlist to fetch the segments that actually stall.
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

    @Test func liveSegmentProbeFetchesPrimedSegments() async throws {
        guard let cfg = Config() else {
            print(">>> SEG skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_METADATA_KEY to run.")
            return
        }
        let session = makeSession()
        let transcode = TranscodeRequest(
            server: cfg.server, token: cfg.token, identity: cfg.identity,
            metadataKey: cfg.metadataKey, maxVideoBitrateKbps: cfg.maxVideoBitrateKbps,
            sessionID: "live-seg-\(UUID().uuidString)",
            mediaIndex: cfg.mediaIndex, partIndex: cfg.partIndex,
            startOffsetSeconds: cfg.offsetSeconds)

        print(String(format: ">>> SEG probe: offset=%ds cap=%dkbps segments=%d — the exact failing wire shape (directPlay=0 directStream=1 Safari).",
                     cfg.offsetSeconds, cfg.maxVideoBitrateKbps, cfg.segmentCount))

        // 1) start.m3u8 — starts the transcode session at the deep offset and returns the master.
        //    PLEX_LIVE_DIRECT_STREAM=0 rewrites the hardcoded directStream=1 to 0, to test whether
        //    forcing a transcode makes PMS honor maxVideoBitrate (segments should shrink ~8x at 3Mbps).
        var startURL = transcode.startM3U8URL()
        if ProcessInfo.processInfo.environment["PLEX_LIVE_DIRECT_STREAM"] == "0" {
            let flipped = startURL.absoluteString.replacingOccurrences(of: "directStream=1", with: "directStream=0")
            if let u = URL(string: flipped) { startURL = u; print(">>> SEG note: forcing directStream=0 (transcode, not copy)") }
        }
        guard let masterData = await fetch(session, "start.m3u8", startURL),
              let masterBody = String(data: masterData, encoding: .utf8) else {
            print(">>> SEG VERDICT: start.m3u8 failed — PMS would not even open the session at this offset.")
            return
        }
        // The master's EXT-X-STREAM-INF BANDWIDTH is PMS's own declared stream bitrate — the
        // decisive copy-vs-transcode tell (≈24 Mbps = copying the 4K original; ≈3 Mbps = honoring
        // the cap). Token stripped so it's safe to log.
        if let infLine = masterBody.split(whereSeparator: \.isNewline).first(where: { $0.contains("BANDWIDTH") }) {
            print(">>> SEG master STREAM-INF: \(infLine.trimmingCharacters(in: .whitespaces))")
        }

        // 2) Resolve the variant (master → media playlist), or treat start.m3u8 as the media playlist.
        var mediaPlaylistURL = startURL
        var mediaBody = masterBody
        if masterBody.contains("#EXT-X-STREAM-INF"), let variant = playlistURIs(masterBody).first {
            guard let variantURL = URL(string: variant, relativeTo: startURL) else {
                print(">>> SEG VERDICT: could not resolve variant URI \(variant)"); return
            }
            guard let data = await fetch(session, "index.m3u8", variantURL),
                  let body = String(data: data, encoding: .utf8) else {
                print(">>> SEG VERDICT: master OK but the variant index.m3u8 failed — session opened, playlist won't serve.")
                return
            }
            mediaPlaylistURL = variantURL
            mediaBody = body
        }

        // The media playlist should carry #EXT-X-START:TIME-OFFSET when PMS honored the deep prime.
        if let startTag = mediaBody.split(whereSeparator: \.isNewline).first(where: { $0.contains("EXT-X-START") }) {
            print(">>> SEG note: \(startTag.trimmingCharacters(in: .whitespaces))")
        } else {
            print(">>> SEG note: media playlist has NO #EXT-X-START — PMS did not prime at the offset (deep seek would stall).")
        }

        // 3) Seek INTO the playlist to the resume offset and fetch the N consecutive segments
        //    AVPlayer plays right after a deep-offset (re)start — the exact ones that stalled.
        //    (The top-of-list segments are empty 188-byte t=0 stubs; see timedSegments.)
        let timed = timedSegments(mediaBody)
        guard !timed.isEmpty else {
            print(">>> SEG VERDICT: media playlist OK but lists NO segments — PMS produced no media at this offset.")
            return
        }
        let startIdx = timed.firstIndex { $0.start + 0.001 >= Double(cfg.offsetSeconds) }
            ?? max(0, timed.count - 1)
        print(String(format: ">>> SEG note: playlist has %d segments; resume offset %ds lands at segment[%d] (t=%.1fs, uri=%@)",
                     timed.count, cfg.offsetSeconds, startIdx, timed[startIdx].start,
                     URL(string: timed[startIdx].uri, relativeTo: mediaPlaylistURL)?.lastPathComponent ?? "?"))

        var served = 0, realMedia = 0
        let slice = timed[startIdx..<min(startIdx + cfg.segmentCount, timed.count)]
        for entry in slice {
            guard let segURL = URL(string: entry.uri, relativeTo: mediaPlaylistURL) else { continue }
            // Full fetch (no range): a real primed segment is hundreds of KB of MPEG-TS; an empty
            // 188-byte PAT-only stub means PMS did NOT transcode media at this point.
            if let data = await fetch(session, "segment@\(Int(entry.start))s", segURL) {
                served += 1
                let head = [UInt8](data.prefix(8))
                let isTS = head.first == 0x47
                let looksReal = data.count > 2_000          // a genuine video segment, not a 1-packet stub
                if isTS && looksReal { realMedia += 1 }
                print(String(format: ">>> SEG sniff@%ds: %d bytes, ts=%@ realMedia=%@ head=%@",
                             Int(entry.start), data.count, isTS ? "YES" : "no",
                             looksReal ? "YES" : "NO(stub)",
                             head.map { String(format: "%02x", $0) }.joined()))
            }
        }

        let asked = slice.count
        if realMedia == asked {
            print(">>> SEG VERDICT: SERVER OK — at the resume offset, PMS served start.m3u8 + \(realMedia)/\(asked) REAL primed segments. The server delivers the exact bytes that stalled in the sim, so the failure is the simulator's media plane (AVFoundation/sim network), not the server. Retest on device.")
        } else if served == asked {
            print(">>> SEG VERDICT: PMS PRIME BROKEN — it served \(served)/\(asked) segments at the offset but only \(realMedia) carried real media (rest were empty stubs). AVPlayer starves on empty segments → the stall. This is a server/session priming bug, reproducible without the simulator.")
        } else {
            print(">>> SEG VERDICT: SERVER/SESSION FAILING — only \(served)/\(asked) segments served at the offset (\(realMedia) real). The deep-offset prime errors/hangs server-side; the client can't fix this, but must stop fork-bombing restarts into it.")
        }
    }
}
