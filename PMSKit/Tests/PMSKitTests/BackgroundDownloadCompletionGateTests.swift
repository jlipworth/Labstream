import Testing
@testable import PMSKit

@Suite("Background download completion gate")
struct BackgroundDownloadCompletionGateTests {
    @Test("Completion batch fires immediately when no durable work is pending")
    func firesImmediatelyWhenNoWorkIsPending() {
        var gate = BackgroundDownloadCompletionGate()
        let token = BackgroundDownloadCompletionHandlerToken()
        gate.storeHandler(identifier: "com.example.downloads", token: token)

        #expect(gate.finishEvents(identifier: "com.example.downloads") == [
            .init(identifier: "com.example.downloads", tokens: [token])
        ])
        #expect(!gate.hasPendingHandler)
        #expect(gate.awaitingFinishHandlerCount == 0)
    }

    @Test("Completion is deferred until all pending durable operations drain")
    func defersUntilPendingWorkDrains() {
        var gate = BackgroundDownloadCompletionGate()
        let token = BackgroundDownloadCompletionHandlerToken()
        gate.storeHandler(identifier: "session-a", token: token)
        gate.beginOperation()
        gate.beginOperation()

        #expect(gate.finishEvents(identifier: "session-a").isEmpty)
        #expect(gate.hasPendingHandler)
        #expect(gate.deferredIdentifierCount == 1)

        #expect(gate.endOperation().isEmpty)
        #expect(gate.endOperation() == [
            .init(identifier: "session-a", tokens: [token])
        ])
        #expect(!gate.hasPendingHandler)
    }

    @Test("Multiple deferred batches retain finish-event order")
    func multipleDeferredBatchesRetainOrder() {
        var gate = BackgroundDownloadCompletionGate()
        let tokenB = BackgroundDownloadCompletionHandlerToken()
        let tokenA = BackgroundDownloadCompletionHandlerToken()
        gate.beginOperation()
        gate.storeHandler(identifier: "session-b", token: tokenB)
        gate.storeHandler(identifier: "session-a", token: tokenA)

        #expect(gate.finishEvents(identifier: "session-b").isEmpty)
        #expect(gate.finishEvents(identifier: "session-a").isEmpty)

        #expect(gate.endOperation() == [
            .init(identifier: "session-b", tokens: [tokenB]),
            .init(identifier: "session-a", tokens: [tokenA]),
        ])
    }

    @Test("Same-identifier handlers present at finish form one exact ordered batch")
    func sameIdentifierHandlersFormOneBatch() {
        var gate = BackgroundDownloadCompletionGate()
        let first = BackgroundDownloadCompletionHandlerToken()
        let second = BackgroundDownloadCompletionHandlerToken()
        gate.storeHandler(identifier: "session", token: first)
        gate.storeHandler(identifier: "session", token: second)

        #expect(gate.awaitingFinishIdentifierCount == 1)
        #expect(gate.awaitingFinishHandlerCount == 2)
        #expect(gate.finishEvents(identifier: "session") == [
            .init(identifier: "session", tokens: [first, second])
        ])
    }

    @Test("A new same-identifier handler after finish belongs to the next cycle")
    func newHandlerAfterFinishBelongsToNextCycle() {
        var gate = BackgroundDownloadCompletionGate()
        let old = BackgroundDownloadCompletionHandlerToken()
        let new = BackgroundDownloadCompletionHandlerToken()
        gate.beginOperation()
        gate.storeHandler(identifier: "session", token: old)
        #expect(gate.finishEvents(identifier: "session").isEmpty)

        gate.storeHandler(identifier: "session", token: new)
        #expect(gate.pendingHandlerCount == 2)
        #expect(gate.endOperation() == [
            .init(identifier: "session", tokens: [old])
        ])
        #expect(gate.hasPendingHandler)
        #expect(gate.pendingHandlerCount == 1)
        #expect(gate.finishEvents(identifier: "session") == [
            .init(identifier: "session", tokens: [new])
        ])
        #expect(!gate.hasPendingHandler)
    }

    @Test("Extra end calls clamp at zero and do not replay batches")
    func extraEndCallsClampAtZero() {
        var gate = BackgroundDownloadCompletionGate()
        let token = BackgroundDownloadCompletionHandlerToken()
        gate.beginOperation()
        gate.storeHandler(identifier: "session", token: token)
        #expect(gate.finishEvents(identifier: "session").isEmpty)

        #expect(gate.endOperation() == [.init(identifier: "session", tokens: [token])])
        #expect(gate.endOperation().isEmpty)
        #expect(gate.pendingOperationCount == 0)
    }

    @Test("Finish without a stored handler never manufactures a batch")
    func finishWithoutStoreIsIgnored() {
        var gate = BackgroundDownloadCompletionGate()
        #expect(gate.finishEvents(identifier: "session").isEmpty)
        #expect(!gate.hasPendingHandler)
    }

    @Test("Duplicate token registration does not duplicate release")
    func duplicateTokenRegistrationDoesNotDuplicateRelease() {
        var gate = BackgroundDownloadCompletionGate()
        let token = BackgroundDownloadCompletionHandlerToken()
        gate.storeHandler(identifier: "session", token: token)
        gate.storeHandler(identifier: "session", token: token)

        #expect(gate.finishEvents(identifier: "session") == [
            .init(identifier: "session", tokens: [token])
        ])
        #expect(gate.finishEvents(identifier: "session").isEmpty)
    }

    @Test("Observable startup failure aborts stored and deferred batches exactly once")
    func startupFailureAbort() {
        var gate = BackgroundDownloadCompletionGate()
        let waiting = BackgroundDownloadCompletionHandlerToken()
        let deferred = BackgroundDownloadCompletionHandlerToken()
        gate.storeHandler(identifier: "waiting", token: waiting)
        gate.storeHandler(identifier: "deferred", token: deferred)
        gate.beginOperation()
        #expect(gate.finishEvents(identifier: "deferred").isEmpty)

        #expect(gate.abortAwaitingHandlers() == [
            .init(identifier: "deferred", tokens: [deferred]),
            .init(identifier: "waiting", tokens: [waiting]),
        ])
        #expect(!gate.hasPendingHandler)
        #expect(gate.pendingOperationCount == 0)
        #expect(gate.abortAwaitingHandlers().isEmpty)
    }
}
