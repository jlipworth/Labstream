import Foundation
import Testing
@testable import PMSKit

/// Pins the pure download speed/ETA derivation (#123). These are the automated proof for the four
/// field bugs the old ad-hoc EMA in `DownloadManager.refreshRecords` had — slow first readout,
/// stale-on-stall, garbage rate on a backwards/resumed byte count, and an upward bias vs.
/// Σbytes/elapsed. (Actual on-the-wire accuracy is a live/device check that needs a real download;
/// these tests pin the math.)
@Suite("Download rate estimator")
struct DownloadRateEstimatorTests {

    /// t0 + `seconds` as a `Date`, so each test drives a synthetic clock (the estimator never calls
    /// `Date()` itself).
    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private static func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - First-emit latency (Symptom 2)

    @Test("first sample is baseline-only and emits no rate")
    func firstSampleBaselineOnly() {
        var est = DownloadRateEstimator()
        #expect(est.sample(bytes: 0, at: Self.t(0)) == nil)
    }

    @Test("a provisional rate appears at the shortened first-emit window, not the ≥1s gate")
    func provisionalEmitAtFirstWindow() throws {
        var est = DownloadRateEstimator(firstEmitWindow: 0.5)
        #expect(est.sample(bytes: 0, at: Self.t(0)) == nil)
        // A sub-1s window (0.5s) already publishes — the old code waited for ≥1s.
        let emitted = est.sample(bytes: 1_000_000, at: Self.t(0.5))
        let rate = try #require(emitted)
        #expect(rate == 2_000_000)   // 1 MB over 0.5s = 2 MB/s
    }

    @Test("no rate until the window spans the first-emit threshold")
    func noEmitBeforeFirstWindow() {
        var est = DownloadRateEstimator(firstEmitWindow: 0.5)
        #expect(est.sample(bytes: 0, at: Self.t(0)) == nil)
        // Only 0.2s of span — still below the 0.5s first-emit window.
        #expect(est.sample(bytes: 500_000, at: Self.t(0.2)) == nil)
    }

    // MARK: - Stall decay (Symptom 1)

    @Test("a stalled row decays toward 0 and then drops to nil rather than holding a stale rate")
    func stallDecaysThenSuppresses() {
        var est = DownloadRateEstimator(windowDuration: 4.0, firstEmitWindow: 0.5, stallTimeout: 6.0)
        // Ramp up a healthy ~10 MB/s rate.
        _ = est.sample(bytes: 0, at: Self.t(0))
        _ = est.sample(bytes: 10_000_000, at: Self.t(1))
        let hot = est.sample(bytes: 20_000_000, at: Self.t(2))
        #expect((hot ?? 0) > 5_000_000)

        // Now bytes wedge at 20 MB. As quiet ticks accrue, the windowed average falls...
        let decaying = est.sample(bytes: 20_000_000, at: Self.t(4)) ?? .infinity
        #expect(decaying < (hot ?? 0))   // decayed, not held

        // ...and once nothing has moved for ≥ stallTimeout (6s past the last forward tick at t=2),
        // the rate is suppressed entirely.
        #expect(est.sample(bytes: 20_000_000, at: Self.t(8)) == nil)
    }

    @Test("a transfer that never moves a byte times out from when watching began")
    func neverMovesStallsFromStart() {
        var est = DownloadRateEstimator(firstEmitWindow: 0.5, stallTimeout: 6.0)
        _ = est.sample(bytes: 1_000, at: Self.t(0))
        _ = est.sample(bytes: 1_000, at: Self.t(3))
        #expect(est.sample(bytes: 1_000, at: Self.t(6)) == nil)
    }

    // MARK: - Resume / non-monotonic bytes (HYPOTHESIS: 200-restart)

    @Test("a backwards byte count re-baselines and never emits a negative/garbage rate")
    func backwardsBytesReBaseline() {
        var est = DownloadRateEstimator(firstEmitWindow: 0.5)
        _ = est.sample(bytes: 0, at: Self.t(0))
        _ = est.sample(bytes: 50_000_000, at: Self.t(1))
        // 200 full-restart: the new task's cumulative bytes drop back to 0.
        #expect(est.sample(bytes: 0, at: Self.t(2)) == nil)   // re-baselined, no negative rate
        // The subsequent forward window is computed against the NEW baseline, not the stale 50 MB.
        let rate = est.sample(bytes: 5_000_000, at: Self.t(3)) ?? -1
        #expect(rate > 0)
        #expect(rate == 5_000_000)   // 5 MB over the 1s since the re-baseline at t=2
    }

    // MARK: - Reconciliation with Σdb / Σdt (Symptom 1, upward-bias fix)

    @Test("on a bursty trace the reported rate reconciles with Σdb/Σdt over the window")
    func reconcilesWithWindowAverage() throws {
        // Window of 10s so the whole bursty trace is in scope. Bursts then quiet ticks — the old EMA
        // skipped the quiet windows and read high; the windowed average must track true Σdb/Σdt.
        var est = DownloadRateEstimator(windowDuration: 10.0, firstEmitWindow: 0.5)
        let trace: [(Int, TimeInterval)] = [
            (0, 0),
            (8_000_000, 1),    // 8 MB burst
            (8_000_000, 2),    // quiet
            (8_000_000, 3),    // quiet
            (16_000_000, 4),   // 8 MB burst
            (16_000_000, 5),   // quiet
        ]
        var last: Double?
        for (b, s) in trace { last = est.sample(bytes: b, at: Self.t(s)) }
        // Σdb = 16 MB over Σdt = 5s ⇒ 3.2 MB/s true average. The EMA-of-bursts-only would read ~8 MB/s.
        let reported = try #require(last)
        let expected = 16_000_000.0 / 5.0
        #expect(abs(reported - expected) / expected < 0.05)   // within 5% of the true window average
    }

    // MARK: - ETA

    @Test("eta uses remaining/rate when an expected total is known")
    func etaFromExpectedTotal() throws {
        var est = DownloadRateEstimator(firstEmitWindow: 0.5)
        _ = est.sample(bytes: 0, at: Self.t(0))
        _ = est.sample(bytes: 10_000_000, at: Self.t(1))   // 10 MB/s
        // 100 MB total, 10 MB done ⇒ 90 MB remaining at 10 MB/s ⇒ ~9s.
        let eta = try #require(est.eta(expectedTotal: 100_000_000))
        #expect(abs(eta - 9.0) < 0.001)
    }

    @Test("eta is nil without an expected total and once the transfer is complete")
    func etaNilWhenUnknownOrComplete() {
        var est = DownloadRateEstimator(firstEmitWindow: 0.5)
        _ = est.sample(bytes: 0, at: Self.t(0))
        _ = est.sample(bytes: 10_000_000, at: Self.t(1))
        #expect(est.eta(expectedTotal: nil) == nil)            // no expected total
        #expect(est.eta(expectedTotal: 10_000_000) == nil)     // remaining ≤ 0
    }

    @Test("eta is suppressed when it exceeds the 12h trust band")
    func etaSuppressedBeyondTrustBand() {
        var est = DownloadRateEstimator(firstEmitWindow: 0.5)
        // A trickle: 1 KB over 1s = 1 KB/s.
        _ = est.sample(bytes: 0, at: Self.t(0))
        _ = est.sample(bytes: 1_000, at: Self.t(1))
        // 1 GB remaining at 1 KB/s ⇒ ~278h ≫ 12h ⇒ suppressed.
        #expect(est.eta(expectedTotal: 1_000_000_000) == nil)
    }

    @Test("eta is nil before any rate is available")
    func etaNilBeforeRate() {
        var est = DownloadRateEstimator(firstEmitWindow: 0.5)
        _ = est.sample(bytes: 0, at: Self.t(0))
        #expect(est.eta(expectedTotal: 100_000_000) == nil)
    }
}
