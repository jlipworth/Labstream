import Foundation
import PMSKit

/// Lock-owning state for background URLSession wake completion.
///
/// The coordinator returns effect descriptions instead of invoking callbacks while locked. The
/// session retains persistence, registry-release, diagnostics, and timer-scheduling effects.
final class BackgroundDownloadWakeCoordinator: @unchecked Sendable {
    struct Drain: Sendable, Equatable {
        let completionBatches: [BackgroundDownloadCompletionReleaseBatch]
        let deferredRevalidationKeys: Set<DownloadAttemptKey>

        static let none = Drain(completionBatches: [], deferredRevalidationKeys: [])
    }

    struct Snapshot: Sendable, Equatable {
        let pendingOperationCount: Int
        let deferredIdentifierCount: Int
        let pendingHandlerCount: Int
    }

    struct GraceGeneration: Sendable, Equatable {
        fileprivate let value: UInt64
    }

    struct GraceStart: Sendable, Equatable {
        let generation: GraceGeneration
        let acquiredHold: Bool
    }

    struct GraceEnd: Sendable, Equatable {
        let ended: Bool
        let drain: Drain
    }

    private let budget: DownloadWakeBudget
    private let clockHooks: DownloadWakeClockHooks?
    private var contractWake: DownloadWakeGeneration?

    init(clockHooks: DownloadWakeClockHooks? = nil, budget: DownloadWakeBudget = .application) {
        self.clockHooks = clockHooks
        self.budget = budget
    }

    /// P6.1 scheduling seam only. P6.4 implements identified expiry/release transitions here.
    /// Timers deliberately do not mutate existing count-only gate behavior in this phase.
    private func contractTimerFired() {}

    private let lock = NSLock()
    private var completionGate = BackgroundDownloadCompletionGate()
    private var deferredRevalidationKeys: Set<DownloadAttemptKey> = []
    private var graceGenerations: [DownloadAttemptKey: GraceGeneration] = [:]
    private var nextGraceGeneration: UInt64 = 0

    var hasPendingHandler: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completionGate.hasPendingHandler
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            pendingOperationCount: completionGate.pendingOperationCount,
            deferredIdentifierCount: completionGate.deferredIdentifierCount,
            pendingHandlerCount: completionGate.pendingHandlerCount)
    }

    /// Observes the handler and registers the exact retry in one critical section, preventing a
    /// pending-to-empty transition from landing between the observation and registration.
    func deferRevalidationIfWakePending(_ key: DownloadAttemptKey?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard completionGate.hasPendingHandler else { return false }
        if let key { deferredRevalidationKeys.insert(key) }
        return true
    }

    /// P6.1 identified facade; P6.4 makes expiry/end validate this exact handle. The current
    /// adapter deliberately preserves anonymous count behavior so stale-end pins remain red.
    func beginOperation(kind: DownloadWakeOperation.Kind) -> DownloadWakeOperation {
        beginOperation()
        let operation = DownloadWakeOperation(id: UUID(), wake: lock.withLock { contractWake },
                                     startedAt: clockHooks?.now() ?? DispatchTime.now().uptimeNanoseconds,
                                     kind: kind)
        clockHooks?.register(.init(id: operation.id,
            deadline: operation.startedAt + UInt64(budget.operation * 1_000_000_000),
            kind: .operation)) { [weak self] in self?.contractTimerFired() }
        return operation
    }

    func endOperation(_ operation: DownloadWakeOperation) -> Drain { endOperation() }

    func beginOperation() {
        lock.lock()
        completionGate.beginOperation()
        lock.unlock()
    }

    func endOperation() -> Drain {
        lock.lock()
        let wasPending = completionGate.hasPendingHandler
        let batches = completionGate.endOperation()
        let drain = drainLocked(wasPending: wasPending, batches: batches)
        lock.unlock()
        return drain
    }

    /// P6.1 compatibility adapter. P6.4 preserves the registry's original absolute deadline.
    func storeHandler(_ receipt: DownloadWakeHandlerReceipt) {
        storeHandler(identifier: receipt.identifier, token: receipt.token)
    }

    func storeHandler(identifier: String, token: BackgroundDownloadCompletionHandlerToken) {
        lock.lock()
        completionGate.storeHandler(identifier: identifier, token: token)
        let arm = contractWake == nil
        if arm { contractWake = DownloadWakeGeneration(id: UUID()) }
        lock.unlock()
        if arm, let hooks = clockHooks {
            let now = hooks.now()
            for (seconds, kind) in [(max(0, budget.wholeWake - budget.persistenceReserve), DownloadWakeClockHooks.Timer.Kind.persistenceReserve),
                                    (budget.wholeWake, .absoluteDeadline)] {
                hooks.register(.init(id: UUID(), deadline: now + UInt64(seconds * 1_000_000_000),
                                     kind: kind)) { [weak self] in self?.contractTimerFired() }
            }
        }
    }

    func finishEvents(identifier: String) -> Drain {
        lock.lock()
        let wasPending = completionGate.hasPendingHandler
        let batches = completionGate.finishEvents(identifier: identifier)
        let drain = drainLocked(wasPending: wasPending, batches: batches)
        lock.unlock()
        return drain
    }

    func finishAllAwaitingEvents() -> Drain {
        lock.lock()
        let wasPending = completionGate.hasPendingHandler
        let batches = completionGate.finishAllAwaitingEvents()
        let drain = drainLocked(wasPending: wasPending, batches: batches)
        lock.unlock()
        return drain
    }

    func abortAwaitingHandlers() -> Drain {
        lock.lock()
        let wasPending = completionGate.hasPendingHandler
        let batches = completionGate.abortAwaitingHandlers()
        // Abort zeroes gate operations. Clear matching grace ownership so rearming acquires a real,
        // balanced hold instead of inheriting an operation the gate no longer contains.
        graceGenerations.removeAll()
        let drain = drainLocked(wasPending: wasPending, batches: batches)
        lock.unlock()
        return drain
    }

    /// B00: true while any attempt of the row holds a rebuild grace, i.e. the manager has been asked to
    /// mint a replacement request and no task exists yet. The stale-row self-heal must not restart it.
    func hasGrace(forRatingKey ratingKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return graceGenerations.keys.contains { $0.ratingKey == ratingKey }
    }

    /// Re-arming advances the timer generation but retains one gate operation for the key.
    func beginGrace(for key: DownloadAttemptKey) -> GraceStart {
        lock.lock()
        nextGraceGeneration &+= 1
        let generation = GraceGeneration(value: nextGraceGeneration)
        let acquiredHold = graceGenerations.updateValue(generation, forKey: key) == nil
        if acquiredHold { completionGate.beginOperation() }
        lock.unlock()
        if let hooks = clockHooks {
            hooks.register(.init(id: UUID(), deadline: hooks.now() + UInt64(budget.operation * 1_000_000_000),
                                 kind: .grace)) { [weak self] in self?.contractTimerFired() }
        }
        return GraceStart(generation: generation, acquiredHold: acquiredHold)
    }

    /// A timer may end only the generation it armed. Passing nil is an explicit production end
    /// (replacement registered, pause, or cancellation) and clears the current grace.
    func endGrace(for key: DownloadAttemptKey, generation: GraceGeneration? = nil) -> GraceEnd {
        lock.lock()
        if let generation, graceGenerations[key] != generation {
            lock.unlock()
            return GraceEnd(ended: false, drain: .none)
        }
        guard graceGenerations.removeValue(forKey: key) != nil else {
            lock.unlock()
            return GraceEnd(ended: false, drain: .none)
        }
        let wasPending = completionGate.hasPendingHandler
        let batches = completionGate.endOperation()
        let drain = drainLocked(wasPending: wasPending, batches: batches)
        lock.unlock()
        return GraceEnd(ended: true, drain: drain)
    }

    #if DEBUG
    var deferredRevalidationKeysForTesting: Set<DownloadAttemptKey> {
        lock.lock()
        defer { lock.unlock() }
        return deferredRevalidationKeys
    }
    #endif

    /// Called only under `lock`. The pending-to-empty transition extracts exact deferred keys once;
    /// duplicate finish/end calls therefore cannot publish the same keys again.
    private func drainLocked(
        wasPending: Bool,
        batches: [BackgroundDownloadCompletionReleaseBatch]
    ) -> Drain {
        let didDrain = wasPending && !completionGate.hasPendingHandler
        let keys = didDrain ? deferredRevalidationKeys : []
        if didDrain {
            deferredRevalidationKeys.removeAll()
            // P6.4 acknowledges terminal claim/dispatch after persistence, not this gate drain.
            contractWake = nil
        }
        return Drain(completionBatches: batches, deferredRevalidationKeys: keys)
    }
}
