/// Pure continuation decisions for the static byte-range transfer engine after a response body has
/// advanced the durable partial, hit a recoverable offset mismatch, or detected a changed source.
///
/// The app layer still owns URLSession, file, store, and diagnostics side effects. This policy keeps
/// the retry/resume routing table explicit: halted rows do nothing, relaunch-adopted remainders ask
/// the backend layer to rebuild authenticated requests, exhausted recovery attempts fail, and live
/// in-memory remainders can immediately schedule a fresh open-ended request.
public enum StaticRangeContinuationDisposition: Sendable, Equatable {
    /// Pause/delete already owns the row; do not schedule, fail, or request backend work.
    case halted
    /// The transfer engine has no authenticated base request; persist queued intent and ask the
    /// backend coordinator to rebuild the request for the durable checkpoint/restart.
    case requestNeeded(BackgroundRangeRequestReason)
    /// The transfer engine still has the base request and can schedule a new Range request directly.
    case startInSession
    /// The bounded retry/restart budget was exhausted; surface a terminal failure.
    case failExhausted
}

public enum StaticRangeContinuationPolicy {
    public static func afterFinishedBody(isHalted: Bool,
                                         hasRequest: Bool) -> StaticRangeContinuationDisposition {
        if isHalted { return .halted }
        return hasRequest ? .startInSession : .requestNeeded(.requestRebuildNeeded)
    }

    public static func afterOffsetMismatch(isHalted: Bool,
                                           retryAttempt: StaticRangeRetryAttempt,
                                           hasRequest: Bool) -> StaticRangeContinuationDisposition {
        if isHalted { return .halted }
        if retryAttempt.isExhausted { return .failExhausted }
        return hasRequest ? .startInSession : .requestNeeded(.requestRebuildNeeded)
    }

    public static func afterValidatorChange(isHalted: Bool,
                                            retryAttempt: StaticRangeRetryAttempt,
                                            hasRequest: Bool) -> StaticRangeContinuationDisposition {
        if isHalted { return .halted }
        if retryAttempt.isExhausted { return .failExhausted }
        return hasRequest ? .startInSession : .requestNeeded(.validatorChanged)
    }
}
