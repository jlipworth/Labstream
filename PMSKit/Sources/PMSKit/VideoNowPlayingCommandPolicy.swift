import Foundation

/// Pure validation and intent construction for video Now Playing remote commands.
public enum VideoNowPlayingCommandPolicy {
    public enum Intent: Equatable, Sendable {
        case seek(toMilliseconds: Int)
        case skip(bySeconds: Int)
    }

    public enum SkipDirection: Sendable {
        case forward
        case backward
    }

    /// Validate a system-supplied absolute position and turn it into the canonical seek intent.
    /// Malformed values fail closed. Valid positions beyond a known duration (or `Int`'s range)
    /// clamp to the corresponding upper bound before any potentially trapping conversion.
    public static func seekIntent(positionTime: Double?,
                                  durationMilliseconds: Int?) -> Intent? {
        guard let positionTime, positionTime.isFinite, positionTime >= 0 else { return nil }

        let upperBound = durationMilliseconds.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
        let requestedMilliseconds = (positionTime * 1000).rounded()
        guard requestedMilliseconds.isFinite,
              requestedMilliseconds < Double(upperBound),
              requestedMilliseconds < Double(Int.max) else {
            return .seek(toMilliseconds: upperBound)
        }
        return .seek(toMilliseconds: Int(requestedMilliseconds))
    }

    /// Validate a system-supplied skip interval and turn it into a signed relative-seek intent.
    /// A missing interval uses the platform's configured fallback. A present but malformed value
    /// is rejected rather than silently converted into the fallback.
    public static func skipIntent(interval: Double?,
                                  fallbackSeconds: Double,
                                  direction: SkipDirection) -> Intent? {
        let candidate = interval ?? fallbackSeconds
        guard candidate.isFinite,
              candidate > 0,
              candidate <= Double(Int.max / 1000) else { return nil }

        let magnitude = max(1, Int(candidate.rounded()))
        // `Double(Int.max / 1000)` can round upward by one at this scale. Re-check the
        // converted integer so `PlaybackController` can multiply it by 1000 safely.
        guard magnitude <= Int.max / 1000 else { return nil }
        switch direction {
        case .forward:
            return .skip(bySeconds: magnitude)
        case .backward:
            return .skip(bySeconds: -magnitude)
        }
    }
}
