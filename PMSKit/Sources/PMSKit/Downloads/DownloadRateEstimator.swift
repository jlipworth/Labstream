import Foundation

/// Pure, unit-testable derivation of a download's smoothed transfer rate (bytes/sec) and the
/// ETA derived from it (#123).
///
/// Lives here (rather than buried in the `@MainActor DownloadManager`) so the speed/ETA math is
/// testable without the app target — the same split that already worked for `DownloadProgressDisplay`.
/// The owner feeds cumulative `(bytes, now)` samples; the estimator keeps a short trailing window of
/// observations and reports the **time-weighted average rate over that window** — Σdb / Σdt including
/// the quiet ticks. That single rule fixes the four field bugs the old ad-hoc EMA had:
///
/// 1. **Slow first readout** — a provisional rate is emitted as soon as the window spans
///    `firstEmitWindow` (0.5s) with forward bytes, instead of waiting for the ≥1s steady-state gate.
/// 2. **Stale-on-stall** — because quiet ticks (`db == 0`) are folded into the average's denominator,
///    a wedged transfer's rate decays toward 0 as the window fills with no-progress span, and drops
///    to `nil` once nothing has moved for `stallTimeout`. The old EMA skipped quiet windows entirely
///    and held the last (too-high) value forever.
/// 3. **Resume / non-monotonic bytes** — a sample whose `bytes < previous` (a 200 full-restart or a
///    stale-resume backwards jump) re-baselines the whole window instead of emitting a negative/garbage
///    rate or computing the next window against a byte count the task already passed.
/// 4. **Upward bias vs Σbytes/elapsed** — the window average's denominator is wall-clock (it includes
///    the skipped sub-1s/quiet ticks), so the displayed value reconciles with the user's
///    Σbytes/elapsed mental model rather than reading high after a burst.
///
/// `now` is always passed in (never `Date()` internally) so tests can drive a synthetic clock.
public struct DownloadRateEstimator: Sendable, Equatable {

    /// One cumulative observation: total bytes transferred as of `time`.
    private struct Observation: Sendable, Equatable {
        var bytes: Int
        var time: Date
    }

    /// Trailing window of observations, oldest first. The reported rate is Σdb / Σdt across this
    /// window (first→last), so quiet ticks pull the average down naturally.
    private var window: [Observation] = []

    /// Time of the most recent sample whose byte count moved FORWARD vs. the prior sample. Tracked
    /// explicitly (not scanned from `window`) so the stall cutoff is independent of window trimming —
    /// a forward tick can age out of the averaging window while we still need to know how long ago it
    /// was. `nil` until the first forward movement is observed.
    private var lastForwardTime: Date? = nil

    /// After a backwards byte-count rebaseline, optionally suppress speed/ETA for a short grace
    /// window. Static byte-range downloads can deliberately reset visible bytes from optimistic
    /// URLSession temp progress back to the durable checkpoint when promoting/cancelling a task;
    /// publishing the next tiny post-reset window reads as a bogus high-speed flash.
    private var rebaselineSuppressUntil: Date? = nil

    /// Length of the trailing averaging window. ~4s of memory matches the old EMA's feel while
    /// still being a true time-weighted average rather than a quiet-window-skipping EMA.
    public let windowDuration: TimeInterval

    /// The window must span at least this long before a (provisional) rate is emitted. Shorter than
    /// the steady-state window so the first readout appears in ~0.5s instead of ~1.5s.
    public let firstEmitWindow: TimeInterval

    /// No forward byte progress for at least this long ⇒ the transfer is wedged; report `nil` rather
    /// than a stale rate. (The window-average already decays toward 0 before this fires; this is the
    /// hard cutoff that drops the readout entirely.)
    public let stallTimeout: TimeInterval

    /// Optional grace period after a backwards rebaseline during which rate/ETA stay hidden.
    /// Defaults to zero to preserve the estimator's historical pure behavior for callers that want
    /// immediate restart rates; the download UI opts into a short grace for #169 checkpoint resets.
    public let rebaselineSuppressWindow: TimeInterval

    public init(windowDuration: TimeInterval = 4.0,
                firstEmitWindow: TimeInterval = 0.5,
                stallTimeout: TimeInterval = 6.0,
                rebaselineSuppressWindow: TimeInterval = 0) {
        self.windowDuration = windowDuration
        self.firstEmitWindow = firstEmitWindow
        self.stallTimeout = stallTimeout
        self.rebaselineSuppressWindow = max(0, rebaselineSuppressWindow)
    }

    /// Feed a cumulative `(bytes, now)` sample; returns the smoothed bytes/sec, or `nil` until a
    /// valid rate is available (first sample is baseline-only) and again once the transfer stalls.
    ///
    /// - Parameters:
    ///   - bytes: cumulative bytes transferred so far (`DownloadRecord.bytes`).
    ///   - now: the caller's clock (pass `Date()` from the actor; tests pass a synthetic time).
    /// - Returns: smoothed bytes/sec, or `nil` (baseline-only, stalled, or not yet enough span).
    @discardableResult
    public mutating func sample(bytes: Int, at now: Date) -> Double? {
        // Re-baseline on a backwards byte count (200 full-restart / stale-resume): the window is
        // measured against a byte total the task already passed, so drop it entirely and start over
        // from this lower point rather than emit a negative/garbage rate. The stall clock also resets —
        // the restart IS forward progress relative to the new baseline.
        if let last = window.last, bytes < last.bytes {
            window = [Observation(bytes: bytes, time: now)]
            lastForwardTime = now
            rebaselineSuppressUntil = rebaselineSuppressWindow > 0
                ? now.addingTimeInterval(rebaselineSuppressWindow)
                : nil
            return nil
        }

        if let last = window.last {
            if bytes > last.bytes { lastForwardTime = now }
        } else {
            // First-ever sample establishes the baseline; treat it as the start of the stall clock so
            // a transfer that never moves a byte still times out from when we began watching it.
            lastForwardTime = now
        }
        window.append(Observation(bytes: bytes, time: now))

        // Hard stall cutoff: no forward byte progress for ≥ `stallTimeout` ⇒ the transfer is wedged;
        // suppress the readout rather than advertise a stale rate. Checked against the explicitly
        // tracked last-forward time so it survives window trimming.
        if let lastForwardTime, now.timeIntervalSince(lastForwardTime) >= stallTimeout {
            trimWindow(asOf: now)
            return nil
        }

        trimWindow(asOf: now)

        if let rebaselineSuppressUntil, now < rebaselineSuppressUntil { return nil }

        guard let oldest = window.first, let newest = window.last else { return nil }
        let dt = newest.time.timeIntervalSince(oldest.time)
        let db = newest.bytes - oldest.bytes
        // Need at least the first-emit span before publishing anything (baseline-only otherwise).
        guard dt >= firstEmitWindow, db >= 0 else { return nil }
        let rate = Double(db) / dt
        return rate.isFinite ? rate : nil
    }

    /// Estimated seconds remaining given the expected final size, using the most recent windowed
    /// rate. `nil` when there is no rate yet, no expected total, or the estimate is non-finite/≤0.
    ///
    /// - Parameter expectedTotal: the row's expected final byte count — `bytes / progress` when a
    ///   `Content-Length` exists, else the duration×bitrate estimate, else `nil`.
    public func eta(expectedTotal: Int?) -> TimeInterval? {
        guard let expectedTotal,
              let newest = window.last else { return nil }
        if let rebaselineSuppressUntil, newest.time < rebaselineSuppressUntil { return nil }
        guard let rate = currentRate(), rate > 0 else { return nil }
        let remaining = Double(expectedTotal) - Double(newest.bytes)
        guard remaining > 0 else { return nil }
        let eta = remaining / rate
        guard eta.isFinite, eta > 0 else { return nil }
        return eta
    }

    /// The current windowed rate without mutating state (for `eta`). Mirrors the tail of `sample`.
    private func currentRate() -> Double? {
        guard let oldest = window.first, let newest = window.last else { return nil }
        let dt = newest.time.timeIntervalSince(oldest.time)
        let db = newest.bytes - oldest.bytes
        guard dt >= firstEmitWindow, db >= 0 else { return nil }
        let rate = Double(db) / dt
        return rate.isFinite ? rate : nil
    }

    /// Trim observations so the window spans at most `windowDuration` before the newest sample,
    /// always keeping ≥2 samples so a rate can still be computed. The oldest is dropped only when it
    /// is itself older than the cutoff AND the second-oldest still anchors the window (so we don't
    /// shrink a sparse-tick window below `windowDuration`).
    private mutating func trimWindow(asOf now: Date) {
        guard let newest = window.last else { return }
        let cutoff = newest.time.addingTimeInterval(-windowDuration)
        while window.count > 2, window[0].time < cutoff, window[1].time <= cutoff {
            window.removeFirst()
        }
    }
}
