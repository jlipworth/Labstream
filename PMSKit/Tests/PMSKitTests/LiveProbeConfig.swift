import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

/// Shared opt-in config for the issue-#75 Plex live probes (subtitle-burn, browse, timeline).
///
/// Centralizes the boilerplate every `Live*Probe` repeats: parse `PLEX_LIVE_SERVER` /
/// `PLEX_LIVE_TOKEN`, build the standard `ClientIdentity`, and return nil (→ the probe no-ops with a
/// skip line) when creds are absent. This keeps plain `swift test` and CI hermetic.
///
/// Scope note: every Plex `Live*Probe` — the #75 ones and the five older ones — now composes this
/// for its server/token/identity parse and routes log scrubbing through the shared `redact` below,
/// so both the env/identity boilerplate and the redaction logic live in exactly one place. Each
/// older probe wraps a `base: LiveProbeConfig` and adds only its probe-specific env fields.
struct LiveProbeConfig {
    let server: URL
    let token: String
    let identity: ClientIdentity

    /// Returns nil when `PLEX_LIVE_SERVER` / `PLEX_LIVE_TOKEN` are missing — the caller prints a
    /// skip line and returns, so nothing hits the network. `deviceName` lets each probe keep its
    /// own label in Plex's device list while still sharing this env-parse + identity build.
    init?(_ env: [String: String] = ProcessInfo.processInfo.environment,
          deviceName: String = "Labstream Live Probe") {
        guard let serverString = env["PLEX_LIVE_SERVER"], let server = URL(string: serverString),
              let token = env["PLEX_LIVE_TOKEN"], !token.isEmpty
        else { return nil }
        self.server = server
        self.token = token
        self.identity = ClientIdentity(
            clientIdentifier: env["PLEX_LIVE_CLIENT_ID"] ?? "labstream-live-probe",
            product: "Labstream",
            version: "0.1.0",
            deviceName: deviceName)
    }

    /// Redact the token, the live `scheme://host[:port]`, and any credential query value from a
    /// string before logging it. The repo is public — log the URL shape (path + query keys), never
    /// the real host or any credential.
    ///
    /// This is the single source of truth for probe scrubbing — every `Live*Probe` (Plex AND Emby)
    /// routes log output through it, so tightening the scrub here covers all of them at once.
    /// `credentialKeys` defaults to both backends' token query params so one impl serves both.
    static func redact(_ string: String, token: String, server: URL,
                       credentialKeys: [String] = [
                        "X-Plex-Token", "api_key",
                        "DeviceId", "MediaSourceId", "PlaySessionId", "UserId",
                       ]) -> String {
        var out = string
        if !token.isEmpty {
            out = out.replacingOccurrences(of: token, with: "<redacted-token>")
        }
        if let host = server.host {
            if let scheme = server.scheme {
                let port = server.port.map { ":\($0)" } ?? ""
                // Case-insensitive so a differently-cased host in a logged URL is still scrubbed.
                out = out.replacingOccurrences(of: "\(scheme)://\(host)\(port)", with: "<server>",
                                               options: [.caseInsensitive])
            }
            out = out.replacingOccurrences(of: host, with: "<host>", options: [.caseInsensitive])
        }
        for key in credentialKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            out = out.replacingOccurrences(of: "(?i)(\(escaped)=)[^&\\s\"]+",
                                           with: "$1<redacted>", options: .regularExpression)
        }
        // Server-relative playback URLs can still carry raw item ids in path segments even after
        // the host and query identifiers are scrubbed (for example `/emby/videos/<item>/...`).
        // Keep the route shape, not the live media/user id.
        out = out.replacingOccurrences(
            of: #"(?i)(/(?:videos|items|users|library/metadata|photo/:/transcode)/)[^/?#\s"]+"#,
            with: "$1<id>",
            options: .regularExpression)
        return out
    }

    /// Instance convenience for the #75 probes that hold a `LiveProbeConfig`.
    func redact(_ string: String) -> String {
        Self.redact(string, token: token, server: server)
    }
}

/// Shared transport for opt-in live probes. It deliberately returns only response status and
/// bytes so probe logs can stay shape-only and avoid printing request URLs/headers by accident.
struct LiveProbeTransport {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }
}

/// Shared safe formatting for live probes. Any raw server/user/media labels should pass through
/// here before printing to public terminal logs.
enum LiveProbeLogger {
    static func serverNameSummary(_ serverName: String?) -> String {
        guard let serverName, !serverName.isEmpty else { return "nil" }
        return "set(sig=\(DiagnosticRedactor.stableIdentifier(for: serverName)))"
    }

    static func idPresence(_ value: String?) -> String {
        (value?.isEmpty == false) ? "<set>" : "nil"
    }
}
