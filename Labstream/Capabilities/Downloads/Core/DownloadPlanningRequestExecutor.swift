import Foundation

/// Executes the short authenticated control-plane requests used while planning a download.
///
/// Authentication remains explicit in each backend-built `URLRequest`; this boundary deliberately
/// has no persistent cookies, credential store, or response cache that could become a second source
/// of backend authority. It is separate from `BackgroundDownloadSession`, which continues to own
/// every durable media transfer.
struct DownloadPlanningRequestExecutor: Sendable {
    typealias Operation = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    init(session: URLSession) {
        operation = { request in
            try await session.data(for: request)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await operation(request)
    }

    /// A nonpersistent session for backend-authenticated planning probes. Session defaults do not
    /// rewrite request headers or request-specific timeouts supplied by the backend builders.
    static let authenticatedEphemeral: Self = {
        Self(session: authenticatedEphemeralSession())
    }()

    static func authenticatedEphemeralSession(
        configuration: URLSessionConfiguration = authenticatedEphemeralConfiguration()
    ) -> URLSession {
        URLSession(configuration: configuration,
                   delegate: DownloadPlanningRedirectDelegate(),
                   delegateQueue: nil)
    }

    static func authenticatedEphemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }
}

/// Allows only redirects that cannot change request authority or semantics. In particular, a
/// default 301/302 redirect can forward Emby's custom token header while rewriting POST to GET.
final class DownloadPlanningRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.allowedRedirect(
            from: task.originalRequest,
            response: response,
            to: request) ? request : nil)
    }

    static func allowedRedirect(from original: URLRequest?,
                                response: HTTPURLResponse,
                                to proposed: URLRequest) -> Bool {
        guard response.statusCode == 307 || response.statusCode == 308,
              let original,
              sameOrigin(original.url, proposed.url),
              original.httpMethod == proposed.httpMethod,
              original.httpBody == proposed.httpBody else {
            return false
        }
        return original.allHTTPHeaderFields?.allSatisfy { field, value in
            proposed.value(forHTTPHeaderField: field) == value
        } ?? true
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        return effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        return switch url.scheme?.lowercased() {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}
