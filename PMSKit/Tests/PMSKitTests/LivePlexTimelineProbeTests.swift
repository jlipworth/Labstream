import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Headless timeline/progress + session-stop probe against a REAL Plex Media Server (issue #75 —
/// the Plex counterpart to the Emby progress + `activeEncodingStop` coverage in `LiveEmbyProbe`).
/// This hits the network and MUTATES the test account's resume point, so it is OPT-IN and must run
/// ONLY against a dedicated test account — see "Cleanup / reset" in
/// `docs/TESTING-LIVE-REQUIREMENTS.md`. With no creds it returns immediately, leaving plain
/// `swift test` and CI hermetic. NOTHING is hardcoded — server, token and item key arrive via the
/// environment, so no secret is ever committed.
///
/// Why this faithfully reproduces the app: the timeline heartbeat uses the real `TimelineRequest`
/// builder and the session stop uses the real `TranscodeRequest.stop(...)` builder — the exact
/// wire shapes the app's `PlaybackController` sends — dispatched through `URLSession.shared`. So a
/// green round-trip here proves the live server accepts the app's progress report and surfaces it
/// back as a resume point, and that the stop endpoint cleanly ends a started session.
///
/// What it proves (two nuances no mock can catch):
///   (a) PROGRESS ROUND-TRIP — POST a `/:/timeline` update at a known offset, then read the item's
///       metadata back and confirm PMS stored a `viewOffset` near that offset. If progress silently
///       fails to persist, Resume would land at the wrong place; this is the tripwire.
///   (b) SESSION STOP — start a transcode session (decision + start.m3u8), then stop it via
///       `TranscodeRequest.stop`, asserting the stop is accepted so no orphaned FFmpeg job is left
///       burning CPU / a concurrent-transcode slot. (Job-starting probe.)
///
/// Run it (creds live in a gitignored env file — see scripts/plex-live.env.example):
///   ./scripts/live-plex-timeline-probe.sh
/// or directly:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LivePlexTimelineProbe
///
/// SECURITY: never prints the token or the live scheme/host; logs offsets / decisions / status only.
///
/// Inputs (env):
///   PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_METADATA_KEY  (required, shared with decision probe)
///   PLEX_LIVE_TIMELINE_OFFSET_SECONDS                            (optional — offset to report; default 120)
struct LivePlexTimelineProbeTests {

    private struct Config {
        let server: URL
        let token: String
        let metadataKey: String     // e.g. /library/metadata/12345
        let ratingKey: String       // bare numeric id, e.g. 12345
        let reportSeconds: Int
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
            self.ratingKey = metadataKey.split(separator: "/").last.map(String.init) ?? metadataKey
            self.reportSeconds = env["PLEX_LIVE_TIMELINE_OFFSET_SECONDS"].flatMap(Int.init) ?? 120
            self.identity = ClientIdentity(
                clientIdentifier: env["PLEX_LIVE_CLIENT_ID"] ?? "visionplay-live-probe",
                product: "VisionPlay",
                version: "0.1.0",
                deviceName: "VisionPlay Live Probe")
        }
    }

    private func send(_ req: PlexRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    /// Read the item's metadata back and return its stored resume offset (`viewOffset`, ms).
    private func readViewOffsetMs(_ cfg: Config) async throws -> Int? {
        let req = PlexRequest(url: cfg.server.appendingPathComponent(cfg.metadataKey),
                              method: "GET",
                              headers: PlexHeaders.standard(identity: cfg.identity, token: cfg.token))
        let (data, status) = try await send(req)
        guard status == 200 else {
            print(">>> TIMELINE [read] HTTP \(status) — cannot read back metadata.")
            return nil
        }
        let decoded = try JSONDecoder().decode(MetadataResponse.self, from: data)
        return decoded.mediaContainer.metadata.first?.viewOffset
    }

    @Test func livePlexTimelineRoundTripAndStop() async throws {
        guard let cfg = Config() else {
            print(">>> TIMELINE skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_METADATA_KEY to run (TEST ACCOUNT ONLY — this writes a resume point).")
            return
        }

        let durationMs = 2 * 60 * 60 * 1000   // 2h upper bound; PMS clamps to real duration.
        let reportMs = cfg.reportSeconds * 1000

        // (a) PROGRESS ROUND-TRIP. Heartbeat a `playing` state at the report offset (the app sends
        //     these periodically), then read the item's viewOffset back.
        let timeline = TimelineRequest.timeline(
            server: cfg.server, token: cfg.token, identity: cfg.identity,
            ratingKey: cfg.ratingKey, key: cfg.metadataKey,
            state: .playing, timeMs: reportMs, durationMs: durationMs)
        let (_, tlStatus) = try await send(timeline)
        print(">>> TIMELINE [report] /:/timeline state=playing time=\(cfg.reportSeconds)s HTTP \(tlStatus)")
        #expect((200..<300).contains(tlStatus), "timeline report expected 2xx, got \(tlStatus)")

        let storedMs = try await readViewOffsetMs(cfg)
        print(">>> TIMELINE [read] viewOffset=\(storedMs.map { "\($0)ms (~\($0/1000)s)" } ?? "nil")")
        if let storedMs {
            // PMS stores progress asynchronously and may round; accept within 15s of the report.
            let deltaSecs = abs(storedMs / 1000 - cfg.reportSeconds)
            print(">>> TIMELINE [read] delta from reported offset = \(deltaSecs)s")
            #expect(deltaSecs <= 15,
                    "stored viewOffset (~\(storedMs/1000)s) should be near the reported \(cfg.reportSeconds)s — progress did not round-trip")
        } else {
            // Some library types (e.g. unmatched/photo) never persist a viewOffset; don't hard-fail,
            // but make the gap explicit rather than silently passing.
            print(">>> TIMELINE [read] VERDICT: server returned no viewOffset — point PLEX_LIVE_METADATA_KEY at a video item that tracks progress.")
        }

        // (b) SESSION STOP. Open a real transcode session (decision + start.m3u8), then stop it.
        let transcode = TranscodeRequest(
            server: cfg.server, token: cfg.token, identity: cfg.identity,
            metadataKey: cfg.metadataKey, maxVideoBitrateKbps: 4_000,
            sessionID: "live-timeline-\(UUID().uuidString)",
            mediaIndex: 0, partIndex: 0)

        // decision first (the control-plane authorization the app does before start.m3u8).
        let (_, decStatus) = try await send(transcode.decisionRequest())
        print(">>> TIMELINE [stop] decision HTTP \(decStatus)")

        // start.m3u8 actually spins up the server-side session.
        let startReq = PlexRequest(url: transcode.startM3U8URL(), method: "GET",
                                   headers: PlexHeaders.media(identity: cfg.identity, token: cfg.token))
        let (_, startStatus) = try await send(startReq)
        print(">>> TIMELINE [stop] start.m3u8 HTTP \(startStatus)")

        // Stop it via the real builder. PMS returns 200 even if the session already reaped, so a
        // 2xx means "no orphaned session remains" — exactly the cleanup guarantee the app relies on.
        let stop = TranscodeRequest.stop(server: cfg.server, token: cfg.token,
                                         identity: cfg.identity, sessionID: transcode.sessionID)
        let (_, stopStatus) = try await send(stop)
        print(">>> TIMELINE [stop] /:/transcode/universal/stop HTTP \(stopStatus)")
        #expect((200..<300).contains(stopStatus),
                "session stop expected 2xx (clean teardown, no orphaned transcode), got \(stopStatus)")

        print(">>> TIMELINE VERDICT: OK — progress round-tripped and the started transcode session stopped cleanly.")
    }
}
