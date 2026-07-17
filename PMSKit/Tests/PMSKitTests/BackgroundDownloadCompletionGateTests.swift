import Testing
@testable import PMSKit

@Suite("Background download completion gate")
struct BackgroundDownloadCompletionGateTests {

    @Test("Completion fires immediately when no durable work is pending")
    func firesImmediatelyWhenNoWorkIsPending() {
        var gate = BackgroundDownloadCompletionGate()
        gate.storeHandler(identifier: "com.example.downloads")

        #expect(gate.hasPendingHandler)
        #expect(gate.finishEvents(identifier: "com.example.downloads") == ["com.example.downloads"])
        #expect(!gate.hasPendingHandler)
        #expect(gate.pendingOperationCount == 0)
        #expect(gate.awaitingFinishIdentifierCount == 0)
        #expect(gate.deferredIdentifierCount == 0)
    }

    @Test("Completion is deferred until all pending durable operations drain")
    func defersUntilPendingWorkDrains() {
        var gate = BackgroundDownloadCompletionGate()
        gate.storeHandler(identifier: "session-a")
        gate.beginOperation()
        gate.beginOperation()

        #expect(gate.finishEvents(identifier: "session-a").isEmpty)
        #expect(gate.hasPendingHandler)
        #expect(gate.deferredIdentifierCount == 1)

        #expect(gate.endOperation().isEmpty)
        #expect(gate.pendingOperationCount == 1)
        #expect(gate.endOperation() == ["session-a"])
        #expect(!gate.hasPendingHandler)
    }

    @Test("Multiple deferred identifiers fire together in deterministic order")
    func multipleDeferredIdentifiersFireTogether() {
        var gate = BackgroundDownloadCompletionGate()
        gate.beginOperation()
        gate.storeHandler(identifier: "session-b")
        gate.storeHandler(identifier: "session-a")

        #expect(gate.finishEvents(identifier: "session-b").isEmpty)
        #expect(gate.finishEvents(identifier: "session-a").isEmpty)
        #expect(gate.deferredIdentifierCount == 2)

        #expect(gate.endOperation() == ["session-a", "session-b"])
        #expect(gate.deferredIdentifierCount == 0)
    }

    @Test("Extra end calls clamp at zero and do not replay completions")
    func extraEndCallsClampAtZero() {
        var gate = BackgroundDownloadCompletionGate()
        gate.beginOperation()
        gate.storeHandler(identifier: "session")
        #expect(gate.finishEvents(identifier: "session").isEmpty)

        #expect(gate.endOperation() == ["session"])
        #expect(gate.endOperation().isEmpty)
        #expect(gate.pendingOperationCount == 0)
    }

    @Test("Finish without a stored handler never manufactures a completion")
    func finishWithoutStoreIsIgnored() {
        var gate = BackgroundDownloadCompletionGate()
        #expect(gate.finishEvents(identifier: "session").isEmpty)
        #expect(!gate.hasPendingHandler)
    }

    @Test("Duplicate finish cannot replay into a later handler generation")
    func duplicateFinishDoesNotReplay() {
        var gate = BackgroundDownloadCompletionGate()
        gate.storeHandler(identifier: "session")
        #expect(gate.finishEvents(identifier: "session") == ["session"])
        #expect(gate.finishEvents(identifier: "session").isEmpty)

        gate.storeHandler(identifier: "session")
        #expect(gate.hasPendingHandler)
        #expect(gate.finishEvents(identifier: "session") == ["session"])
        #expect(!gate.hasPendingHandler)
    }

    @Test("Observable startup failure aborts stored and deferred handlers exactly once")
    func startupFailureAbort() {
        var gate = BackgroundDownloadCompletionGate()
        gate.storeHandler(identifier: "waiting")
        gate.storeHandler(identifier: "deferred")
        gate.beginOperation()
        #expect(gate.finishEvents(identifier: "deferred").isEmpty)

        #expect(gate.abortAwaitingHandlers() == ["deferred", "waiting"])
        #expect(!gate.hasPendingHandler)
        #expect(gate.pendingOperationCount == 0)
        #expect(gate.abortAwaitingHandlers().isEmpty)
        #expect(gate.finishEvents(identifier: "waiting").isEmpty)
    }
}
