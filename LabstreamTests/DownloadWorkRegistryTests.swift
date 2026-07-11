import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct DownloadWorkRegistryTests {
    @Test func exactCompletionCannotRemoveAnotherTokenOrAttempt() {
        let registry = DownloadWorkRegistry()
        let attemptA = key("plex:item", "attempt-A")
        let attemptB = key("plex:item", "attempt-B")
        let taskA = pendingTask()
        let taskB = pendingTask()
        defer { taskA.cancel(); taskB.cancel() }
        let tokenA = registry.register(taskA, for: attemptA, kind: .finalizer)
        let tokenB = registry.register(taskB, for: attemptB, kind: .finalizer)

        #expect(!registry.complete(key: attemptB, token: tokenA))
        #expect(registry.snapshot().totalCount == 2)
        #expect(registry.complete(key: attemptA, token: tokenA))
        #expect(!registry.complete(key: attemptA, token: tokenA))
        #expect(registry.snapshot().attempts.map(\.key) == [attemptB])
        #expect(registry.complete(key: attemptB, token: tokenB))
        #expect(registry.snapshot().totalCount == 0)
    }

    @Test func cancellationIsExactAttemptScopedAndPreservesRequiredCleanup() {
        let registry = DownloadWorkRegistry()
        let attemptA = key("emby:item", "attempt-A")
        let attemptB = key("emby:item", "attempt-B")
        let finalizer = pendingTask()
        let poster = pendingTask()
        let cleanup = pendingTask()
        let replacement = pendingTask()
        defer {
            finalizer.cancel(); poster.cancel(); cleanup.cancel(); replacement.cancel()
        }
        let finalizerToken = registry.register(finalizer, for: attemptA, kind: .finalizer)
        let posterToken = registry.register(
            poster, for: attemptA, kind: .sideCache(.poster))
        let cleanupToken = registry.register(
            cleanup, for: attemptA, kind: .requiredCleanup)
        let replacementToken = registry.register(
            replacement, for: attemptB, kind: .sideCache(.chapterImages))

        let cancelled = Set(registry.cancelCancellableWork(for: attemptA))
        #expect(cancelled == Set([finalizerToken, posterToken]))
        #expect(finalizer.isCancelled)
        #expect(poster.isCancelled)
        #expect(!cleanup.isCancelled)
        #expect(!replacement.isCancelled)
        let snapshot = registry.snapshot()
        #expect(snapshot.totalCount == 2)
        #expect(snapshot.cancellableCount == 1)
        #expect(snapshot.requiredCleanupCount == 1)
        #expect(snapshot.attempts.map(\.key) == [attemptA, attemptB])

        #expect(registry.complete(key: attemptA, token: cleanupToken))
        #expect(registry.complete(key: attemptB, token: replacementToken))
    }

    @Test func startedWorkCompareRemovesItselfAndCleanupSurvivesAttemptCancel() async {
        let registry = DownloadWorkRegistry()
        let attempt = key("jellyfin:item", "attempt-A")
        let finalizerGate = AsyncWorkGate()
        let cleanupGate = AsyncWorkGate()
        let finalizerToken = registry.start(for: attempt, kind: .finalizer) {
            await finalizerGate.wait()
        }
        let cleanupToken = registry.start(for: attempt, kind: .requiredCleanup) {
            await cleanupGate.wait()
        }
        await finalizerGate.waitUntilEntered()
        await cleanupGate.waitUntilEntered()
        #expect(registry.snapshot().totalCount == 2)

        #expect(registry.cancelCancellableWork(for: attempt) == [finalizerToken])
        let retained = registry.snapshot()
        #expect(retained.totalCount == 1)
        #expect(retained.attempts.first?.entries.first?.token == cleanupToken)
        #expect(retained.requiredCleanupCount == 1)

        await finalizerGate.open()
        await cleanupGate.open()
        await waitUntil { registry.snapshot().totalCount == 0 }
        #expect(registry.snapshot().totalCount == 0)
    }

    @Test func snapshotsHaveDeterministicAttemptAndKindOrdering() {
        let registry = DownloadWorkRegistry()
        let z = key("z:item", "attempt-Z")
        let a2 = key("a:item", "attempt-B")
        let a1 = key("a:item", "attempt-A")
        let tasks = (0..<4).map { _ in pendingTask() }
        defer { tasks.forEach { $0.cancel() } }
        _ = registry.register(tasks[0], for: z, kind: .requiredCleanup)
        _ = registry.register(tasks[1], for: a2, kind: .sideCache(.poster))
        _ = registry.register(tasks[2], for: a1, kind: .sideCache(.chapterImages))
        _ = registry.register(tasks[3], for: a1, kind: .finalizer)

        let snapshot = registry.snapshot()
        #expect(snapshot.attempts.map(\.key) == [a1, a2, z])
        #expect(snapshot.attempts[0].entries.map(\.kind)
                == [.finalizer, .sideCache(.chapterImages)])
    }

    private func key(_ ratingKey: String, _ attempt: String) -> DownloadAttemptKey {
        DownloadAttemptKey(
            ratingKey: ratingKey,
            attemptID: DownloadAttemptID(rawValue: attempt)!)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !predicate() { await Task.yield() }
    }

    private func pendingTask() -> Task<Void, Never> {
        Task { try? await Task.sleep(for: .seconds(3_600)) }
    }
}

private actor AsyncWorkGate {
    private var entered = false
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
