/// Pure relaunch-adoption decision for static byte-range URLSession tasks.
///
/// Only open-ended `bytes=<durableOffset>-` remainder tasks from the #227+ architecture are
/// adoptable. Legacy closed ranges are deliberately dropped in #231 so late delegate callbacks
/// cannot append stale closed-range temps.
public enum StaticRangeReattachDisposition: Sendable, Equatable {
    case dropLegacyRange(requestedOffset: Int?, durableBytes: Int, rangeRequestShape: StaticRangeRequestShape)
    case rejectOffsetMismatch(requestedOffset: Int, durableBytes: Int)
    /// The task carries a download-attempt token that does not match the row's current attempt:
    /// it belongs to a prior attempt/life of the same ratingKey (cancelled, failed, or replaced
    /// at a different quality) and must be cancelled + superseded, never adopted.
    case rejectAttemptMismatch(taskAttemptID: String, rowAttemptID: String?)
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
    ///     `.closed` shape AND carries a v2 attempt token equal to `rowAttemptID`, the task is one
    ///     WE pre-queued for the CURRENT attempt and flows through the normal
    ///     adopt/suppress/replace machinery instead of `.dropLegacyRange`. A v1 marker (no token)
    ///     is legacy and dropped; any token that mismatches the row's attempt — on any request
    ///     shape — is `.rejectAttemptMismatch` (a prior attempt/life of the same key).
    ///   - rowAttemptID: the row's current persisted download-attempt token. `nil` (legacy row)
    ///     means no marked segment can be adopted.
    public static func plan(taskIdentifier: Int,
                            downloadID: String,
                            durableBytes: Int,
                            requestedOffset: Int?,
                            rangeRequestShape: StaticRangeRequestShape,
                            bodyBytesWritten: Int,
                            existingTasks: [StaticRangeTaskSnapshot],
                            taskMarker: String? = nil,
                            rowAttemptID: String? = nil) -> StaticRangeReattachPlan {
        let markedOffset = StaticRangeSegmentMarker.parse(taskMarker)
        let taskAttemptID = BackgroundDownloadTaskIdentity.attemptID(taskDescription: taskMarker)
        if let taskAttemptID, taskAttemptID != rowAttemptID {
            return StaticRangeReattachPlan(
                candidateBaseOffset: requestedOffset ?? durableBytes,
                disposition: .rejectAttemptMismatch(taskAttemptID: taskAttemptID,
                                                    rowAttemptID: rowAttemptID)
            )
        }
        let isAdoptableMarkedSegment = rangeRequestShape == .closed
            && markedOffset != nil
            && markedOffset == requestedOffset
            && taskAttemptID != nil
            && taskAttemptID == rowAttemptID

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
            // A marked segment ahead of the durable checkpoint is adoptable regardless of grid
            // alignment: the attempt token above already proves this attempt planned it, and the
            // planner anchors its grid at the durable bytes of the moment it planned — a train
            // planned from a mid-file checkpoint (legacy open-ended partial, crash-mid-append) is
            // legitimately off any absolute grid. Requiring `requestedOffset % segmentBytes == 0`
            // (anchored at 0) dropped every off-head background segment of such trains on each
            // relaunch. Behind-durable segments stay rejected: their bytes are already durable.
            let isOwnedSegmentAheadOfDurable = isAdoptableMarkedSegment
                && requestedOffset >= durableBytes
            if !isOwnedSegmentAheadOfDurable {
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
