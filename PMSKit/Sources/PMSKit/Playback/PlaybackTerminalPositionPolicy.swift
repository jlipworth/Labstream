/// Resolves the one position that teardown is allowed to publish.
///
/// AVPlayer reports zero while an item is detached during a stream reopen. That clock is not a
/// real regression: prefer the seek/reopen target, then the last trustworthy position, before
/// falling back to the server-saved offset. A live clock that the controller has already judged
/// trustworthy remains authoritative, including an explicit user seek to the beginning.
public enum PlaybackTerminalPositionPolicy {
    public static func position(liveClockMs: Int?,
                                liveClockIsTrustworthy: Bool,
                                heldTargetMs: Int?,
                                lastTrustworthyMs: Int?,
                                savedOffsetMs: Int?) -> Int {
        if liveClockIsTrustworthy, let liveClockMs {
            return max(0, liveClockMs)
        }
        if let heldTargetMs {
            return max(0, heldTargetMs)
        }
        if let lastTrustworthyMs {
            return max(0, lastTrustworthyMs)
        }
        return max(0, savedOffsetMs ?? 0)
    }
}
