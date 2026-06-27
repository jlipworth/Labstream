import Foundation

/// Normalizes AVPlayer's current time for backend-resolved remote streams.
///
/// Jellyfin/Emby HLS transcodes can be opened at a non-zero media offset while AVPlayer's item
/// clock still starts near zero. Server timeline/progress reporting must use the absolute media
/// position, not that item-relative clock, or Continue Watching can regress to the beginning.
public enum RemotePlaybackPositionPolicy {
    /// Returns an absolute media position in milliseconds.
    ///
    /// - Parameters:
    ///   - playerTimeMs: The current `AVPlayer` item time in milliseconds.
    ///   - streamBaseMs: The absolute media offset used to open/prime the current stream.
    ///   - absoluteClockSlackMs: How far below `streamBaseMs` an AVPlayer time may be and still be
    ///     treated as already absolute. This covers normal segment-boundary snapping around a
    ///     requested offset without double-counting the base.
    public static func absolutePositionMs(playerTimeMs rawMs: Int,
                                          streamBaseMs baseMs: Int?,
                                          absoluteClockSlackMs: Int = 5_000) -> Int {
        let raw = max(0, rawMs)
        guard let base = baseMs, base > 0 else { return raw }
        let absoluteThreshold = max(0, base - max(0, absoluteClockSlackMs))
        if raw < absoluteThreshold {
            return base + raw
        }
        return raw
    }
}
