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
        // Forbidden resources do not prove that the account credential expired.
        case 401:
            throw PlexError.unauthorized
        default:
            throw PlexError.http(http.statusCode)
        }
    }
}
