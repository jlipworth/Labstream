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

public enum StaticRangeFinishedBodyPolicy {
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
