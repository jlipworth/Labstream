import Foundation

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
    static var segmentBytes: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--vp-probe-range-segment-bytes"),
           args.indices.contains(index + 1),
           let bytes = Int(args[index + 1]), bytes > 0 {
            return bytes
        }
        #endif
        // The original device failure was excessive train DEPTH: five rows expanded to 34
        // simultaneous tasks. Keep long-lived 512 MiB background transfers, which avoid repeatedly
        // completing and replacing 64 MiB URLSession tasks while off-head, and bound fan-out with
        // maxQueuedSegments below.
        return 512 * 1024 * 1024
    }
    /// Cap on live + newly-planned segment depth per download.
    /// Two keeps one head plus one look-ahead segment active. This preserves overlap without
    /// multiplying five visible downloads into 40 competing HTTP/3 transactions.
    static let maxQueuedSegments = 2
}
