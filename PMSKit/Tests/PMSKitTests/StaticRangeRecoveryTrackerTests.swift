import Testing
@testable import PMSKit

@Suite("Static range recovery tracker")
struct StaticRangeRecoveryTrackerTests {

    @Test("Pending resume keys are gated by manual queue-resume state while queue is paused")
    func pendingResumeKeysRespectQueuePause() {
        var tracker = StaticRangeRecoveryTracker()
        tracker.addPendingResume("a")
        tracker.addPendingResume("b")

        #expect(tracker.resumablePendingKeys(isQueuePaused: false) == ["a", "b"])
        #expect(tracker.resumablePendingKeys(isQueuePaused: true).isEmpty)

        tracker.markManualQueueResume("b")
        #expect(tracker.resumablePendingKeys(isQueuePaused: true) == ["b"])

        tracker.removePendingResume("b")
        #expect(tracker.resumablePendingKeys(isQueuePaused: false) == ["a"])
        #expect(tracker.resumablePendingKeys(isQueuePaused: true).isEmpty)
    }

    @Test("Finalizing and manual queue-resume terminal cleanup is explicit")
    func terminalCleanup() {
        var tracker = StaticRangeRecoveryTracker()
        tracker.markFinalizing("a")
        tracker.markFinalizing("b")
        tracker.markManualQueueResume("b")
        tracker.markManualQueueResume("c")

        tracker.subtractFinalizing(["a", "z"])
        tracker.subtractManualQueueResumes(["c", "z"])

        #expect(!tracker.isFinalizing("a"))
        #expect(tracker.isFinalizing("b"))
        #expect(tracker.wasManuallyResumedWhileQueuePaused("b"))
        #expect(!tracker.wasManuallyResumedWhileQueuePaused("c"))
    }

    @Test("Restart counter preservation is one-shot")
    func restartCounterPreservationIsOneShot() {
        var tracker = StaticRangeRecoveryTracker()
        tracker.preserveRestartCountersForNextStart("row")

        let first = tracker.consumeRestartCounterPreservation("row")
        let second = tracker.consumeRestartCounterPreservation("row")
        let other = tracker.consumeRestartCounterPreservation("other")

        #expect(first)
        #expect(!second)
        #expect(!other)
    }
}
