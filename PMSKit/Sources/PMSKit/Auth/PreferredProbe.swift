import Foundation

/// Concurrent probing of candidates that are ranked by preference.
///
/// Callers such as Plex connection resolution rank candidates (LAN before remote before
/// relay) and must use the *most preferred* candidate that answers, not merely the fastest.
/// Probing them one at a time makes every dead candidate cost a full timeout; probing them
/// all and draining the group makes the slowest dead candidate gate every result.
public enum PreferredProbe {
    /// Lets a lower-ranked success win once higher-ranked candidates have had `grace` to
    /// answer, so one unreachable preferred candidate (for example an advertised LAN address
    /// that is not routable from this network) cannot hold the result for its full timeout.
    public struct EarlyAcceptance: Sendable {
        /// How long higher-ranked pending candidates may keep answering after the first
        /// eligible success arrives.
        public let grace: Duration
        /// Whether a successful candidate at this index may win before every higher-ranked
        /// candidate has failed (for example: never a bandwidth-limited relay).
        public let isEligible: @Sendable (Int) -> Bool

        public init(grace: Duration, isEligible: @escaping @Sendable (Int) -> Bool) {
            self.grace = grace
            self.isEligible = isEligible
        }
    }

    /// Run `probe` for indices in `0..<count` concurrently (at most `maxConcurrent` at a
    /// time, started in preference order) and return the lowest index whose probe produced
    /// a value.
    ///
    /// The result is decided as soon as every lower-ranked index has failed and one index
    /// has succeeded, or — with `earlyAcceptance` — when its grace elapses after an eligible
    /// success, in which case the lowest-ranked eligible success so far wins. Remaining
    /// probes are then cancelled and *not awaited*: a probe that is slow to honour
    /// cancellation finishes in the background without delaying the result. Returns nil
    /// when every probe fails, or when the calling task is cancelled.
    public static func firstSuccess<T: Sendable>(
        count: Int,
        maxConcurrent: Int = .max,
        earlyAcceptance: EarlyAcceptance? = nil,
        _ probe: @escaping @Sendable (Int) async -> T?
    ) async -> (index: Int, value: T)? {
        guard count > 0 else { return nil }
        let window = max(1, maxConcurrent)
        let (events, continuation) = AsyncStream.makeStream(of: ProbeEvent<T>.self)
        let tasks = TaskBag()

        return await withTaskCancellationHandler {
            var nextLaunch = 0
            var inFlight = 0
            func launchAvailable() {
                while nextLaunch < count, inFlight < window {
                    let index = nextLaunch
                    tasks.add(Task {
                        let value = await probe(index)
                        continuation.yield(.outcome(index, value))
                    })
                    nextLaunch += 1
                    inFlight += 1
                }
            }
            func finish() {
                tasks.cancelAll()
                continuation.finish()
            }

            launchAvailable()
            // nil = still pending; .some(nil) = failed; .some(value) = succeeded.
            var outcomes = [T??](repeating: nil, count: count)
            var frontier = 0
            var graceStarted = false
            for await event in events {
                switch event {
                case let .outcome(index, value):
                    inFlight -= 1
                    outcomes[index] = .some(value)
                    while frontier < count, case let .some(resolved) = outcomes[frontier] {
                        if let resolved {
                            finish()
                            return (frontier, resolved)
                        }
                        frontier += 1
                    }
                    if frontier == count {
                        finish()
                        return nil
                    }
                    if value != nil, !graceStarted, let earlyAcceptance,
                       earlyAcceptance.isEligible(index) {
                        graceStarted = true
                        tasks.add(Task {
                            try? await Task.sleep(for: earlyAcceptance.grace)
                            continuation.yield(.graceElapsed)
                        })
                    }
                    launchAvailable()
                case .graceElapsed:
                    guard let earlyAcceptance else { continue }
                    for index in frontier..<count {
                        if case let .some(.some(value)) = outcomes[index],
                           earlyAcceptance.isEligible(index) {
                            finish()
                            return (index, value)
                        }
                    }
                }
            }
            // The stream only ends early when the caller was cancelled.
            return nil
        } onCancel: {
            tasks.cancelAll()
            continuation.finish()
        }
    }

    private enum ProbeEvent<T: Sendable>: Sendable {
        case outcome(Int, T?)
        case graceElapsed
    }

    /// Unstructured probe tasks, so the result never waits for a loser to wind down.
    private final class TaskBag: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []
        private var cancelled = false

        func add(_ task: Task<Void, Never>) {
            lock.lock()
            let alreadyCancelled = cancelled
            if !alreadyCancelled { tasks.append(task) }
            lock.unlock()
            if alreadyCancelled { task.cancel() }
        }

        func cancelAll() {
            lock.lock()
            cancelled = true
            let snapshot = tasks
            tasks = []
            lock.unlock()
            snapshot.forEach { $0.cancel() }
        }
    }
}
