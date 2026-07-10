import Foundation

/// Persisted wall-clock deadline for a Plex server-side optimize attempt.
///
/// Healthy metadata polls can succeed forever without ever producing a new Part (stalled/paused
/// queue item, lost queue ownership, or an inert completed item). The start instant lives in
/// `OfflineMetadata`, so relaunching cannot reset this deadline and resume an immortal poll loop.
public enum PlexOptimizeDeadlinePolicy {
    public static let maximumDurationSeconds: TimeInterval = 24 * 60 * 60

    public static func isExpired(startedAtEpochSeconds: TimeInterval,
                                 nowEpochSeconds: TimeInterval) -> Bool {
        guard startedAtEpochSeconds.isFinite, nowEpochSeconds.isFinite else { return true }
        // A future timestamp can result from a corrected clock. Do not instantly fail it; measure
        // from zero elapsed until wall time catches up.
        let elapsed = max(0, nowEpochSeconds - startedAtEpochSeconds)
        return elapsed >= maximumDurationSeconds
    }
}
