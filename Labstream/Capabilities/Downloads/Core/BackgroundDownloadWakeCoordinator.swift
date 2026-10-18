import Foundation
import PMSKit

/// Owns wake release, independently of the lifetime of physical workers. No effect runs locked.
final class BackgroundDownloadWakeCoordinator: @unchecked Sendable {
    struct Flush: Sendable, Equatable {
        let generation: DownloadWakeGeneration
        let epoch: UInt64
        let remaining: TimeInterval
    }
    struct Drain: Sendable, Equatable {
        let completionBatches: [BackgroundDownloadCompletionReleaseBatch]
        let deferredRevalidationKeys: Set<DownloadAttemptKey>
        var flush: Flush? = nil
        var outcome: DownloadWakeTerminalAcknowledgement.Outcome? = nil
        var terminalAcknowledgement: DownloadWakeTerminalAcknowledgement? = nil
        var reason: String? = nil
        var elapsed: TimeInterval = 0
        var pendingKinds: Set<String> = []
        var expiredGraces: [DownloadAttemptKey: GraceGeneration] = [:]
        static let none = Drain(completionBatches: [], deferredRevalidationKeys: [])
    }
    struct Snapshot: Sendable, Equatable {
        let expiredOperationCount: Int
        let pendingOperationCount: Int
        let deferredIdentifierCount: Int
        let pendingHandlerCount: Int
    }
    struct GraceGeneration: Sendable, Equatable { fileprivate let value: UInt64 }
    struct GraceStart: Sendable, Equatable {
        let generation: GraceGeneration
        let acquiredHold: Bool
    }
    struct GraceEnd: Sendable, Equatable {
        let ended: Bool
        let drain: Drain
    }
    private struct Wake {
        let generation: DownloadWakeGeneration
        var deadline: UInt64
        let receivedAt: UInt64
        var required: Set<UUID>
        var awaiting: [String: [BackgroundDownloadCompletionHandlerToken]] = [:]
        var finished: [BackgroundDownloadCompletionReleaseBatch] = []
        var epoch: UInt64 = 0
        var flushing: UInt64?
        var proof: UInt64?
        var windingDown = false
    }
    private let lock = NSLock()
    private let budget: DownloadWakeBudget
    private let clock: DownloadWakeClockHooks
    private var wake: Wake?
    private var operations: [UUID: DownloadWakeOperation] = [:]
    private var expiredOperations: Set<UUID> = []
    private var backgroundAuthorizationExpired = false
    private var anonymousOperations: [DownloadWakeOperation] = []
    private var deferredRevalidationKeys: Set<DownloadAttemptKey> = []
    private var graceGenerations: [DownloadAttemptKey: (GraceGeneration, DownloadWakeOperation, UInt64)] = [:]
    private var nextGraceGeneration: UInt64 = 0
    private var effect: (@Sendable (Drain) -> Void)?

    init(clockHooks: DownloadWakeClockHooks? = nil, budget: DownloadWakeBudget = .application) {
        clock = clockHooks ?? .live
        self.budget = budget
    }

    func setEffectHandler(_ handler: @escaping @Sendable (Drain) -> Void) {
        lock.withLock { effect = handler }
    }

    var hasPendingHandler: Bool { lock.withLock { wake != nil } }
    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(expiredOperationCount: expiredOperations.count, pendingOperationCount: operations.count,
                     deferredIdentifierCount: Set(wake?.finished.map(\.identifier) ?? []).count,
                     pendingHandlerCount: (wake?.awaiting.values.reduce(0) { $0 + $1.count } ?? 0)
                        + (wake?.finished.reduce(0) { $0 + $1.tokens.count } ?? 0))
        }
    }
    var operationTimeout: TimeInterval { budget.operation }
    func remainingTimeout(for flush: Flush) -> TimeInterval {
        lock.withLock {
            guard let current = wake, current.generation == flush.generation else { return 0 }
            return min(flush.remaining, remaining(current.deadline))
        }
    }
    var hasExpiredBackgroundAuthorization: Bool {
        lock.withLock { backgroundAuthorizationExpired }
    }
    var isWindingDown: Bool {
        lock.withLock { backgroundAuthorizationExpired || wake?.windingDown == true || !expiredOperations.isEmpty }
    }
    /// OS handler release does not authorize foreground work. Only a new wake or an
    /// explicit active-scene edge can restore that permission after expiry.
    func noteForegroundAuthorization() {
        lock.withLock { backgroundAuthorizationExpired = false }
    }
    var remainingTimeout: TimeInterval {
        lock.withLock { wake.map { remaining($0.deadline) } ?? budget.operation }
    }
    func deferRevalidationIfWakePending(_ key: DownloadAttemptKey?) -> Bool {
        lock.withLock {
            guard backgroundAuthorizationExpired || wake != nil || !expiredOperations.isEmpty else {
                if let key { deferredRevalidationKeys.remove(key) }
                return false
            }
            if let key { deferredRevalidationKeys.insert(key) }
            return true
        }
    }

    @discardableResult
    func beginOperation(kind: DownloadWakeOperation.Kind) -> DownloadWakeOperation {
        let operation = lock.withLock {
            let operation = DownloadWakeOperation(id: UUID(), wake: wake?.generation,
                                                  startedAt: clock.now(), kind: kind)
            operations[operation.id] = operation
            if wake == nil && !expiredOperations.isEmpty { expiredOperations.insert(operation.id) }
            wake?.required.insert(operation.id)
            wake?.epoch &+= 1
            return operation
        }
        arm(operation)
        return operation
    }
    func endOperation(_ operation: DownloadWakeOperation) -> Drain {
        lock.lock()
        guard operations.removeValue(forKey: operation.id) == operation else {
            lock.unlock(); return .none
        }
        expiredOperations.remove(operation.id)
        if wake?.required.remove(operation.id) != nil { wake?.epoch &+= 1 }
        let drain = progressLocked()
        lock.unlock()
        if let ack = drain.terminalAcknowledgement { clock.terminalAcknowledged(ack) }
        return drain
    }

    // Compatibility for older count-only fixtures. Production always captures an exact handle.
    func beginOperation() {
        let operation = beginOperation(kind: .append)
        lock.withLock { anonymousOperations.append(operation) }
    }
    func endOperation() -> Drain {
        guard let operation = lock.withLock({ anonymousOperations.popLast() }) else { return .none }
        return endOperation(operation)
    }

    func storeHandler(identifier: String, token: BackgroundDownloadCompletionHandlerToken) {
        let now = clock.now()
        storeHandler(.init(identifier: identifier, token: token, receivedAt: now,
                           absoluteDeadline: DownloadWakeBudget.deadline(from: now, after: budget.wholeWake)))
    }
    func storeHandler(_ receipt: DownloadWakeHandlerReceipt) {
        lock.lock()
        let isNew = wake == nil
        if isNew {
            backgroundAuthorizationExpired = false
            wake = Wake(generation: .init(id: UUID()), deadline: receipt.absoluteDeadline,
                        receivedAt: receipt.receivedAt, required: Set(operations.keys).subtracting(expiredOperations))
        }
        guard var current = wake else { lock.unlock(); return }
        guard !current.awaiting.values.contains(where: { $0.contains(receipt.token) }),
              !current.finished.contains(where: { $0.tokens.contains(receipt.token) }) else {
            lock.unlock(); return
        }
        let previousDeadline = current.deadline
        current.deadline = min(current.deadline, receipt.absoluteDeadline)
        current.awaiting[receipt.identifier, default: []].append(receipt.token)
        current.epoch &+= 1
        wake = current
        let generation = current.generation
        let outstanding = operations.values.filter { current.required.contains($0.id) && $0.kind != .grace }
        let graces = graceGenerations.filter { current.required.contains($0.value.1.id) }
        lock.unlock()
        if isNew || current.deadline < previousDeadline {
            let reserve = UInt64(max(0, budget.persistenceReserve) * 1_000_000_000)
            let start = current.deadline > reserve ? current.deadline - reserve : 0
            register(deadline: start, kind: .persistenceReserve) { [weak self] in
                self?.timerFired(generation: generation, hard: false)
            }
            register(deadline: current.deadline, kind: .absoluteDeadline) { [weak self] in
                self?.timerFired(generation: generation, hard: true)
            }
            // Work admitted before a handler remains required, without renewing its start time.
            for operation in outstanding { arm(operation) }
            for (key, grace) in graces {
                let deadline = min(DownloadWakeBudget.deadline(from: grace.2, after: budget.operation), current.deadline)
                register(deadline: deadline, kind: .grace) { [weak self] in
                    self?.graceExpired(key, generation: grace.0, wake: generation)
                }
            }
        }
    }

    func finishEvents(identifier: String) -> Drain {
        lock.lock()
        if let tokens = wake?.awaiting.removeValue(forKey: identifier), !tokens.isEmpty {
            wake?.finished.append(.init(identifier: identifier, tokens: tokens))
        }
        let drain = progressLocked()
        lock.unlock()
        if let ack = drain.terminalAcknowledgement { clock.terminalAcknowledged(ack) }
        return drain
    }
    func finishAllAwaitingEvents() -> Drain {
        lock.lock()
        if let awaiting = wake?.awaiting {
            for identifier in awaiting.keys.sorted() {
                wake?.finished.append(.init(identifier: identifier, tokens: awaiting[identifier]!))
            }
            wake?.awaiting.removeAll()
        }
        let drain = progressLocked()
        lock.unlock()
        if let ack = drain.terminalAcknowledgement { clock.terminalAcknowledged(ack) }
        return drain
    }

    /// Only terminal failure before transport exists may discard startup-only holds.
    func abortAwaitingHandlers() -> Drain {
        lock.lock()
        operations.removeAll()
        expiredOperations.removeAll()
        anonymousOperations.removeAll()
        graceGenerations.removeAll()
        let drain = claimLocked(.startupBlocked)
        lock.unlock()
        acknowledge(drain)
        return drain.value
    }

    /// The exact flush boundary was captured after epoch's last required operation settled.
    /// A concurrent operation invalidates that proof, even if the old flush later succeeds.
    func persistenceFinished(_ flush: Flush, committed: Bool) -> Drain {
        lock.lock()
        guard wake?.generation == flush.generation, wake?.flushing == flush.epoch else {
            lock.unlock(); return .none
        }
        wake?.flushing = nil
        if committed { wake?.proof = flush.epoch }
        let expired = wake.map { remaining($0.deadline) <= 0 } ?? false
        if expired {
            let drain = claimLocked(.timedOut)
            lock.unlock(); acknowledge(drain); return drain.value
        }
        if !committed { lock.unlock(); return .none } // dirty work remains supervised until expiry
        let drain = progressLocked()
        lock.unlock()
        if let ack = drain.terminalAcknowledgement { clock.terminalAcknowledged(ack) }
        return drain
    }

    func hasGrace(forRatingKey ratingKey: String) -> Bool {
        lock.withLock { graceGenerations.keys.contains { $0.ratingKey == ratingKey } }
    }
    func beginGrace(for key: DownloadAttemptKey) -> GraceStart {
        lock.lock()
        nextGraceGeneration &+= 1
        let generation = GraceGeneration(value: nextGraceGeneration)
        let previous = graceGenerations[key]
        let operation = previous?.1 ?? DownloadWakeOperation(
            id: UUID(), wake: wake?.generation, startedAt: clock.now(), kind: .grace)
        operations[operation.id] = operation
        graceGenerations[key] = (generation, operation, clock.now())
        if previous == nil {
            wake?.required.insert(operation.id)
            wake?.epoch &+= 1
        }
        let deadline = min(DownloadWakeBudget.deadline(from: clock.now(), after: budget.operation),
                           wake?.deadline ?? UInt64.max)
        let owner = wake?.generation
        lock.unlock()
        register(deadline: deadline, kind: .grace) { [weak self] in
            self?.graceExpired(key, generation: generation, wake: owner)
        }
        return GraceStart(generation: generation, acquiredHold: previous == nil)
    }
    func endGrace(for key: DownloadAttemptKey, generation: GraceGeneration? = nil) -> GraceEnd {
        lock.lock()
        guard let current = graceGenerations[key], generation == nil || current.0 == generation else {
            lock.unlock(); return GraceEnd(ended: false, drain: .none)
        }
        graceGenerations.removeValue(forKey: key)
        operations.removeValue(forKey: current.1.id)
        expiredOperations.remove(current.1.id)
        if wake?.required.remove(current.1.id) != nil { wake?.epoch &+= 1 }
        let drain = progressLocked()
        lock.unlock()
        if let ack = drain.terminalAcknowledgement { clock.terminalAcknowledged(ack) }
        return GraceEnd(ended: true, drain: drain)
    }

    #if DEBUG
    var deferredRevalidationKeysForTesting: Set<DownloadAttemptKey> {
        lock.withLock { deferredRevalidationKeys }
    }
    #endif

    private func remaining(_ deadline: UInt64) -> TimeInterval {
        let now = clock.now()
        return deadline > now ? Double(deadline - now) / 1_000_000_000 : 0
    }
    private func register(deadline: UInt64, kind: DownloadWakeClockHooks.Timer.Kind,
                          action: @escaping @Sendable () -> Void) {
        clock.register(.init(id: UUID(), deadline: deadline, kind: kind), action)
    }
    private func arm(_ operation: DownloadWakeOperation) {
        let owner = lock.withLock { wake?.generation }
        let deadline = lock.withLock {
            min(DownloadWakeBudget.deadline(from: operation.startedAt, after: budget.operation),
                wake?.deadline ?? UInt64.max)
        }
        register(deadline: deadline, kind: .operation) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.operations[operation.id] == operation,
                  let owner, self.wake?.generation == owner,
                  self.wake?.required.contains(operation.id) == true else { self.lock.unlock(); return }
            let drain = self.claimLocked(.timedOut, reason: "operation_watchdog")
            self.lock.unlock()
            self.publish(drain)
        }
    }
    private func graceExpired(_ key: DownloadAttemptKey, generation: GraceGeneration,
                              wake owner: DownloadWakeGeneration?) {
        lock.lock()
        guard graceGenerations[key]?.0 == generation else { lock.unlock(); return }
        // End OS-wake permission independently of cleanup. The session returns physical grace
        // cleanup to its serial worker; a queued append or stuck syscall cannot delay release.
        var drain: Claim = (.none, nil)
        if let owner, wake?.generation == owner {
            drain = claimLocked(.timedOut, reason: "grace_watchdog")
        }
        drain.value.expiredGraces[key] = generation
        lock.unlock()
        publish(drain)
    }
    private func timerFired(generation: DownloadWakeGeneration, hard: Bool) {
        lock.lock()
        guard wake?.generation == generation else { lock.unlock(); return }
        if hard {
            let drain = claimLocked(.timedOut, reason: "absolute_deadline")
            lock.unlock(); publish(drain)
        } else {
            wake?.windingDown = true
            let drain = progressLocked(proactive: true)
            let handler = effect
            lock.unlock()
            handler?(drain)
        }
    }
    private func progressLocked(proactive: Bool = false) -> Drain {
        guard let current = wake else { return .none }
        let predicate = DownloadWakeReleasePredicate(
            finishEvents: current.awaiting.isEmpty,
            requiredOperationsSettled: current.required.isEmpty,
            persistenceCoversResultingBoundary: current.proof == current.epoch)
        if predicate.permitsNormalRelease {
            let drain = claimLocked(.drained)
            return drain.value
        }
        guard current.flushing == nil,
              (proactive || (current.awaiting.isEmpty && current.required.isEmpty)),
              remaining(current.deadline) > 0 else { return .none }
        wake?.flushing = current.epoch
        return Drain(completionBatches: [], deferredRevalidationKeys: [],
                     flush: .init(generation: current.generation, epoch: current.epoch,
                                  remaining: min(budget.persistenceReserve, remaining(current.deadline))))
    }
    private typealias Claim = (value: Drain, ack: DownloadWakeTerminalAcknowledgement?)
    private func claimLocked(_ outcome: DownloadWakeTerminalAcknowledgement.Outcome,
                             reason: String? = nil) -> Claim {
        guard let current = wake else { return (.none, nil) }
        let batches = current.finished + current.awaiting.keys.sorted().map {
            BackgroundDownloadCompletionReleaseBatch(identifier: $0, tokens: current.awaiting[$0]!)
        }
        if outcome == .timedOut {
            backgroundAuthorizationExpired = true
            expiredOperations.formUnion(current.required)
        }
        wake = nil
        // Timed-out deferred probes remain parked until an authorized foreground edge.
        let keys = outcome == .drained ? deferredRevalidationKeys : []
        if outcome == .drained { deferredRevalidationKeys.removeAll() }
        let acknowledgement = DownloadWakeTerminalAcknowledgement(
            generation: current.generation, outcome: outcome, batches: batches)
        return (Drain(completionBatches: batches, deferredRevalidationKeys: keys, outcome: outcome,
                      terminalAcknowledgement: acknowledgement,
                      reason: reason ?? outcome.diagnosticLabel,
                      elapsed: Double(clock.now() - min(clock.now(), current.receivedAt)) / 1_000_000_000,
                      pendingKinds: Set(operations.values.filter { current.required.contains($0.id) }
                        .map { String(describing: $0.kind) })), acknowledgement)
    }
    private func acknowledge(_ claim: Claim) {
        if let ack = claim.ack { clock.terminalAcknowledged(ack) }
    }
    private func publish(_ claim: Claim) {
        acknowledge(claim)
        let handler = lock.withLock { effect }
        handler?(claim.value)
    }
}
