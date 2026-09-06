import Foundation

/// Transport activity alone must not keep a non-playing stream waiting forever.
/// Preserve one normal grace interval, then stop deferring after two intervals.
public enum PlaybackStallDeadlinePolicy {
    public static func allowsDeferral(waitingSince: TimeInterval, now: TimeInterval,
                                      interval: TimeInterval) -> Bool {
        guard waitingSince.isFinite, now.isFinite, interval.isFinite, interval > 0,
              now >= waitingSince else { return false }
        return now - waitingSince < interval * 2
    }
}
