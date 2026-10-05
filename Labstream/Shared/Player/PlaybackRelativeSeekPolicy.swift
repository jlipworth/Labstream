/// Relative jumps compose against outstanding user intent, not a stale native clock.
enum PlaybackRelativeSeekPolicy {
    static func target(heldMs: Int?, liveMs: Int?, explicitBaseMs: Int?,
                       fallbackMs: @autoclosure () -> Int,
                       deltaSeconds: Int, durationMs: Int?) -> Int {
        let base = heldMs ?? liveMs ?? explicitBaseMs ?? fallbackMs()
        let (delta, deltaOverflow) = deltaSeconds.multipliedReportingOverflow(by: 1000)
        let (sum, sumOverflow) = base.addingReportingOverflow(delta)
        let unclamped = deltaOverflow || sumOverflow
            ? (deltaSeconds < 0 ? Int.min : Int.max) : sum
        let lowerClamped = max(unclamped, 0)
        if let durationMs, durationMs > 0 { return min(lowerClamped, durationMs) }
        return lowerClamped
    }
}
