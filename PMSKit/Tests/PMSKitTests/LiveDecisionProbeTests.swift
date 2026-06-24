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
    /// Server/token/identity come from the shared `LiveProbeConfig`; only the probe-specific fields
    /// are parsed here.
    private struct LiveConfig {
        let base: LiveProbeConfig
        let metadataKey: String
        let maxVideoBitrateKbps: Int
        let mediaIndex: Int
        let partIndex: Int
        var server: URL { base.server }
        var token: String { base.token }
        var identity: ClientIdentity { base.identity }

        init?() {
            let env = ProcessInfo.processInfo.environment
            guard let base = LiveProbeConfig(env),
                  let metadataKey = env["PLEX_LIVE_METADATA_KEY"], !metadataKey.isEmpty
            else { return nil }
            self.base = base
            self.metadataKey = metadataKey
            // Original quality → effectively-uncapped ceiling, matching PlaybackController's 200 Mbps.
            self.maxVideoBitrateKbps = env["PLEX_LIVE_MAX_KBPS"].flatMap(Int.init) ?? 200_000
            self.mediaIndex = env["PLEX_LIVE_MEDIA_INDEX"].flatMap(Int.init) ?? 0
            self.partIndex = env["PLEX_LIVE_PART_INDEX"].flatMap(Int.init) ?? 0
        }
    }

    private func makeRequest(_ cfg: LiveConfig) -> TranscodeRequest {
        TranscodeRequest(server: cfg.server, token: cfg.token, identity: cfg.identity,
                         metadataKey: cfg.metadataKey,
                         maxVideoBitrateKbps: cfg.maxVideoBitrateKbps,
                         sessionID: "live-probe-\(UUID().uuidString)",
                         mediaIndex: cfg.mediaIndex, partIndex: cfg.partIndex)
    }

    /// Send a built PlexRequest exactly as the app does and dump status + raw body. The raw body
    /// carries real media titles/paths, so it is scrubbed through `LiveProbeConfig.redact` before
    /// logging (the repo is public). Asserts a 200 so a 401/500 fails the probe instead of passing.
    private func dump(_ label: String, _ req: PlexRequest, _ cfg: LiveConfig) async throws {
        let (data, response) = try await URLSession.shared.data(for: req.urlRequest())
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        #expect(status == 200, "live [\(label)] expected HTTP 200, got \(status)")
        let rawBody = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes, non-utf8>"
        let body = LiveProbeConfig.redact(rawBody, token: cfg.token, server: cfg.server)
        print("""
        >>> LIVE [\(label)] HTTP \(status), \(data.count) bytes
        >>> LIVE [\(label)] body:
        \(body)
        >>> LIVE [\(label)] end body
        """)
        // Try the current decoder and report what savesVideoEncode currently sees. The decision
        // text fields can echo a title, so redact them too.
        if status == 200, let decoded = try? JSONDecoder().decode(DecisionResponse.self, from: data) {
            let generalText = decoded.generalDecisionText.map { LiveProbeConfig.redact($0, token: cfg.token, server: cfg.server) } ?? "nil"
            let mde = decoded.mdeDecisionText.map { LiveProbeConfig.redact($0, token: cfg.token, server: cfg.server) } ?? "nil"
            print("""
            >>> LIVE [\(label)] parsed: general=\(decoded.generalDecisionCode.map(String.init) ?? "nil") \
            generalText=\(generalText) \
            video=\(decoded.videoDecision ?? "nil") audio=\(decoded.audioDecision ?? "nil") \
            mde=\(mde) savesVideoEncode=\(decoded.savesVideoEncode)
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
        try await dump("decision", req.decisionRequest(), cfg)
        try await dump("directPlayProbe", req.directPlayProbeRequest(), cfg)
    }
}
