/// Pure progress-reporting decisions shared by Jellyfin/Emby video playback.
public enum MediaBrowserPlaybackProgressEvent: Sendable, Equatable {
    case playing
    case progress
    case stopped
}

public enum MediaBrowserPlaybackProgressPolicy {
    public static let ticksPerMillisecond = 10_000

    public static func positionTicks(milliseconds: Int) -> Int {
        max(0, milliseconds) * ticksPerMillisecond
    }

    public static func event(for state: TimelineRequest.State,
                             hasStartedSession: Bool) -> MediaBrowserPlaybackProgressEvent {
        switch state {
        case .stopped:
            return .stopped
        case .playing, .paused, .buffering:
            return hasStartedSession ? .progress : .playing
        }
    }
}
