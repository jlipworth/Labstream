import Foundation

/// Small pure helpers shared by playback UI that lets the user request an exact
/// seek target outside AVKit's currently-loaded buffer.
public enum PlaybackSeekControl {
    /// Clamp a requested seek target into a sane media timeline. Unknown duration
    /// still clamps negative input to zero, but otherwise preserves the user's target.
    public static func clamp(targetMs: Int, durationMs: Int?) -> Int {
        let lowerBounded = max(0, targetMs)
        guard let durationMs, durationMs > 0 else { return lowerBounded }
        return min(lowerBounded, durationMs)
    }

    /// Format milliseconds as `m:ss` or `h:mm:ss` for compact player chrome.
    public static func timecode(ms: Int) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
