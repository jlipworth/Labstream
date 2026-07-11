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
        // Device evidence on 2026-07-11 showed five resumed rows expanding to 34 simultaneous
        // 512 MiB tasks. visionOS kept transferring off-head, but leading segments took so long
        // to finish that gigabytes remained in nsurlsessiond temp/held files with no durable
        // checkpoint. Smaller segments commit useful progress within minutes on a constrained
        // path instead of making the first checkpoint depend on a half-gigabyte head task.
        return 64 * 1024 * 1024
    }
    /// Cap on live + newly-planned segment depth per download.
    /// Two keeps one head plus one look-ahead segment active. This preserves overlap without
    /// multiplying five visible downloads into 40 competing HTTP/3 transactions.
    static let maxQueuedSegments = 2
}
