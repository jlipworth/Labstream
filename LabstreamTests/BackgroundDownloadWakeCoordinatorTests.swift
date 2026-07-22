import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Background download wake coordinator")
struct BackgroundDownloadWakeCoordinatorTests {
    @Test("Pending-handler observation and exact-key deferral drain atomically once")
    func atomicDeferralAndExactOnceDrain() throws {
        let coordinator = BackgroundDownloadWakeCoordinator()
        let first = try key("first")
        let second = try key("second")
        let token = deterministicToken(1)

        #expect(!coordinator.deferRevalidationIfWakePending(first))
        coordinator.storeHandler(identifier: "wake", token: token)
        #expect(coordinator.deferRevalidationIfWakePending(first))
        #expect(coordinator.deferRevalidationIfWakePending(second))
        #expect(coordinator.deferRevalidationIfWakePending(first))

        let drain = coordinator.finishEvents(identifier: "wake")
        #expect(drain.completionBatches == [batch("wake", token)])
        #expect(drain.deferredRevalidationKeys == [first, second])
        #expect(!coordinator.hasPendingHandler)
        #expect(coordinator.finishEvents(identifier: "wake") == .none)
        #expect(coordinator.endOperation() == .none)
    }

    @Test("Deferred handlers and keys wait for every operation")
    func operationsDrainTogether() throws {
        let coordinator = BackgroundDownloadWakeCoordinator()
        let attempt = try key("held")
        let token = deterministicToken(2)
        coordinator.storeHandler(identifier: "wake", token: token)
        coordinator.beginOperation()
        coordinator.beginOperation()
        #expect(coordinator.deferRevalidationIfWakePending(attempt))
        #expect(coordinator.finishEvents(identifier: "wake") == .none)

        #expect(coordinator.endOperation() == .none)
        let drain = coordinator.endOperation()
        #expect(drain.completionBatches == [batch("wake", token)])
        #expect(drain.deferredRevalidationKeys == [attempt])
        #expect(coordinator.snapshot.pendingOperationCount == 0)
    }

    @Test("Grace rearm advances generation without double begin and stale timer is a no-op")
    func graceRearmIsBalancedAndStaleSafe() throws {
        let coordinator = BackgroundDownloadWakeCoordinator()
        let attempt = try key("rearm")
        let token = deterministicToken(3)
        coordinator.storeHandler(identifier: "wake", token: token)

        let first = coordinator.beginGrace(for: attempt)
        #expect(first.acquiredHold)
        let second = coordinator.beginGrace(for: attempt)
        #expect(!second.acquiredHold)
        #expect(first.generation != second.generation)
        #expect(coordinator.snapshot.pendingOperationCount == 1)
        #expect(coordinator.finishEvents(identifier: "wake") == .none)

        let stale = coordinator.endGrace(for: attempt, generation: first.generation)
        #expect(!stale.ended)
        #expect(stale.drain == .none)
        #expect(coordinator.snapshot.pendingOperationCount == 1)

        let current = coordinator.endGrace(for: attempt, generation: second.generation)
        #expect(current.ended)
        #expect(current.drain.completionBatches == [batch("wake", token)])
        #expect(coordinator.snapshot.pendingOperationCount == 0)
        #expect(!coordinator.endGrace(for: attempt, generation: second.generation).ended)
    }

    @Test("Explicit grace end invalidates its timer generation")
    func explicitEndInvalidatesTimer() throws {
        let coordinator = BackgroundDownloadWakeCoordinator()
        let attempt = try key("explicit")
        let start = coordinator.beginGrace(for: attempt)

        let explicit = coordinator.endGrace(for: attempt)
        #expect(explicit.ended)
        #expect(explicit.drain == .none)
        #expect(!coordinator.endGrace(for: attempt, generation: start.generation).ended)
        #expect(coordinator.snapshot.pendingOperationCount == 0)
    }

    @Test("Startup abort clears grace ownership and permits a balanced rearm")
    func abortClearsGraceOwnership() throws {
        let coordinator = BackgroundDownloadWakeCoordinator()
        let attempt = try key("abort")
        let token = deterministicToken(4)
        coordinator.storeHandler(identifier: "wake", token: token)
        _ = coordinator.beginGrace(for: attempt)

        #expect(coordinator.abortAwaitingHandlers().completionBatches == [batch("wake", token)])
        #expect(coordinator.snapshot.pendingOperationCount == 0)
        let rearmed = coordinator.beginGrace(for: attempt)
        #expect(rearmed.acquiredHold)
        #expect(coordinator.snapshot.pendingOperationCount == 1)
        #expect(coordinator.endGrace(for: attempt, generation: rearmed.generation).ended)
        #expect(coordinator.snapshot.pendingOperationCount == 0)
    }

    private func key(_ suffix: String) throws -> DownloadAttemptKey {
        DownloadAttemptKey(
            ratingKey: "plex:\(suffix)",
            attemptID: try #require(DownloadAttemptID(rawValue: "attempt-\(suffix)")))
    }

    private func deterministicToken(_ suffix: UInt8) -> BackgroundDownloadCompletionHandlerToken {
        BackgroundDownloadCompletionHandlerToken(
            rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)))
    }

    private func batch(
        _ identifier: String,
        _ token: BackgroundDownloadCompletionHandlerToken
    ) -> BackgroundDownloadCompletionReleaseBatch {
        BackgroundDownloadCompletionReleaseBatch(identifier: identifier, tokens: [token])
    }
}
