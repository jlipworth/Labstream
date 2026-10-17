import Foundation
import Testing
@testable import PMSKit

// B02: reattach (including the scene-active foreground reattach) must not re-adopt a task whose
// pause or cancel is still in flight, and must not resurrect a paused row.
@Suite("Background reattach task gate")
struct BackgroundReattachTaskGatePolicyTests {
    @Test("A superseded, halted, or canceling task is left alone")
    func inFlightPauseOrCancelIsLeftAlone() {
        #expect(BackgroundReattachTaskGatePolicy.disposition(
            isSuperseded: true, isCanceling: false, isAttemptHalted: false,
            rowStatus: .downloading) == .leaveAlone)
        #expect(BackgroundReattachTaskGatePolicy.disposition(
            isSuperseded: false, isCanceling: true, isAttemptHalted: false,
            rowStatus: .downloading) == .leaveAlone)
        #expect(BackgroundReattachTaskGatePolicy.disposition(
            isSuperseded: false, isCanceling: false, isAttemptHalted: true,
            rowStatus: .paused) == .leaveAlone)
    }

    @Test("A live task for a paused row is cancelled, never adopted or rebuilt")
    func pausedRowTaskIsCancelled() {
        #expect(BackgroundReattachTaskGatePolicy.disposition(
            isSuperseded: false, isCanceling: false, isAttemptHalted: false,
            rowStatus: .paused) == .cancelForPausedRow)
    }

    @Test("Active rows and unknown rows keep the existing classification")
    func activeRowsClassify() {
        for status in [DownloadStatus.queued, .downloading] {
            #expect(BackgroundReattachTaskGatePolicy.disposition(
                isSuperseded: false, isCanceling: false, isAttemptHalted: false,
                rowStatus: status) == .classify)
        }
        #expect(BackgroundReattachTaskGatePolicy.disposition(
            isSuperseded: false, isCanceling: false, isAttemptHalted: false,
            rowStatus: nil) == .classify)
    }

    @Test("Adoption and rebuild may write active status only for an unhalted, unpaused row")
    func activeStatusWriteGate() {
        #expect(BackgroundReattachTaskGatePolicy.mayWriteActiveStatus(
            currentStatus: .queued, isAttemptHalted: false))
        #expect(!BackgroundReattachTaskGatePolicy.mayWriteActiveStatus(
            currentStatus: .paused, isAttemptHalted: false))
        #expect(!BackgroundReattachTaskGatePolicy.mayWriteActiveStatus(
            currentStatus: .downloading, isAttemptHalted: true))
        #expect(!BackgroundReattachTaskGatePolicy.mayWriteActiveStatus(
            currentStatus: nil, isAttemptHalted: false))
    }
}
