import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// App-owned upstream transport for the proxy (#33). The one thing app code *can* do that
/// AVFoundation's own media-plane pool will not: guarantee a fresh socket. On a wedge-class
/// error it rotates (rebuilds the session) once, budget-permitting, and retries — so the user
/// never has to tap Retry. A genuinely-down server exhausts the budget and the error surfaces
/// through the existing failure path instead of reconnecting forever.
///
/// `makeAttempt`/`rotate`/`now` are injected so the rotate logic is unit-testable without a live
/// `URLSession`. Every attempt carries the session generation it actually uses. Production wiring
/// (in `MediaSessionProxy`) swaps to a fresh session without cancelling healthy work on the old
/// generation; a late failure from that draining generation retries on the current session but
/// cannot rotate it again.
actor UpstreamConnection {
    private var budget: SeekRestartBudget
    private let now: @Sendable () -> TimeInterval
    private let makeAttempt: @Sendable () -> UpstreamFetchAttempt
    private let rotate: @Sendable (_ expectedGeneration: Int) -> Bool
    private(set) var rotateCount = 0

    init(budget: SeekRestartBudget,
         now: @escaping @Sendable () -> TimeInterval,
         makeAttempt: @escaping @Sendable () -> UpstreamFetchAttempt,
         rotate: @escaping @Sendable (_ expectedGeneration: Int) -> Bool) {
        self.budget = budget
        self.now = now
        self.makeAttempt = makeAttempt
        self.rotate = rotate
    }

    /// Convenience injection used by policy/proxy tests. The closure transport advances a real
    /// generation on each accepted rebuild even though it has no socket pool to replace.
    init(budget: SeekRestartBudget,
         now: @escaping @Sendable () -> TimeInterval,
         rebuild: @escaping @Sendable () -> Void,
         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        let transport = ClosureUpstreamTransport(rebuild: rebuild, fetch: fetch)
        self.init(budget: budget,
                  now: now,
                  makeAttempt: { transport.makeAttempt() },
                  rotate: { transport.rotate(ifCurrent: $0) })
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let attempt = makeAttempt()
        do {
            return try await attempt.fetch(request)
        } catch {
            let current = makeAttempt()
            if current.generation != attempt.generation {
                // Another request already rotated this failed generation. Give this request its
                // single retry on the current session without consuming budget or rotating again.
                // This applies to cancellation as well as wedge errors: a task captured just as
                // its generation began draining may observe URLSession cancellation before its
                // request was fully registered.
                try Task.checkCancellation()
                return try await current.fetch(request)
            }

            guard Self.isWedge(error) else { throw error }
            switch budget.requestRestart(now: now()) {
            case .allow:
                if rotate(attempt.generation) {
                    rotateCount += 1
                }
                return try await makeAttempt().fetch(request) // one retry on the fresh socket
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

/// A fetch closure bound to the exact transport generation that was current when the request
/// started. Capturing the transport (rather than looking it up after an `await`) closes the race
/// between choosing a generation and creating its URLSession task.
struct UpstreamFetchAttempt: Sendable {
    let generation: Int
    let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Generation source for injected transports that have no concrete URLSession to swap. Keeping
/// this behavior aligned with `SessionBox` makes stale-failure policy testable through the same
/// `UpstreamConnection` path used in production.
final class ClosureUpstreamTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private let rebuild: @Sendable () -> Void
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(rebuild: @escaping @Sendable () -> Void,
         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.rebuild = rebuild
        self.fetch = fetch
    }

    func makeAttempt() -> UpstreamFetchAttempt {
        lock.lock()
        let generation = generation
        let fetch = fetch
        lock.unlock()
        return UpstreamFetchAttempt(generation: generation, fetch: fetch)
    }

    func rotate(ifCurrent expectedGeneration: Int) -> Bool {
        lock.lock()
        guard generation == expectedGeneration else {
            lock.unlock()
            return false
        }
        generation += 1
        lock.unlock()
        rebuild()
        return true
    }
}
