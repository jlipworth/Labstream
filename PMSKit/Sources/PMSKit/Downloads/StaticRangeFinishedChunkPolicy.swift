/// Pure pause/cancel decision for a completed static byte-range chunk.
///
/// The transfer engine may receive a finished chunk after the row was paused or cancelled. Pauses
/// should preserve a fully completed checkpoint chunk and stop before the next chunk; hard cancels
/// should discard the temp so deleted rows do not resurrect bytes.
public enum StaticRangeFinishedChunkDisposition: Sendable, Equatable {
    /// Drop the temp without writing it into the durable partial.
    case discardTemp
    /// Fold the temp into the durable partial, then leave the row paused.
    case writeThenPause
    /// Fold the temp into the durable partial and continue/finalize normally.
    case writeThenContinue
}

public enum StaticRangeFinishedChunkPolicy {
    public static func shouldDiscardBeforeStash(isHalted: Bool,
                                                persistedStatusPaused: Bool) -> Bool {
        isHalted && !persistedStatusPaused
    }

    public static func disposition(isHalted: Bool,
                                   persistedStatusPaused: Bool,
                                   segmentKind: RangeTransferSegmentKind,
                                   gracefulPauseRequested: Bool) -> StaticRangeFinishedChunkDisposition {
        if shouldDiscardBeforeStash(isHalted: isHalted, persistedStatusPaused: persistedStatusPaused) {
            return .discardTemp
        }
        if isHalted && persistedStatusPaused {
            return .writeThenPause
        }
        if gracefulPauseRequested && RangeTransferHTTPPolicy.isDurableCheckpointSegment(segmentKind) {
            return .writeThenPause
        }
        return .writeThenContinue
    }
}
