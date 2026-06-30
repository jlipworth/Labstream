/// Pure continuation decisions for the static byte-range transfer engine after a chunk has either
/// advanced a durable checkpoint, hit a recoverable offset mismatch, or detected a changed source.
///
/// The app layer still owns URLSession, file, store, and diagnostics side effects. This policy keeps
/// the retry/resume routing table explicit: halted rows do nothing, adopted relaunch chunks ask the
/// backend layer to rebuild authenticated requests, exhausted recovery attempts fail, and live
/// in-memory chunks can immediately schedule the next request.
public enum StaticRangeContinuationDisposition: Sendable, Equatable {
    /// Pause/delete already owns the row; do not schedule, fail, or request backend work.
    case halted
    /// A relaunch-adopted chunk has no authenticated base request; persist queued intent and ask the
    /// backend coordinator to rebuild the request for the durable checkpoint/restart.
    case requestNeeded(BackgroundRangeRequestReason)
    /// The transfer engine still has the base request and can schedule a new Range chunk directly.
    case startInSession
    /// The bounded retry/restart budget was exhausted; surface a terminal failure.
    case failExhausted
}

public enum StaticRangeContinuationPolicy {
    public static func afterFinishedChunk(isHalted: Bool,
                                          hasRequest: Bool) -> StaticRangeContinuationDisposition {
        if isHalted { return .halted }
        return hasRequest ? .startInSession : .requestNeeded(.adoptedChunkFinished)
    }

    public static func afterOffsetMismatch(isHalted: Bool,
                                           retryAttempt: StaticRangeRetryAttempt,
                                           hasRequest: Bool) -> StaticRangeContinuationDisposition {
        if isHalted { return .halted }
        if retryAttempt.isExhausted { return .failExhausted }
        return hasRequest ? .startInSession : .requestNeeded(.adoptedChunkFailed)
    }

    public static func afterValidatorChange(isHalted: Bool,
                                            retryAttempt: StaticRangeRetryAttempt,
                                            hasRequest: Bool) -> StaticRangeContinuationDisposition {
        if isHalted { return .halted }
        if retryAttempt.isExhausted { return .failExhausted }
        return hasRequest ? .startInSession : .requestNeeded(.validatorChanged)
    }
}
