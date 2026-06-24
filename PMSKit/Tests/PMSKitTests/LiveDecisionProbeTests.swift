import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Headless integration probe against a REAL Plex Media Server (issue #7 / #29 closing the
/// player test loop). This hits the network, so it is OPT-IN: it runs only when the required
/// env vars are present and otherwise returns immediately, leaving plain `swift test` and CI
/// hermetic. NOTHING here is hardcoded — server, token and metadata key all arrive via the
/// environment, so no secret is ever committed.
///
/// Why this faithfully reproduces the app: the app's `PlexClient.send` is a bare
/// `URLSession.shared.data(for: request.urlRequest())` with no custom session, retries or
/// header injection. So building a `TranscodeRequest` here and sending it through
/// `URLSession.shared` produces the exact same wire request the app sends — including the
/// token in BOTH the query string and the `X-Plex-Token` header, plus the full `X-Plex-*`
/// identity set. (That header set is what hand-written `curl` was missing when it 401'd.)
///
/// Run it (creds live in a gitignored env file — see scripts/plex-live.env.example):
///   ./scripts/live-decision-probe.sh
/// or directly:
///   set -a; source scripts/plex-live.env; set +a
///   cd PMSKit && swift test --filter LiveDecisionProbe
///
/// The point is to capture the RAW decision JSON so we can see exactly which field PMS uses to
/// express a direct-play / copy verdict, then fix `DecisionResponse.savesVideoEncode` against
/// the real shape (it returned `mdeDecisionText="Direct play OK."` with nil per-stream
/// decisions, so `savesVideoEncode` read the wrong field).
struct LiveDecisionProbeTests {

    /// Required + optional env inputs. Returns nil (→ test is a no-op) when creds are absent.
    private struct LiveConfig {
        let server: URL
        let token: String
        let metadataKey: String
        let maxVideoBitrateKbps: Int
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
            // Original quality → effectively-uncapped ceiling, matching PlaybackController's 200 Mbps.
            self.maxVideoBitrateKbps = env["PLEX_LIVE_MAX_KBPS"].flatMap(Int.init) ?? 200_000
            self.mediaIndex = env["PLEX_LIVE_MEDIA_INDEX"].flatMap(Int.init) ?? 0
            self.partIndex = env["PLEX_LIVE_PART_INDEX"].flatMap(Int.init) ?? 0
            self.identity = ClientIdentity(
                clientIdentifier: env["PLEX_LIVE_CLIENT_ID"] ?? "visionplay-live-probe",
                product: "VisionPlay",
                version: "0.1.0",
                deviceName: "VisionPlay Live Probe")
        }
    }

    private func makeRequest(_ cfg: LiveConfig) -> TranscodeRequest {
        TranscodeRequest(server: cfg.server, token: cfg.token, identity: cfg.identity,
                         metadataKey: cfg.metadataKey,
                         maxVideoBitrateKbps: cfg.maxVideoBitrateKbps,
                         sessionID: "live-probe-\(UUID().uuidString)",
                         mediaIndex: cfg.mediaIndex, partIndex: cfg.partIndex)
    }

    /// Send a built PlexRequest exactly as the app does and dump status + raw body.
    private func dump(_ label: String, _ req: PlexRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes, non-utf8>"
        print("""
        >>> LIVE [\(label)] HTTP \(status), \(data.count) bytes
        >>> LIVE [\(label)] body:
        \(body)
        >>> LIVE [\(label)] end body
        """)
        // Try the current decoder and report what savesVideoEncode currently sees.
        if status == 200, let decoded = try? JSONDecoder().decode(DecisionResponse.self, from: data) {
            print("""
            >>> LIVE [\(label)] parsed: general=\(decoded.generalDecisionCode.map(String.init) ?? "nil") \
            generalText=\(decoded.generalDecisionText ?? "nil") \
            video=\(decoded.videoDecision ?? "nil") audio=\(decoded.audioDecision ?? "nil") \
            mde=\(decoded.mdeDecisionText ?? "nil") savesVideoEncode=\(decoded.savesVideoEncode)
            """)
        }
    }

    @Test func liveDecisionProbeDumpsRawBody() async throws {
        guard let cfg = LiveConfig() else {
            print(">>> LIVE skipped: set PLEX_LIVE_SERVER / PLEX_LIVE_TOKEN / PLEX_LIVE_METADATA_KEY to run.")
            return
        }
        let req = makeRequest(cfg)
        // Production decision (directPlay=0) and the #7 direct-play probe (directPlay=1).
        try await dump("decision", req.decisionRequest())
        try await dump("directPlayProbe", req.directPlayProbeRequest())
    }
}
