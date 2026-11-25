import Foundation
import Testing
@testable import PMSKit

@Suite("Aggregate download speed after sleep")
struct DownloadAggregateRateEstimatorTests {
    private let a = DownloadAttemptKey(ratingKey: "a", attemptID: .init(rawValue: "attempt-a")!)
    private let b = DownloadAttemptKey(ratingKey: "b", attemptID: .init(rawValue: "attempt-b")!)

    private func time(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    @Test("staggered post-wake callbacks cannot publish a partial batch total")
    func staggeredWake() {
        var estimator = DownloadAggregateRateEstimator()
        estimator.setActiveTransfers([a, b], at: time(0))
        estimator.sample(a, bytes: 0, at: time(0))
        estimator.sample(b, bytes: 0, at: time(0))
        estimator.sample(a, bytes: 400, at: time(4))
        estimator.sample(b, bytes: 800, at: time(4))
        #expect(estimator.rate(at: time(4)) == 300)

        estimator.resetAfterWake(at: time(100))
        estimator.sample(a, bytes: 1_000_000, at: time(100))
        estimator.sample(a, bytes: 1_000_400, at: time(104))
        #expect(estimator.rate(at: time(104)) == nil)
        estimator.sample(b, bytes: 8_000_000, at: time(104))
        for second in 105...108 {
            estimator.sample(a, bytes: 1_000_000 + (second - 100) * 100, at: time(Double(second)))
        }
        #expect(estimator.rate(at: time(108)) == nil)
        estimator.sample(b, bytes: 8_000_800, at: time(108))
        #expect(estimator.rate(at: time(108)) == 300)
    }

    @Test("every item uses the same start and end despite different callback times")
    func sharedWindow() {
        var estimator = DownloadAggregateRateEstimator(settlingDuration: 0)
        estimator.setActiveTransfers([a, b], at: time(0))
        estimator.sample(a, bytes: 0, at: time(0))
        estimator.sample(a, bytes: 100, at: time(1))
        estimator.sample(a, bytes: 500, at: time(3))
        estimator.sample(b, bytes: 0, at: time(1))
        estimator.sample(b, bytes: 300, at: time(2))
        // Common interval [1, 2]: a contributes 200/s, b 300/s. Independent windows
        // would incorrectly sum a's 500/3 with b's 300/1.
        #expect(estimator.rate(at: time(3)) == 500)
    }

    @Test("a long callback gap rebaselines the batch without a lifecycle hint")
    func implicitWake() {
        var estimator = DownloadAggregateRateEstimator()
        estimator.setActiveTransfers([a, b], at: time(0))
        estimator.sample(a, bytes: 0, at: time(0))
        estimator.sample(b, bytes: 0, at: time(0))
        estimator.sample(a, bytes: 400, at: time(4))
        estimator.sample(b, bytes: 800, at: time(4))
        #expect(estimator.rate(at: time(4)) == 300)
        #expect(estimator.rate(at: time(100)) == nil)
        estimator.sample(a, bytes: 9_000_000, at: time(100))
        estimator.sample(b, bytes: 9_000_000, at: time(101))
        estimator.sample(a, bytes: 9_000_500, at: time(105))
        #expect(estimator.rate(at: time(105)) == nil)
        estimator.sample(b, bytes: 9_000_800, at: time(105))
        #expect(estimator.rate(at: time(105)) == 300)
    }

    @Test("late first callbacks and buffered catch-up bytes preserve the #224 guard")
    func catchUpGuard() {
        var estimator = DownloadAggregateRateEstimator()
        estimator.setActiveTransfers([a], at: time(0))
        estimator.resetAfterWake(at: time(0))
        estimator.sample(a, bytes: 100_000_000, at: time(15))
        estimator.sample(a, bytes: 500_000_000, at: time(18))
        #expect(estimator.rate(at: time(18)) == nil)
        estimator.sample(a, bytes: 510_000_000, at: time(19))
        #expect(estimator.rate(at: time(19)) == 10_000_000)
    }

    @Test("a single transfer warms up, measures and expires normally")
    func singleTransfer() {
        var estimator = DownloadAggregateRateEstimator()
        estimator.setActiveTransfers([a], at: time(0))
        estimator.sample(a, bytes: 100, at: time(0))
        #expect(estimator.rate(at: time(0)) == nil)
        estimator.sample(a, bytes: 500, at: time(4))
        #expect(estimator.rate(at: time(4)) == 100)
        #expect(estimator.rate(at: time(10)) == nil)
    }

    @Test("observed quiet callbacks decay to zero without dropping a stalled member")
    func realStall() {
        var estimator = DownloadAggregateRateEstimator(settlingDuration: 0)
        estimator.setActiveTransfers([a, b], at: time(0))
        for second in 0...8 {
            estimator.sample(a, bytes: second * 100, at: time(Double(second)))
            estimator.sample(b, bytes: min(second, 2) * 200, at: time(Double(second)))
        }
        #expect(estimator.rate(at: time(8)) == 100)
        for second in 9...12 {
            estimator.sample(a, bytes: 800, at: time(Double(second)))
            estimator.sample(b, bytes: 400, at: time(Double(second)))
        }
        #expect(estimator.rate(at: time(12)) == 0)
    }

    @Test("a silent member hides the batch until callbackGap, then counts as zero (#379, #487)")
    func silentMember() {
        var estimator = DownloadAggregateRateEstimator(settlingDuration: 0)
        estimator.setActiveTransfers([a, b], at: time(0))
        estimator.sample(b, bytes: 0, at: time(0))
        estimator.sample(b, bytes: 200, at: time(1))
        for second in 0...6 {
            estimator.sample(a, bytes: second * 100, at: time(Double(second)))
        }
        // Silent for 5 s: it may be about to deliver catch-up bytes, so the total stays hidden.
        #expect(estimator.rate(at: time(6)) == nil)
        // Silent for callbackGap in a process that kept observing: it counts as zero (#487).
        for second in 7...8 {
            estimator.sample(a, bytes: second * 100, at: time(Double(second)))
            #expect(estimator.rate(at: time(Double(second))) == 100)
        }
        // Its delayed watermark is catch-up evidence, not an instantaneous burst: the batch resets.
        estimator.sample(b, bytes: 9_000_000, at: time(8))
        #expect(estimator.rate(at: time(8)) == nil)
    }

    @Test("a member that never reports counts as zero callbackGap after the batch's reset (#487)")
    func neverReportingMember() {
        var estimator = DownloadAggregateRateEstimator()
        estimator.setActiveTransfers([a, b], at: time(0))
        for second in 0...20 {
            estimator.sample(a, bytes: second * 1_000, at: time(Double(second)))
        }
        #expect(estimator.rate(at: time(5)) == nil)
        #expect(estimator.rate(at: time(20)) == 1_000)
        // A wake restarts the silence clock: pre-sleep silence never becomes a zero at once.
        estimator.resetAfterWake(at: time(100))
        for second in 100...105 {
            estimator.sample(a, bytes: 1_000_000 + second * 1_000, at: time(Double(second)))
        }
        #expect(estimator.rate(at: time(105)) == nil)
        for second in 106...110 {
            estimator.sample(a, bytes: 1_000_000 + second * 1_000, at: time(Double(second)))
        }
        #expect(estimator.rate(at: time(110)) == 1_000)
        // Its first report, however late, is a new baseline for the whole batch.
        estimator.sample(b, bytes: 50_000_000, at: time(110))
        #expect(estimator.rate(at: time(110)) == nil)
    }

    @Test("a batch whose every member is silent has no answer (#487)")
    func allSilent() {
        var estimator = DownloadAggregateRateEstimator(settlingDuration: 0)
        estimator.setActiveTransfers([a, b], at: time(0))
        #expect(estimator.rate(at: time(30)) == nil)
        estimator.sample(a, bytes: 0, at: time(30))
        estimator.sample(a, bytes: 400, at: time(34))
        estimator.sample(b, bytes: 0, at: time(30))
        estimator.sample(b, bytes: 800, at: time(34))
        #expect(estimator.rate(at: time(34)) == 300)
        #expect(estimator.rate(at: time(40)) == nil)
    }

    @Test("membership changes and backwards checkpoints cannot retain a stale batch rate")
    func membershipAndRebaseline() {
        var estimator = DownloadAggregateRateEstimator(settlingDuration: 0)
        estimator.setActiveTransfers([a, b], at: time(0))
        estimator.sample(a, bytes: 0, at: time(0))
        estimator.sample(b, bytes: 0, at: time(0))
        estimator.sample(a, bytes: 100, at: time(1))
        estimator.sample(b, bytes: 200, at: time(1))
        estimator.setActiveTransfers([a], at: time(1))
        #expect(estimator.rate(at: time(1)) == 100)
        estimator.sample(a, bytes: 10, at: time(2))
        #expect(estimator.rate(at: time(2)) == nil)
        estimator.sample(a, bytes: 110, at: time(3))
        #expect(estimator.rate(at: time(3)) == 100)
        let replacement = DownloadAttemptKey(ratingKey: "a", attemptID: .init(rawValue: "replacement")!)
        estimator.setActiveTransfers([replacement], at: time(4))
        estimator.sample(a, bytes: 999, at: time(4))
        #expect(estimator.rate(at: time(4)) == nil)
        estimator.setActiveTransfers([], at: time(4))
        #expect(estimator.rate(at: time(4)) == nil)
    }
}
