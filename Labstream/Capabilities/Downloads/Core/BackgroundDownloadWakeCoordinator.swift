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

    func storeHandler(identifier: String, token: BackgroundDownloadCompletionHandlerToken) {
        lock.lock()
        completionGate.storeHandler(identifier: identifier, token: token)
        lock.unlock()
    }

    func finishEvents(identifier: String) -> Drain {
        lock.lock()
        let wasPending = completionGate.hasPendingHandler
        let batches = completionGate.finishEvents(identifier: identifier)
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

    /// Re-arming advances the timer generation but retains one gate operation for the key.
    func beginGrace(for key: DownloadAttemptKey) -> GraceStart {
        lock.lock()
        nextGraceGeneration &+= 1
        let generation = GraceGeneration(value: nextGraceGeneration)
        let acquiredHold = graceGenerations.updateValue(generation, forKey: key) == nil
        if acquiredHold { completionGate.beginOperation() }
        lock.unlock()
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
        if didDrain { deferredRevalidationKeys.removeAll() }
        return Drain(completionBatches: batches, deferredRevalidationKeys: keys)
    }
}
