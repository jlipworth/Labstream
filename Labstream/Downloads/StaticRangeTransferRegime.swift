/// Which static-range transfer regime this platform runs. `.segmentTrain` is the
/// pre-queued closed-segment design; `.openEndedRemainder` is the pre-segment shipping
/// behavior (single `Range: bytes=N-` task). Flip a platform back with a one-line edit —
/// both regimes recover from the durable-partial checkpoint, so switching across
/// launches is safe.
enum StaticRangeTransferRegime {
    case segmentTrain
    case openEndedRemainder

    static var current: StaticRangeTransferRegime {
        #if os(visionOS)
        return .segmentTrain
        #else
        return .segmentTrain   // flip to .openEndedRemainder to bifurcate non-visionOS
        #endif
    }

    /// Size of each closed-range segment in the pre-queued train.
    static let segmentBytes = 512 * 1024 * 1024
    /// Cap on live + newly-planned segment depth per download.
    static let maxQueuedSegments = 8
}
