import PMSKit
import Testing
@testable import Labstream

@Suite("Background download completion registry")
@MainActor
struct BackgroundDownloadCompletionRegistryTests {
    @Test("Every handler claimed by one finish cycle fires once")
    func everyClaimedHandlerFiresOnce() {
        let registry = BackgroundDownloadCompletionRegistry()
        var calls: [Int] = []

        let first = registry.store(identifier: "session") { calls.append(1) }
        let second = registry.store(identifier: "session") { calls.append(2) }
        let third = registry.store(identifier: "session") { calls.append(3) }
        let batch = BackgroundDownloadCompletionReleaseBatch(
            identifier: "session",
            tokens: [first, second, third]
        )

        registry.fireCompletions(in: batch)
        registry.fireCompletions(in: batch)

        #expect(calls == [1, 2, 3])
        #expect(!registry.hasPendingHandler(identifier: "session"))
    }

    @Test("Identifiers release independently")
    func identifiersReleaseIndependently() {
        let registry = BackgroundDownloadCompletionRegistry()
        var calls: [String] = []
        let tokenA = registry.store(identifier: "session-a") { calls.append("a") }
        let tokenB = registry.store(identifier: "session-b") { calls.append("b") }

        registry.fireCompletions(in: .init(identifier: "session-a", tokens: [tokenA]))

        #expect(calls == ["a"])
        #expect(!registry.hasPendingHandler(identifier: "session-a"))
        #expect(registry.hasPendingHandler(identifier: "session-b"))

        registry.fireCompletions(in: .init(identifier: "session-b", tokens: [tokenB]))
        #expect(calls == ["a", "b"])
    }

    @Test("A handler supplied during release waits for the next finish event")
    func reentrantHandlerWaitsForNextRelease() {
        let registry = BackgroundDownloadCompletionRegistry()
        var calls: [Int] = []
        var nextToken: BackgroundDownloadCompletionHandlerToken?
        let firstToken = registry.store(identifier: "session") {
            calls.append(1)
            nextToken = registry.store(identifier: "session") { calls.append(2) }
        }

        registry.fireCompletions(in: .init(identifier: "session", tokens: [firstToken]))
        #expect(calls == [1])
        #expect(registry.hasPendingHandler(identifier: "session"))

        guard let nextToken else {
            Issue.record("Reentrant store did not supply a next-cycle token")
            return
        }
        registry.fireCompletions(in: .init(
            identifier: "session",
            tokens: [nextToken]
        ))
        #expect(calls == [1, 2])
        #expect(!registry.hasPendingHandler(identifier: "session"))
    }

    @Test("Delayed persistence release cannot sweep a new same-identifier cycle")
    func delayedPersistenceReleaseCannotSweepNewCycle() async {
        let registry = BackgroundDownloadCompletionRegistry()
        var calls: [Int] = []
        let oldToken = registry.store(identifier: "session") { calls.append(1) }
        let oldBatch = BackgroundDownloadCompletionReleaseBatch(
            identifier: "session",
            tokens: [oldToken]
        )
        let flush = AsyncReleaseGate()

        let delayedRelease = Task {
            await BackgroundCompletionPersistenceBarrier.flushThenRelease(
                releases: [oldBatch],
                flush: {
                    await flush.wait()
                    return .committed(revision: 1)
                },
                release: { registry.fireCompletions(in: $0) }
            )
        }
        await flush.waitUntilSuspended()

        let newToken = registry.store(identifier: "session") { calls.append(2) }
        await flush.resume()
        _ = await delayedRelease.value

        #expect(calls == [1])
        #expect(registry.hasPendingHandler(identifier: "session"))

        registry.fireCompletions(in: .init(identifier: "session", tokens: [newToken]))
        #expect(calls == [1, 2])
        #expect(!registry.hasPendingHandler(identifier: "session"))
    }
}

private actor AsyncReleaseGate {
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var isSuspended = false

    func wait() async {
        isSuspended = true
        suspensionContinuation?.resume()
        suspensionContinuation = nil
        await withCheckedContinuation { waitContinuation = $0 }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { suspensionContinuation = $0 }
    }

    func resume() {
        waitContinuation?.resume()
        waitContinuation = nil
    }
}
