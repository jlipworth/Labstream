/// Pure relaunch-adoption decision for static byte-range URLSession tasks.
///
/// A reappearing task is only authoritative if the requested Range starts at the durable partial
/// size. Anything else is stale or gapped. Once offset-safe, the same duplicate-task ownership rule
/// decides whether the adopted task replaces an older task or is suppressed by a newer one.
public enum StaticRangeReattachDisposition: Sendable, Equatable {
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
                            chunkBytesWritten: Int,
                            existingTasks: [StaticRangeTaskSnapshot]) -> StaticRangeReattachPlan {
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
            chunkBytesWritten: max(0, chunkBytesWritten)
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
