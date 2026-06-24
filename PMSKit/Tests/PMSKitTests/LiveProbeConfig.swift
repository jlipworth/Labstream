import Foundation
@testable import PMSKit

/// Shared opt-in config for the issue-#75 Plex live probes (subtitle-burn, browse, timeline).
///
/// Centralizes the boilerplate every `Live*Probe` repeats: parse `PLEX_LIVE_SERVER` /
/// `PLEX_LIVE_TOKEN`, build the standard `ClientIdentity`, and return nil (→ the probe no-ops with a
/// skip line) when creds are absent. This keeps plain `swift test` and CI hermetic.
///
/// Scope note: this is used by the THREE probes added/edited for #75 only. The five older
/// `Live*Probe` files predate it and are intentionally left untouched to avoid churn — full dedup
/// across all probes is a follow-up (see `docs/TESTING-LIVE-REQUIREMENTS.md`).
struct LiveProbeConfig {
    let server: URL
    let token: String
    let identity: ClientIdentity

    /// Returns nil when `PLEX_LIVE_SERVER` / `PLEX_LIVE_TOKEN` are missing — the caller prints a
    /// skip line and returns, so nothing hits the network.
    init?(_ env: [String: String] = ProcessInfo.processInfo.environment) {
        guard let serverString = env["PLEX_LIVE_SERVER"], let server = URL(string: serverString),
              let token = env["PLEX_LIVE_TOKEN"], !token.isEmpty
        else { return nil }
        self.server = server
        self.token = token
        self.identity = ClientIdentity(
            clientIdentifier: env["PLEX_LIVE_CLIENT_ID"] ?? "visionplay-live-probe",
            product: "VisionPlay",
            version: "0.1.0",
            deviceName: "VisionPlay Live Probe")
    }

    /// Redact the token and the live scheme://host[:port] from a string before logging it. The repo
    /// is public — log the URL shape (path + query keys), never the real host or any credential.
    func redact(_ string: String) -> String {
        var out = string
        if !token.isEmpty {
            out = out.replacingOccurrences(of: token, with: "<redacted-token>")
        }
        if let scheme = server.scheme, let host = server.host {
            let port = server.port.map { ":\($0)" } ?? ""
            out = out.replacingOccurrences(of: "\(scheme)://\(host)\(port)", with: "<server>")
            out = out.replacingOccurrences(of: host, with: "<host>")
        }
        out = out.replacingOccurrences(of: #"(?i)(X-Plex-Token=)[^&\s"]+"#,
                                       with: "$1<redacted>", options: .regularExpression)
        return out
    }
}
