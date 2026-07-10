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
    ///   - liveSegmentOffsets: start offsets of segments already in flight (queued or executing).
    ///   - segmentBytes: size of each closed-range segment.
    ///   - maxQueuedSegments: the cap on live + newly-planned segment depth.
    /// - Returns: new segment plans to enqueue, topping the live depth up to `maxQueuedSegments`.
    ///   Empty when `durableBytes >= expectedBytes` or the live train is already at the cap.
    ///   When `expectedBytes` is `nil`, returns exactly one open-ended plan (`length == nil`)
    ///   starting at `durableBytes`.
    public static func segmentsToEnqueue(durableBytes: Int,
                                         expectedBytes: Int?,
                                         liveSegmentOffsets: Set<Int>,
                                         segmentBytes: Int,
                                         maxQueuedSegments: Int) -> [StaticRangeSegmentPlan] {
        let durableBytes = max(0, durableBytes)

        guard let expectedBytes else {
            return [StaticRangeSegmentPlan(offset: durableBytes, length: nil)]
        }
        guard durableBytes < expectedBytes else { return [] }

        let liveDepth = liveSegmentOffsets.count
        let budget = maxQueuedSegments - liveDepth
        guard budget > 0, segmentBytes > 0 else { return [] }

        // Start planning at the first byte not already covered by durable bytes or a live
        // segment: walk the segment grid forward from durableBytes, skipping any offset that
        // already has a live segment in flight.
        var offset = durableBytes
        var plans: [StaticRangeSegmentPlan] = []
        while plans.count < budget, offset < expectedBytes {
            if liveSegmentOffsets.contains(offset) {
                offset += segmentBytes
                continue
            }
            let remaining = expectedBytes - offset
            let length = min(segmentBytes, remaining)
            plans.append(StaticRangeSegmentPlan(offset: offset, length: length))
            offset += segmentBytes
        }
        return plans
    }
}
