import Foundation

/// A single closed-range (or, as a fallback, open-ended) segment to enqueue as a background
/// `Range` request for a static-byte-range download.
public struct StaticRangeSegmentPlan: Equatable, Sendable {
    public let offset: Int
    /// Byte count of this segment, or `nil` for an open-ended fallback (unknown total size).
    public let length: Int?

    public init(offset: Int, length: Int?) {
        self.offset = offset
        self.length = length
    }

    /// The `Range` request header value for this segment.
    public var rangeHeaderValue: String {
        let policy = StaticRangeRemainderRequestPolicy()
        guard let length else {
            return policy.rangeHeaderValue(offset: offset)
        }
        return policy.rangeHeaderValue(offset: offset, length: length)
    }
}

/// Pure, IO-free policy deciding which closed-range segments to pre-queue as a train of
/// background `URLSessionDownloadTask`s for a static-byte-range download (range-segments work).
///
/// Segments execute OS-side without app wakeups; their bodies are appended to the durable
/// partial file whenever the app is next serviced. This policy only decides which ranges to
/// enqueue next — it never touches disk or the network.
public enum StaticRangeSegmentQueuePolicy {
    /// Compute the closed-range segments to enqueue next.
    ///
    /// - Parameters:
    ///   - durableBytes: bytes already durably written to the partial file.
    ///   - expectedBytes: total object size, or `nil` if unknown.
    ///   - liveSegments: segments already in flight or held (queued, executing, or stashed
    ///     out-of-order bodies). Each covers `[offset, offset + length)`; an open-ended live
    ///     segment (`length == nil`) covers everything from its offset onward.
    ///   - segmentBytes: size of each closed-range segment.
    ///   - maxQueuedSegments: the cap on live + newly-planned segment depth.
    /// - Returns: new segment plans to enqueue, topping the live depth up to `maxQueuedSegments`.
    ///   Empty when `durableBytes >= expectedBytes` or the live train is already at the cap.
    ///   When `expectedBytes` is `nil`, returns exactly one open-ended plan (`length == nil`)
    ///   starting at `durableBytes`.
    ///
    /// Coverage is judged by INTERVAL, not offset equality: after a relaunch from a mid-file
    /// checkpoint the adopted segments sit on the prior attempt's grid, and a fresh grid anchored
    /// at the new durable offset would otherwise overlap — and refetch — every one of them.
    /// Planned segments fill only the uncovered gaps (a filler shorter than `segmentBytes` is
    /// planned up to the next covered interval).
    public static func segmentsToEnqueue(durableBytes: Int,
                                         expectedBytes: Int?,
                                         liveSegments: [StaticRangeSegmentPlan],
                                         segmentBytes: Int,
                                         maxQueuedSegments: Int) -> [StaticRangeSegmentPlan] {
        let durableBytes = max(0, durableBytes)

        guard let expectedBytes else {
            return [StaticRangeSegmentPlan(offset: durableBytes, length: nil)]
        }
        guard durableBytes < expectedBytes else { return [] }

        let budget = maxQueuedSegments - liveSegments.count
        guard budget > 0, segmentBytes > 0 else { return [] }

        let covered: [(start: Int, end: Int)] = liveSegments
            .map { segment in
                (start: segment.offset, end: segment.length.map { segment.offset + $0 } ?? expectedBytes)
            }
            .filter { $0.end > $0.start }

        var offset = durableBytes
        var plans: [StaticRangeSegmentPlan] = []
        while plans.count < budget, offset < expectedBytes {
            if let covering = covered.first(where: { $0.start <= offset && offset < $0.end }) {
                offset = covering.end
                continue
            }
            let nextCoveredStart = covered.map(\.start).filter { $0 > offset }.min() ?? expectedBytes
            let length = min(segmentBytes, expectedBytes - offset, nextCoveredStart - offset)
            plans.append(StaticRangeSegmentPlan(offset: offset, length: length))
            offset += length
        }
        return plans
    }
}
