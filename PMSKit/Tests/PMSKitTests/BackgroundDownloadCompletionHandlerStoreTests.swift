import Testing
@testable import PMSKit

@Suite("Background download completion handler store")
struct BackgroundDownloadCompletionHandlerStoreTests {
    @Test("Same-identifier batch drains in supply order")
    func sameIdentifierBatchDrainsInSupplyOrder() {
        var store = BackgroundDownloadCompletionHandlerStore()
        var calls: [Int] = []

        let first = store.append(identifier: "session") { calls.append(1) }
        let second = store.append(identifier: "session") { calls.append(2) }
        let third = store.append(identifier: "session") { calls.append(3) }
        let batch = BackgroundDownloadCompletionReleaseBatch(
            identifier: "session",
            tokens: [first, second, third]
        )

        let handlers = store.drain(batch: batch)
        #expect(handlers.count == 3)
        for handler in handlers { handler() }

        #expect(calls == [1, 2, 3])
        #expect(!store.hasHandlers(for: "session"))
        #expect(store.totalCount == 0)
    }

    @Test("A token is transferred by exactly one drain")
    func tokenIsTransferredExactlyOnce() {
        var store = BackgroundDownloadCompletionHandlerStore()
        var callCount = 0
        let token = store.append(identifier: "session") { callCount += 1 }
        let batch = BackgroundDownloadCompletionReleaseBatch(
            identifier: "session",
            tokens: [token]
        )

        for handler in store.drain(batch: batch) { handler() }
        for handler in store.drain(batch: batch) { handler() }

        #expect(callCount == 1)
        #expect(store.count(for: "session") == 0)
    }

    @Test("Draining one identifier does not consume sibling handlers")
    func identifiersAreIsolated() {
        var store = BackgroundDownloadCompletionHandlerStore()
        var calls: [String] = []
        let tokenA = store.append(identifier: "session-a") { calls.append("a") }
        _ = store.append(identifier: "session-b") { calls.append("b") }

        let batchA = BackgroundDownloadCompletionReleaseBatch(
            identifier: "session-a",
            tokens: [tokenA]
        )
        for handler in store.drain(batch: batchA) { handler() }

        #expect(calls == ["a"])
        #expect(store.count(for: "session-a") == 0)
        #expect(store.count(for: "session-b") == 1)
        #expect(store.totalCount == 1)
    }

    @Test("Delayed old-cycle release cannot sweep a new same-identifier handler")
    func delayedReleaseDoesNotSweepNewCycle() {
        var store = BackgroundDownloadCompletionHandlerStore()
        var calls: [Int] = []
        let oldToken = store.append(identifier: "session") { calls.append(1) }
        let oldBatch = BackgroundDownloadCompletionReleaseBatch(
            identifier: "session",
            tokens: [oldToken]
        )

        // Models a new app-delegate callback arriving while the old batch awaits persistence.
        let newToken = store.append(identifier: "session") { calls.append(2) }
        for handler in store.drain(batch: oldBatch) { handler() }

        #expect(calls == [1])
        #expect(store.pendingTokens(for: "session") == [newToken])

        let newBatch = BackgroundDownloadCompletionReleaseBatch(
            identifier: "session",
            tokens: [newToken]
        )
        for handler in store.drain(batch: newBatch) { handler() }
        #expect(calls == [1, 2])
        #expect(store.totalCount == 0)
    }
}
