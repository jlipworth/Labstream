import Foundation

/// Pure decisions that keep a closed-range segment train byte-consistent when the source
/// resource changes underneath it (#169 HIGH 1 follow-up: audit B.2 / B.3(b)).
///
/// `BackgroundDownloadSession` owns the URLSession tasks, the held-segment stashes, and the
/// durable partial; this policy owns only the version-consistency logic:
/// - which train-teardown events must supersede every in-flight sibling segment (a
///   changed-resource restart or an adopted whole-file 200 makes every sibling's bytes stale —
///   leaving them running lets the re-plan trust old-resource fetchers, and their late finishes
///   would splice or destructively re-restart);
/// - whether a finished body still belongs to the current train generation (a body whose train
///   was torn down after its delegate finish must be discarded, never applied);
/// - how an arriving 206 body's resource validator relates to the pinned one (pin the first,
///   restart on a definite change, tolerate absence);
/// - whether a held out-of-order stash may still be spliced at drain time.
public enum StaticRangeTrainIntegrityPolicy {
    /// Events that invalidate every other in-flight segment of a ratingKey's train.
    public enum TrainTeardownTrigger: Equatable {
        /// The pinned validator changed mid-download: partial deleted, restarting from 0.
        case changedResourceRestart
        /// An HTTP 200 whole-file body was adopted and replaced the durable partial.
        case adoptedWholeFileReplace
    }

    public struct TrainTeardownActions: Equatable {
        /// Remove every in-flight sibling from tracking and cancel its URLSession task, so the
        /// re-plan cannot treat a stale old-resource fetcher as covering its offset.
        public let supersedeInFlightTasks: Bool
        /// Delete held out-of-order stashes — their bytes belong to the previous resource version.
        public let purgeHeldSegments: Bool
        /// Advance the train generation so bodies already past the delegate (stashed, queued for
        /// apply) are recognized as stale and discarded instead of applied.
        public let advanceTrainEpoch: Bool
    }

    /// Both teardown triggers require the full teardown: supersede, purge, and epoch advance.
    public static func teardownActions(for trigger: TrainTeardownTrigger) -> TrainTeardownActions {
        switch trigger {
        case .changedResourceRestart, .adoptedWholeFileReplace:
            return TrainTeardownActions(supersedeInFlightTasks: true,
                                        purgeHeldSegments: true,
                                        advanceTrainEpoch: true)
        }
    }

    /// A finished body may only be applied when its train generation is still current. A stale
    /// body (its train was superseded between the delegate finish and the off-queue apply) must
    /// be discarded: appending it would splice old-resource bytes, and letting it re-run the
    /// changed-resource restart would delete a just-completed replacement file.
    public static func shouldProcessFinishedBody(bodyTrainEpoch: Int, currentTrainEpoch: Int) -> Bool {
        bodyTrainEpoch == currentTrainEpoch
    }

    public enum ArrivingBodyValidatorDecision: Equatable {
        /// Validators are consistent, or absence is tolerated — apply the body.
        case proceed
        /// No validator pinned yet: pin this body's validator (first arrival wins, head OR held)
        /// so every later sibling is verified against it, then apply the body.
        case pinAndProceed(String)
        /// Definite resource change: the body is bytes from a different version — restart from 0.
        case restartChangedResource
    }

    /// Version check for any owned 206 segment body (in-order head or out-of-order held) BEFORE
    /// it is appended or stashed. Only a present-and-different validator triggers a restart; an
    /// absent response validator (transient header omission) must not loop restarts. When nothing
    /// is pinned yet, the first body carrying a validator pins it — closing the window where a
    /// held body could be stashed unchecked before the offset-0 append pins one.
    public static func arrivingBodyDecision(storedValidator: String?,
                                            responseValidator: String?) -> ArrivingBodyValidatorDecision {
        if let storedValidator {
            if let responseValidator, responseValidator != storedValidator {
                return .restartChangedResource
            }
            return .proceed
        }
        if let responseValidator {
            return .pinAndProceed(responseValidator)
        }
        return .proceed
    }

    public enum HeldSpliceDecision: Equatable {
        case splice
        /// The stash was recorded against a different resource version than the one now pinned —
        /// discard it and let the planner re-fetch the hole rather than corrupt the partial.
        case discardChangedResource
    }

    /// Re-verify a held stash at SPLICE time. The pinned validator can change between hold and
    /// drain (restart, replaceWhole, re-pin), so the hold-time check alone is not sufficient.
    /// Symmetric tolerance with `arrivingBodyDecision`: only present-and-different rejects.
    public static func heldSpliceDecision(storedValidator: String?,
                                          heldValidator: String?) -> HeldSpliceDecision {
        if let storedValidator, let heldValidator, heldValidator != storedValidator {
            return .discardChangedResource
        }
        return .splice
    }
}
