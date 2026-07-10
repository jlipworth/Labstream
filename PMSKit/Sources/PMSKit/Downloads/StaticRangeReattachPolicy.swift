/// Pure relaunch-adoption decision for static byte-range URLSession tasks.
///
/// Only open-ended `bytes=<durableOffset>-` remainder tasks from the #227+ architecture are
/// adoptable. Legacy closed ranges are deliberately dropped in #231 so late delegate callbacks
/// cannot append stale closed-range temps.
public enum StaticRangeReattachDisposition: Sendable, Equatable {
    case dropLegacyRange(requestedOffset: Int?, durableBytes: Int, rangeRequestShape: StaticRangeRequestShape)
    case rejectOffsetMismatch(requestedOffset: Int, durableBytes: Int)
    case adopt
    case replaceExisting(existingTaskIdentifier: Int, existingBaseOffset: Int)
    case suppressForExisting(existingTaskIdentifier: Int, existingBaseOffset: Int)
}

public struct StaticRangeReattachPlan: Sendable, Equatable {
    public let candidateBaseOffset: Int
    public let disposition: StaticRangeReattachDisposition

    public init(candidateBaseOffset: Int, disposition: StaticRangeReattachDisposition) {
        self.candidateBaseOffset = candidateBaseOffset
        self.disposition = disposition
    }
}

public enum StaticRangeReattachPolicy {
    /// - Parameters:
    ///   - taskMarker: the task's `taskDescription`. When it decodes (via
    ///     `StaticRangeSegmentMarker.parse`) to an offset matching `requestedOffset` on a
    ///     `.closed` shape, the task is one WE deliberately pre-queued (range-segments) and flows
    ///     through the normal adopt/suppress/replace machinery instead of `.dropLegacyRange`. Any
    ///     other closed-range task (nil/malformed marker, or a marker offset that does not match
    ///     the header) is treated as a pre-#231 legacy task and dropped, unchanged from before.
    ///   - segmentBytes: the closed-range segment grid size, when known. Lets a marked segment's
    ///     `requestedOffset` legitimately sit ahead of `durableBytes` (earlier segments still in
    ///     flight) without tripping the offset-mismatch guard, as long as the offset is aligned to
    ///     the segment grid. `nil` disables this exemption.
    public static func plan(taskIdentifier: Int,
                            downloadID: String,
                            durableBytes: Int,
                            requestedOffset: Int?,
                            rangeRequestShape: StaticRangeRequestShape,
                            bodyBytesWritten: Int,
                            existingTasks: [StaticRangeTaskSnapshot],
                            taskMarker: String? = nil,
                            segmentBytes: Int? = nil) -> StaticRangeReattachPlan {
        let markedOffset = StaticRangeSegmentMarker.parse(taskMarker)
        let isAdoptableMarkedSegment = rangeRequestShape == .closed
            && markedOffset != nil
            && markedOffset == requestedOffset

        guard rangeRequestShape == .openEnded || isAdoptableMarkedSegment else {
            return StaticRangeReattachPlan(
                candidateBaseOffset: requestedOffset ?? durableBytes,
                disposition: .dropLegacyRange(
                    requestedOffset: requestedOffset,
                    durableBytes: durableBytes,
                    rangeRequestShape: rangeRequestShape
                )
            )
        }

        if let requestedOffset, requestedOffset != durableBytes {
            let isGridAlignedAheadOfDurable = isAdoptableMarkedSegment
                && requestedOffset >= durableBytes
                && segmentBytes.map { $0 > 0 && requestedOffset % $0 == 0 } ?? false
            if !isGridAlignedAheadOfDurable {
                return StaticRangeReattachPlan(
                    candidateBaseOffset: requestedOffset,
                    disposition: .rejectOffsetMismatch(
                        requestedOffset: requestedOffset,
                        durableBytes: durableBytes
                    )
                )
            }
        }

        let baseOffset = requestedOffset ?? durableBytes
        let candidate = StaticRangeTaskSnapshot(
            taskIdentifier: taskIdentifier,
            downloadID: downloadID,
            baseOffset: baseOffset,
            bodyBytesWritten: max(0, bodyBytesWritten)
        )
        // Marked segments only supersede other tasks claiming the SAME offset — distinct
        // segments of one download's pre-queued train must coexist.
        let comparisonPool = isAdoptableMarkedSegment
            ? existingTasks.filter { $0.baseOffset == baseOffset }
            : existingTasks
        guard let duplicate = StaticRangeTaskSelectionPolicy.duplicateDecision(
            candidate: candidate,
            existingTasks: comparisonPool
        ) else {
            return StaticRangeReattachPlan(candidateBaseOffset: baseOffset, disposition: .adopt)
        }
        let disposition: StaticRangeReattachDisposition = duplicate.shouldReplaceExisting
            ? .replaceExisting(
                existingTaskIdentifier: duplicate.existingTaskIdentifier,
                existingBaseOffset: duplicate.existingBaseOffset
            )
            : .suppressForExisting(
                existingTaskIdentifier: duplicate.existingTaskIdentifier,
                existingBaseOffset: duplicate.existingBaseOffset
            )
        return StaticRangeReattachPlan(candidateBaseOffset: baseOffset, disposition: disposition)
    }
}
