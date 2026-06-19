import Foundation
import PMSKit

/// Typed errors surfaced by `PlexClient`. The whole app maps failures to these
/// so callers (AuthManager, players, downloads) can react uniformly — most
/// importantly to `.unauthorized` (401), which drives a return to the login flow.
public enum PlexError: Error, Sendable {
    case unauthorized
    case serverUnreachable
    case http(Int)
    case decoding(Error)
}

/// Thin live executor for a `PlexRequest`.
///
/// All request *building* lives in PMSKit (pure, tested). This actor only:
///   1. turns a `PlexRequest` into a `URLRequest`,
///   2. runs it on an injected `URLSession`,
///   3. maps the HTTP status to a typed `PlexError`,
///   4. optionally decodes JSON.
///
/// It is an `actor` so a single instance can be shared across the app and used
/// concurrently from any task without data races on the session.
public actor PlexClient {
    private let session: URLSession
    private let identity: ClientIdentity
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared, identity: ClientIdentity) {
        self.session = session
        self.identity = identity
        self.decoder = JSONDecoder()
    }

    /// Fresh, short-timeout control-plane client for player recovery (#33).
    ///
    /// Use this after a heavy-stream stall has likely poisoned the shared connection pool:
    /// retry/rebuild control requests should not wait behind a half-open keep-alive socket.
    public static func recovery(identity: ClientIdentity, timeout: TimeInterval = 5) -> PlexClient {
        let session = URLSession(configuration: PlexSessionConfiguration.recoveryControlPlane(timeout: timeout))
        return PlexClient(session: session, identity: identity)
    }

    /// Run a request and decode the JSON body as `T`.
    public func send<T: Decodable>(_ r: PlexRequest, as type: T.Type) async throws -> T {
        let data = try await send(r)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PlexError.decoding(error)
        }
    }

    /// Run a request and return the raw response body.
    @discardableResult
    public func send(_ r: PlexRequest) async throws -> Data {
        let request = r.urlRequest()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Connection refused, TLS failure, DNS, timeout, etc.
            if Task.isCancelled { throw CancellationError() }
            throw PlexError.serverUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            // Non-HTTP response (shouldn't happen for our endpoints).
            return data
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw PlexError.unauthorized
        default:
            throw PlexError.http(http.statusCode)
        }
    }
}

/// TLS handling for Plex servers.
///
/// Plex Media Server presents a self-signed certificate on its direct LAN IP
/// (e.g. `https://192.168.x.x:32400`). The *correct* way to reach a server over
/// HTTPS with a valid chain is to use the `*.plex.direct` hostnames returned by
/// `ResourceDiscovery` (`includeHttps=1`): plex.tv issues a real, publicly-trusted
/// wildcard cert for `<hash>.<machineId>.plex.direct`, and those hostnames resolve
/// to the server's LAN/WAN IP. Preferring those means the system trust evaluation
/// "just works" and no override is needed.
///
/// If you must connect to a bare IP (no plex.direct mapping), you would need a
/// delegate that trusts the server cert. That is a deliberate downgrade of TLS
/// validation and should be scoped to Plex hosts only. We ship a delegate below
/// but DO NOT install it by default — the app uses `.shared`/plex.direct. Wire it
/// in only behind an explicit "allow insecure LAN" user setting.
///
/// SECURITY NOTE: blindly trusting any server cert exposes the token to MITM on
/// the LAN. Keep this opt-in and host-scoped.
final class PlexInsecureLANTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    /// Hostnames/IPs for which we accept the server-presented cert without chain
    /// validation. Empty means "trust nothing specially" (system default).
    private let trustedHosts: Set<String>

    init(trustedHosts: Set<String> = []) {
        self.trustedHosts = trustedHosts
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              trustedHosts.contains(challenge.protectionSpace.host)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Host is explicitly allow-listed: accept its self-signed cert.
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
