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
    public static func plan(taskIdentifier: Int,
                            downloadID: String,
                            durableBytes: Int,
                            requestedOffset: Int?,
                            rangeRequestShape: StaticRangeRequestShape,
                            bodyBytesWritten: Int,
                            existingTasks: [StaticRangeTaskSnapshot]) -> StaticRangeReattachPlan {
        guard rangeRequestShape == .openEnded else {
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
            return StaticRangeReattachPlan(
                candidateBaseOffset: requestedOffset,
                disposition: .rejectOffsetMismatch(
                    requestedOffset: requestedOffset,
                    durableBytes: durableBytes
                )
            )
        }

        let baseOffset = requestedOffset ?? durableBytes
        let candidate = StaticRangeTaskSnapshot(
            taskIdentifier: taskIdentifier,
            downloadID: downloadID,
            baseOffset: baseOffset,
            bodyBytesWritten: max(0, bodyBytesWritten)
        )
        guard let duplicate = StaticRangeTaskSelectionPolicy.duplicateDecision(
            candidate: candidate,
            existingTasks: existingTasks
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
