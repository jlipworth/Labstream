/// Pure pause/cancel decision for a completed static byte-range transfer body.
///
/// The transfer engine may receive a finished body after the row was paused or cancelled. User
/// pauses should preserve a body that had already finished; hard cancels should discard the temp so
/// deleted rows do not resurrect bytes.

/// Why the halt was inserted. The engine records this at the halt site itself, because the
/// persisted row status is written asynchronously at the END of the pause chain — a body finishing
/// inside that window would otherwise be discarded despite the writeThenPause machinery (a pause
/// halt that still read `.downloading` from the store looked identical to a cancel).
public enum StaticRangeHaltKind: Sendable, Equatable {
    /// User/system pause: finished bodies are folded into the durable partial, then stay paused.
    case pause
    /// Cancel/delete/terminal failure: finished bodies are discarded — the caller may be deleting
    /// the partial, and resurrecting bytes onto it corrupts the replacement attempt.
    case cancel
}

public enum StaticRangeFinishedBodyDisposition: Sendable, Equatable {
    /// Drop the temp without writing it into the durable partial.
    case discardTemp
    /// Fold the temp into the durable partial, then leave the row paused.
    case writeThenPause
    /// Fold the temp into the durable partial and continue/finalize normally.
    case writeThenContinue
}

/// What a pause's task listing does with one listed task of the row (RangeTrain-R3, #474).
public enum StaticRangePauseSweepDisposition: Sendable, Equatable {
    /// The task is still transferring: drop its tracking, mark it superseded and cancel it.
    case supersedeAndCancel
    /// The task has finished and only its finish callback is outstanding. Leave it tracked, so
    /// the callback takes the finished-body path and `writeThenPause` keeps the body.
    case leaveForFinishCallback
}

public enum StaticRangeFinishedBodyPolicy {
    /// A task that finished in the daemon while a pause was landing is still listed by the
    /// pause's `getAllTasks`, with its finish callback queued behind that completion.
    /// Superseding it there made the callback ignore the body: one segment of a train, or the
    /// whole remainder on the open-ended fallback. A task counts as finished when URLSession
    /// says so, or when every byte its response declared has arrived. If that judgement is
    /// early, the next progress callback under the halt cancels the task as before.
    public static func pauseSweepDisposition(taskStateIsCompleted: Bool,
                                             bytesReceived: Int64,
                                             bytesExpectedToReceive: Int64) -> StaticRangePauseSweepDisposition {
        if taskStateIsCompleted { return .leaveForFinishCallback }
        if bytesExpectedToReceive > 0, bytesReceived >= bytesExpectedToReceive {
            return .leaveForFinishCallback
        }
        return .supersedeAndCancel
    }

    public static func shouldDiscardBeforeStash(haltKind: StaticRangeHaltKind?) -> Bool {
        haltKind == .cancel
    }

    public static func disposition(haltKind: StaticRangeHaltKind?) -> StaticRangeFinishedBodyDisposition {
        switch haltKind {
        case .cancel:
            return .discardTemp
        case .pause:
            return .writeThenPause
        case nil:
            return .writeThenContinue
        }
    }
}
