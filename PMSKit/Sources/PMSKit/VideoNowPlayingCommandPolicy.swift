import Foundation

/// Pure helpers for the video Now Playing remote-command path.
public enum VideoNowPlayingCommandPolicy {
    /// Convert an MPChangePlaybackPositionCommandEvent position to milliseconds,
    /// clamping invalid, negative, and over-duration values before the app's canonical
    /// user-seek path receives them.
    public static func clampedPositionMilliseconds(positionTime: Double,
                                                   durationMilliseconds: Int?) -> Int {
        guard positionTime.isFinite, positionTime > 0 else { return 0 }
        // Bound the Double BEFORE the Int conversion: Int(_:) traps on finite values
        // beyond Int.max, and the event position is system-supplied, not app-validated.
        let requestedMilliseconds = (positionTime * 1000).rounded()
        guard let durationMilliseconds, durationMilliseconds > 0 else {
            return requestedMilliseconds >= Double(Int.max) ? Int.max : Int(requestedMilliseconds)
        }
        return Int(min(requestedMilliseconds, Double(durationMilliseconds)))
    }
}
