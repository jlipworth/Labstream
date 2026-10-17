#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

/// Delegate-lane fixture only: registration is synchronous, advances call only production timer
/// callbacks, and terminal acknowledgements are separately recorded. No test-side expiry policy.
final class P6WakeClock: @unchecked Sendable {
    struct State {
        var now: UInt64 = 0
        var timers: [(DownloadWakeClockHooks.Timer, @Sendable () -> Void)] = []
        var acknowledgements: [DownloadWakeTerminalAcknowledgement] = []
    }
    let state = Mutex(State())
    var hooks: DownloadWakeClockHooks {
        .init(now: { self.state.withLock { $0.now } },
              register: { timer, action in self.state.withLock { $0.timers.append((timer, action)) } },
              terminalAcknowledged: { ack in self.state.withLock { $0.acknowledgements.append(ack) } })
    }
    func advance(to seconds: UInt64) {
        let actions = state.withLock { value -> [@Sendable () -> Void] in
            value.now = seconds * 1_000_000_000
            let due = value.timers.filter { $0.0.deadline <= value.now }
            value.timers.removeAll { $0.0.deadline <= value.now }
            return due.sorted { $0.0.deadline < $1.0.deadline }.map { $0.1 }
        }
        for action in actions { action() }
    }
    func requireWakeTimers() throws {
        let kinds = state.withLock { $0.timers.map { $0.0.kind } }
        try #require(kinds.contains(.absoluteDeadline))
        try #require(kinds.contains(.persistenceReserve))
    }
}

@Suite("P6 delegate wake pins", .serialized)
struct P6BackgroundWakeTests {
    @Test("P6-pin-06 terminal startup failure releases late and pre-registration tokens once", arguments: [false, true])
    @MainActor func startupFailure(lateRegistration: Bool) throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let registry = BackgroundDownloadCompletionRegistry()
        let fired = Mutex(0)
        let constructions = Mutex(0)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [],
            transportWillConstruct: { constructions.withLock { $0 += 1 } },
            releaseBackgroundCompletion: { registry.fireCompletions(in: $0) })
        defer { session.invalidateInjectedSessionForTesting() }
        if !lateRegistration { registry.register(session) }
        registry.noteStartupWakeState(.blockedBeforeTransport(generation: 1), identifier: BackgroundDownloadSession.identifier)
        let token = registry.store(identifier: BackgroundDownloadSession.identifier) { fired.withLock { $0 += 1 } }
        if lateRegistration { registry.register(session) }
        #expect(fired.withLock { $0 } == 1)
        #expect(!registry.hasPendingHandler(identifier: BackgroundDownloadSession.identifier))
        #expect(!session.startupAdmissionIsActiveForTesting)
        #expect(constructions.withLock { $0 } == 0)
        // Exact-token drain remains idempotent, including if timeout and normal completion race.
        let batch = BackgroundDownloadCompletionReleaseBatch(identifier: BackgroundDownloadSession.identifier, tokens: [token])
        registry.fireCompletions(in: batch)
        registry.fireCompletions(in: batch)
        #expect(fired.withLock { $0 } == 1)
    }

    @Test("P6-pin-07 operation deadline releases its wake and stale A cannot consume B")
    func operationDeadline() throws {
        let clock = P6WakeClock()
        let coordinator = BackgroundDownloadWakeCoordinator(clockHooks: clock.hooks)
        let a = BackgroundDownloadCompletionHandlerToken()
        coordinator.storeHandler(identifier: "wake", token: a)
        let operationA = coordinator.beginOperation(kind: .append)
        #expect(coordinator.finishEvents(identifier: "wake") == .none)
        try clock.requireWakeTimers()
        clock.advance(to: 21)
        #expect(!coordinator.hasPendingHandler)
        // Once A is claimed, B's hold cannot be consumed by A's late/duplicate completion.
        _ = coordinator.abortAwaitingHandlers() // fixture cleanup, not the proposed timeout path
        coordinator.storeHandler(identifier: "wake", token: .init())
        let operationB = coordinator.beginOperation(kind: .append)
        #expect(operationA.id != operationB.id)
        _ = coordinator.finishEvents(identifier: "wake")
        _ = coordinator.endOperation(operationA)
        _ = coordinator.endOperation(operationA) // duplicate delayed A end
        #expect(coordinator.hasPendingHandler)
    }

    @Test("P6-pin-07 grace expiry is bounded and rearmed generations reject stale timers")
    func graceDeadline() throws {
        let clock = P6WakeClock()
        let coordinator = BackgroundDownloadWakeCoordinator(clockHooks: clock.hooks)
        let key = DownloadAttemptKey(ratingKey: "plex:grace", attemptID: .generated())
        coordinator.storeHandler(identifier: "wake", token: .init())
        let a = coordinator.beginGrace(for: key)
        _ = coordinator.finishEvents(identifier: "wake")
        try clock.requireWakeTimers()
        clock.advance(to: 21)
        #expect(!coordinator.hasPendingHandler)
        let b = coordinator.beginGrace(for: key)
        #expect(a.generation != b.generation)
        #expect(!coordinator.endGrace(for: key, generation: a.generation).ended)
        #expect(coordinator.hasGrace(forRatingKey: key.ratingKey))
    }

    @Test("P6-pin-08 late registration preserves registry receipt and caps operation timers")
    func receiptDeadline() throws {
        let clock = P6WakeClock()
        clock.advance(to: 10)
        let coordinator = BackgroundDownloadWakeCoordinator(clockHooks: clock.hooks)
        coordinator.storeHandler(.init(identifier: "wake", token: .init(), receivedAt: 0,
                                      absoluteDeadline: 25_000_000_000))
        try clock.requireWakeTimers()
        let absolute = clock.state.withLock { $0.timers.first { $0.0.kind == .absoluteDeadline }?.0.deadline }
        clock.advance(to: 24)
        _ = coordinator.beginOperation(kind: .append)
        let operation = clock.state.withLock { $0.timers.first { $0.0.kind == .operation }?.0.deadline }
        #expect(absolute == 25_000_000_000)
        #expect(operation == 25_000_000_000)
    }

    @Test("P6-pin-08 balanced operations cannot slide the one absolute wake deadline")
    func balancedOperations() throws {
        let clock = P6WakeClock()
        let coordinator = BackgroundDownloadWakeCoordinator(clockHooks: clock.hooks)
        coordinator.storeHandler(identifier: "wake", token: .init())
        coordinator.beginOperation()
        _ = coordinator.finishEvents(identifier: "wake")
        try clock.requireWakeTimers()
        for second in 1...24 {
            coordinator.beginOperation()
            _ = coordinator.endOperation()
            clock.advance(to: UInt64(second))
        }
        clock.advance(to: 25)
        #expect(!coordinator.hasPendingHandler)
        #expect(coordinator.snapshot.pendingOperationCount == 1) // physical work is retained
    }

    @Test("P6-pin-08 amendment: successful proactive flush cannot release a blocked append")
    func flushWhileAppendBlocked() async throws {
        try await blockedAppend(finishEvents: true)
    }

    @Test("P6-pin-08 amendment: missing finish-events expires even after a committed flush")
    func neverFinishEvents() async throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let clock = P6WakeClock()
        let coordinator = BackgroundDownloadWakeCoordinator(clockHooks: clock.hooks)
        coordinator.storeHandler(identifier: "wake", token: .init())
        try clock.requireWakeTimers()
        let proof = await store.flushLifecycleAndPersistence(through: store.currentPersistenceTicket(),
            artifactWatermark: store.currentArtifactLifecycleWatermark(), timeout: 2)
        guard case .committed = proof else { Issue.record("proactive proof failed"); return }
        #expect(coordinator.hasPendingHandler)
        #expect(coordinator.snapshot.pendingOperationCount == 0)
        clock.advance(to: 25)
        #expect(!coordinator.hasPendingHandler)
    }

    private func blockedAppend(finishEvents: Bool, verifyRecovery: Bool = false) async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        let working = try fixture.working(initial, key)
        #expect(initial.resetStaticRangeProgressToDurableCheckpoint(for: key, expectedBytes: 10) == .applied(bytes: 3))
        let artifactHold = P6Hold()
        let live = DownloadArtifactFilesystem.live
        let store = DownloadStore(baseDirectory: fixture.directory, artifactFilesystem: .init(
            writeAuthArtifact: { data, url, manager in
                try live.writeAuthArtifact(data, url, manager)
                artifactHold.hit()
            }, removeItem: live.removeItem, fileExists: live.fileExists))
        let source = fixture.directory.appendingPathComponent("body.part")
        try Data([4, 5]).write(to: source)
        let hold = P6Hold()
        let clock = P6WakeClock()
        let registry = await MainActor.run { BackgroundDownloadCompletionRegistry(clockHooks: clock.hooks) }
        let fired = Mutex(0)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [], wakeClockHooks: clock.hooks,
            appendWillPerformIO: { _, _ in hold.hit() },
            releaseBackgroundCompletion: { registry.fireCompletions(in: $0) })
        defer { hold.release.signal(); artifactHold.release.signal(); session.invalidateInjectedSessionForTesting() }
        session.claimRangeBodyForTesting(source, for: key, bytes: 2)
        session.beginBackgroundCompletionOperationForTesting()
        await MainActor.run {
            registry.register(session)
            registry.store(identifier: BackgroundDownloadSession.identifier) { fired.withLock { $0 += 1 } }
        }
        try clock.requireWakeTimers()
        hold.arm()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? session.appendFileForP6Testing(at: source, onto: working)
            session.endBackgroundCompletionOperationForTesting()
            done.signal()
        }
        try #require(await p6Signal(hold.entered))
        var pendingArtifact: DownloadStore.AttemptResumeDataSubmission?
        if verifyRecovery {
            artifactHold.arm()
            pendingArtifact = store.submitResumeData(for: key, Data([9]))
            try #require(await p6Signal(artifactHold.entered))
        }
        if finishEvents { session.finishBackgroundEventsForTesting(identifier: BackgroundDownloadSession.identifier) }
        let proof = await store.flushPersistence(through: store.currentPersistenceTicket(), timeout: 2)
        guard case .committed = proof else { Issue.record("proactive proof failed"); return }
        #expect(fired.withLock { $0 } == 0) // covering flush alone is never normal drain
        clock.advance(to: 25)
        let terminal = clock.state.withLock { $0.acknowledgements }
        let stillPending = await MainActor.run { registry.hasPendingHandler(identifier: BackgroundDownloadSession.identifier) }
        #expect(!stillPending)
        #expect(fired.withLock { $0 } == 1)
        #expect(terminal.count == 1)
        #expect(terminal.first?.outcome == .timedOut)
        // P6-pin-09: expiry never drops actual attempt/body ownership or committed checkpoint.
        #expect(store.ownsAttempt(key))
        #expect(session.claimedRangeBodiesForTesting().contains(source.standardizedFileURL))
        #expect(try Data(contentsOf: working) == Data([1, 2, 3]))
        if verifyRecovery {
            let reinitialized = fixture.store()
            #expect(reinitialized.record(for: key)?.bytes == 3)
            #expect(reinitialized.resolveArtifactSynchronouslyForTests(
                through: reinitialized.currentArtifactLifecycleWatermark()) == .completed)
            #expect(reinitialized.resumeData(for: key) == Data([9]))
            #expect(reinitialized.record(for: key)?.bytes == 3)
            artifactHold.release.signal()
            if let pendingArtifact { #expect(await store.resolve(pendingArtifact, deadline: .after(2)) == .applied) }
        }
        hold.release.signal()
        try #require(await p6Signal(done))
        #expect(try Data(contentsOf: working) == Data([1, 2, 3, 4, 5]))
        session.releaseRangeBodyForTesting(source)
    }

    @Test("P6-pin-08 absolute deadline supervises a slow index flush already in flight")
    func slowFlushInFlight() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        let hold = P6Hold()
        let store = fixture.store(index: .init { data, url in
            hold.hit()
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        let clock = P6WakeClock()
        let registry = await MainActor.run { BackgroundDownloadCompletionRegistry(clockHooks: clock.hooks) }
        let fired = Mutex(0)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [], wakeClockHooks: clock.hooks,
            releaseBackgroundCompletion: { registry.fireCompletions(in: $0) })
        defer { hold.release.signal(); session.invalidateInjectedSessionForTesting() }
        await MainActor.run {
            registry.register(session)
            registry.store(identifier: BackgroundDownloadSession.identifier) { fired.withLock { $0 += 1 } }
        }
        hold.arm()
        _ = store.submitProgress(for: key, bytes: 1, progress: 0.1)
        try #require(await p6Signal(hold.entered))
        try clock.requireWakeTimers()
        session.finishBackgroundEventsForTesting(identifier: BackgroundDownloadSession.identifier)
        clock.advance(to: 25)
        let pending = await MainActor.run { registry.hasPendingHandler(identifier: BackgroundDownloadSession.identifier) }
        #expect(!pending)
        #expect(fired.withLock { $0 } == 1)
        #expect(clock.state.withLock { $0.timers.isEmpty }) // no new five-second budget at expiry
        hold.release.signal()
        _ = await store.flushPersistence(through: store.currentPersistenceTicket(), timeout: 2)
    }

    @Test("Normal release waits for a proof of the last settled operation, including work during flush")
    func proofMustCoverResultingBoundary() throws {
        let clock = P6WakeClock()
        let coordinator = BackgroundDownloadWakeCoordinator(clockHooks: clock.hooks)
        let first = BackgroundDownloadCompletionHandlerToken()
        coordinator.storeHandler(identifier: "wake", token: first)
        let early = try #require(coordinator.finishEvents(identifier: "wake").flush)
        #expect(coordinator.hasPendingHandler) // a flush does not claim the tokens
        let operation = coordinator.beginOperation(kind: .heldLifecycle)
        #expect(coordinator.persistenceFinished(early, committed: true) == .none)
        #expect(coordinator.hasPendingHandler)
        let resulting = try #require(coordinator.endOperation(operation).flush)
        #expect(resulting.epoch != early.epoch)
        let terminal = coordinator.persistenceFinished(resulting, committed: true)
        #expect(terminal.completionBatches == [.init(identifier: "wake", tokens: [first])])
        #expect(terminal.outcome == .drained)
        #expect(!coordinator.hasPendingHandler)
        #expect(clock.state.withLock { $0.acknowledgements.map(\.outcome) } == [.drained])
        #expect(coordinator.persistenceFinished(resulting, committed: true) == .none)
    }

    @Test("Expired A remains physically owned but cannot hold or expire successor wake B")
    func expiredOperationCannotJoinSuccessor() throws {
        let clock = P6WakeClock()
        let coordinator = BackgroundDownloadWakeCoordinator(clockHooks: clock.hooks)
        coordinator.storeHandler(identifier: "wake", token: .init())
        let old = coordinator.beginOperation(kind: .append)
        clock.advance(to: 20)
        #expect(!coordinator.hasPendingHandler)
        #expect(coordinator.snapshot.pendingOperationCount == 1)
        let successor = BackgroundDownloadCompletionHandlerToken()
        coordinator.storeHandler(identifier: "wake", token: successor)
        let flush = try #require(coordinator.finishEvents(identifier: "wake").flush)
        clock.advance(to: 25) // the old absolute timer cannot claim B
        #expect(coordinator.hasPendingHandler)
        #expect(coordinator.endOperation(old) == .none)
        #expect(coordinator.endOperation(old) == .none)
        let terminal = coordinator.persistenceFinished(flush, committed: true)
        #expect(terminal.completionBatches == [.init(identifier: "wake", tokens: [successor])])
        #expect(terminal.outcome == .drained)
    }

    @Test("A new token during normal flush needs its own finish event and cannot enter the old proof")
    func newTokenDuringFlush() throws {
        let clock = P6WakeClock()
        let coordinator = BackgroundDownloadWakeCoordinator(clockHooks: clock.hooks)
        coordinator.storeHandler(identifier: "wake", token: .init())
        let early = try #require(coordinator.finishEvents(identifier: "wake").flush)
        coordinator.storeHandler(identifier: "wake", token: .init())
        #expect(coordinator.persistenceFinished(early, committed: true) == .none)
        #expect(coordinator.hasPendingHandler)
        let resulting = try #require(coordinator.finishEvents(identifier: "wake").flush)
        let terminal = coordinator.persistenceFinished(resulting, committed: true)
        #expect(terminal.completionBatches.reduce(0) { $0 + $1.tokens.count } == 2)
        #expect(terminal.outcome == .drained)
    }

    @Test("Registry receipt survives delayed registration and deferred startup without transport")
    @MainActor func deferredStartupBudget() async throws {
        let fixture = try P6Fixture()
        let clock = P6WakeClock()
        let registry = BackgroundDownloadCompletionRegistry(clockHooks: clock.hooks)
        let fired = Mutex(0)
        let delivered = DispatchSemaphore(value: 0)
        let token = registry.store(identifier: BackgroundDownloadSession.identifier) {
            fired.withLock { $0 += 1 }; delivered.signal()
        }
        // Cleanup is independent of callback scheduling and the bounded acknowledgement below.
        defer { registry.fireCompletions(in: .init(identifier: BackgroundDownloadSession.identifier, tokens: [token])) }
        clock.advance(to: 10)
        let session = BackgroundDownloadSession(store: fixture.store(), protocolClasses: [], wakeClockHooks: clock.hooks,
            releaseBackgroundCompletion: { registry.fireCompletions(in: $0) })
        defer { session.invalidateInjectedSessionForTesting() }
        registry.register(session)
        clock.advance(to: 25)
        #expect(await p6Signal(delivered))
        #expect(fired.withLock { $0 } == 1)
        #expect(!registry.hasPendingHandler(identifier: BackgroundDownloadSession.identifier))
        #expect(clock.state.withLock { $0.acknowledgements.map(\.outcome) } == [.timedOut])
        #expect(!session.startupAdmissionIsActiveForTesting)
    }

    @Test("Registry fallback bounds a wake that never registers a session")
    @MainActor func registryWithoutRegistration() async {
        let clock = P6WakeClock()
        let registry = BackgroundDownloadCompletionRegistry(clockHooks: clock.hooks)
        let fired = Mutex(0)
        let delivered = DispatchSemaphore(value: 0)
        let token = registry.store(identifier: "wake") {
            fired.withLock { $0 += 1 }; delivered.signal()
        }
        defer { registry.fireCompletions(in: .init(identifier: "wake", tokens: [token])) }
        clock.advance(to: 25)
        #expect(await p6Signal(delivered))
        #expect(fired.withLock { $0 } == 1)
        #expect(!registry.hasPendingHandler(identifier: "wake"))
    }

    @Test("P6-pin-09 timeout retains a physically active owner and does not consume a new token")
    func physicalOwnerAfterTimeout() async throws {
        try await blockedAppend(finishEvents: true, verifyRecovery: true)
    }
}
#endif
