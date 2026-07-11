/// Pure coordinate helpers for pointer-driven trick-play previews.
public enum TrickPlayPreviewGeometry {
    /// Maps a pointer's local horizontal position to a clamped media target.
    public static func targetMs(pointerX: Double, trackWidth: Double, durationMs: Int) -> Int? {
        guard trackWidth > 0, durationMs > 0 else { return nil }
        let fraction = min(max(pointerX / trackWidth, 0), 1)
        return Int((Double(durationMs) * fraction).rounded())
    }

    /// Keeps a preview card centered on the pointer without clipping either track edge.
    public static func cardCenterX(pointerX: Double, trackWidth: Double, cardWidth: Double) -> Double {
        guard trackWidth > 0 else { return 0 }
        let effectiveCardWidth = min(max(cardWidth, 0), trackWidth)
        let halfWidth = effectiveCardWidth / 2
        return min(max(pointerX, halfWidth), trackWidth - halfWidth)
    }
}
