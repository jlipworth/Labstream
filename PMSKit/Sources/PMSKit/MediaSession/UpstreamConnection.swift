import Foundation

/// App-owned upstream transport for the proxy (#33). The one thing app code *can* do that
/// AVFoundation's own media-plane pool will not: guarantee a fresh socket. On a wedge-class
/// error it rotates (rebuilds the session) once, budget-permitting, and retries — so the user
/// never has to tap Retry. A genuinely-down server exhausts the budget and the error surfaces
/// through the existing failure path instead of reconnecting forever.
///
/// `fetch`/`rebuild`/`now` are injected so the rotate logic is unit-testable without a live
/// `URLSession`. Production wiring (in `MediaSessionProxy`) passes a `fetch` that calls
/// `session.data(for:)` and a `rebuild` that does `invalidateAndCancel()` + a fresh session.
actor UpstreamConnection {
    private var budget: SeekRestartBudget
    private let now: @Sendable () -> TimeInterval
    private let rebuild: @Sendable () -> Void
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private(set) var rotateCount = 0

    init(budget: SeekRestartBudget,
         now: @escaping @Sendable () -> TimeInterval,
         rebuild: @escaping @Sendable () -> Void,
         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.budget = budget
        self.now = now
        self.rebuild = rebuild
        self.fetch = fetch
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await fetch(request)
        } catch let error where Self.isWedge(error) {
            switch budget.requestRestart(now: now()) {
            case .allow:
                rebuild()
                rotateCount += 1
                return try await fetch(request)   // one retry on the fresh socket
            case .deferred, .escalate:
                throw error                        // surface; do not reconnect-storm
            }
        }
    }

    /// Errors that indicate a poisoned/half-open socket rather than a clean HTTP error.
    private static func isWedge(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        switch e.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}
