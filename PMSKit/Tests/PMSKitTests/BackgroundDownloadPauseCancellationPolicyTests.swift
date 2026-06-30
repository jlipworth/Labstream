import Testing
@testable import PMSKit

@Suite("Background download pause/cancellation policy")
struct BackgroundDownloadPauseCancellationPolicyTests {

    @Test("Delayed pause callbacks apply only to active rows without replacement tasks")
    func pauseStillApplies() {
        #expect(BackgroundDownloadPauseCancellationPolicy.pauseStillApplies(
            status: .queued,
            hasReplacementTask: false
        ))
        #expect(BackgroundDownloadPauseCancellationPolicy.pauseStillApplies(
            status: .downloading,
            hasReplacementTask: false
        ))
        #expect(!BackgroundDownloadPauseCancellationPolicy.pauseStillApplies(
            status: .downloading,
            hasReplacementTask: true
        ))
        #expect(!BackgroundDownloadPauseCancellationPolicy.pauseStillApplies(
            status: .paused,
            hasReplacementTask: false
        ))
        #expect(!BackgroundDownloadPauseCancellationPolicy.pauseStillApplies(
            status: .failed,
            hasReplacementTask: false
        ))
        #expect(!BackgroundDownloadPauseCancellationPolicy.pauseStillApplies(
            status: nil,
            hasReplacementTask: false
        ))
    }

    @Test("Range start failures are suppressed for halted rows or cancellation")
    func suppressRangeStartFailures() {
        #expect(BackgroundDownloadPauseCancellationPolicy.shouldSuppressRangeStartFailure(
            isHalted: true,
            isCancellation: false
        ))
        #expect(BackgroundDownloadPauseCancellationPolicy.shouldSuppressRangeStartFailure(
            isHalted: false,
            isCancellation: true
        ))
        #expect(BackgroundDownloadPauseCancellationPolicy.shouldSuppressRangeStartFailure(
            isHalted: true,
            isCancellation: true
        ))
        #expect(!BackgroundDownloadPauseCancellationPolicy.shouldSuppressRangeStartFailure(
            isHalted: false,
            isCancellation: false
        ))
    }
}
