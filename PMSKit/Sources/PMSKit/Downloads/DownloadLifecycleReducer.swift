import Foundation

/// The facts a transition may depend on, built from the row and live session state at the moment
/// of the call (P3a.3). They are the distinctions today's reconcile table and retry policies use.
public struct DownloadRowFacts: Sendable, Equatable {
    public enum Route: Sendable, Equatable {
        case staticRange
        case plexPrep
        case embyConvert(hasJobOrIdentity: Bool)
        case forwardOnly
    }

    public enum Checkpoint: Sendable, Equatable {
        case none
        case durablePartial(bytes: Int)
        case resumeBlob
    }

    public enum Body: Sendable, Equatable {
        case none
        /// Moved out of the URLSession temp into an attempt-owned capture path (B10).
        case captured
        case workingComplete
        case published
    }

    public var route: Route
    public var checkpoint: Checkpoint
    public var body: Body
    public var pendingArtifactHead: Bool
    public var deletionPending: Bool
    public var liveTask: Bool
    public var snapshotEligible: Bool

    public init(route: Route, checkpoint: Checkpoint = .none, body: Body = .none,
                pendingArtifactHead: Bool = false, deletionPending: Bool = false,
                liveTask: Bool = false, snapshotEligible: Bool = true) {
        self.route = route
        self.checkpoint = checkpoint
        self.body = body
        self.pendingArtifactHead = pendingArtifactHead
        self.deletionPending = deletionPending
        self.liveTask = liveTask
        self.snapshotEligible = snapshotEligible
    }

    var hasResumableCheckpoint: Bool {
        switch checkpoint {
        case .durablePartial(let bytes): return bytes > 0
        case .resumeBlob: return true
        case .none: return false
        }
    }
}

public enum DownloadRetryMode: String, Sendable, Equatable {
    case freshAttempt
    case resumeBlob
    case staticCheckpoint
    case prepReattach
    case convertResume
}

public enum DownloadFinalizeOutcome: Sendable, Equatable {
    case complete
    case unverified(reason: String)
    case truncated
    case incompleteBytes
    case emptyFile
}

public enum DownloadLifecycleEvent: Sendable, Equatable {
    case pause(DownloadPauseCause)
    case retry(DownloadRetryMode)
    case retryRejected(DownloadFailureReason)
    case admissionGranted
    case prepReattached
    case prepHandoff
    case prepFailed(DownloadFailureReason)
    case transferStarted
    case transferProgress
    case checkpointAdvanced
    case transferRebuilding
    case taskAdopted
    case rebuildExpired
    case resourceChanged
    case transferInterrupted(DownloadFailureReason)
    case transferFailed(DownloadFailureReason)
    case backendUnavailable(DownloadPauseCause)
    case bodyCaptured
    case bodyAtWorking
    /// `outcomeID` = attempt + finalizer request; a replayed ID is a no-op (R2-5).
    case finalizeOutcome(id: String, outcome: DownloadFinalizeOutcome, source: DownloadSourceKey)
    case publishedBodyRevalidated(id: String, outcome: DownloadFinalizeOutcome)
    case promotionCommitted(DownloadLifecycle)
    case promotionAbandoned
    case promotionRecovered(DownloadLifecycle)
    case localPlaybackProgressed
    case sizeAuditFailed
    case stallDetected
    case relaunchObserved
}

public enum DownloadLifecycleEffect: Sendable, Equatable {
    case deleteWorkingBody
    case deletePublishedBody
    case clearResumeBlob
    case requestFinalization
    case publish(DownloadLifecycle)
    case resetBytesToDurableCheckpoint
    case resetBytesToZero
}

public struct DownloadLifecycleState: Sendable, Equatable {
    public var lifecycle: DownloadLifecycle
    public var history: DownloadAttemptHistory

    public init(lifecycle: DownloadLifecycle, history: DownloadAttemptHistory = .empty) {
        self.lifecycle = lifecycle
        self.history = history
    }
}

public enum DownloadLifecycleTransition: Sendable, Equatable {
    public enum Rejection: Sendable, Equatable { case illegal, replayed }
    case rejected(Rejection)
    case applied(DownloadLifecycleState, [DownloadLifecycleEffect])

    public var state: DownloadLifecycleState? {
        if case .applied(let state, _) = self { return state }
        return nil
    }
    public var effects: [DownloadLifecycleEffect] {
        if case .applied(_, let effects) = self { return effects }
        return []
    }
}

/// The only way lifecycle and history change (P3a.2). Pure: call sites persist the returned
/// state together with its durable effects in one revision, then execute the effects.
public enum DownloadLifecycleReducer {
    public static let maxTruncationStrikes = BackgroundFinalizationResultPolicy.maxConsecutiveTruncationFailures

    public static func reduce(
        _ state: DownloadLifecycleState,
        _ event: DownloadLifecycleEvent,
        facts: DownloadRowFacts
    ) -> DownloadLifecycleTransition {
        var next = state
        let lifecycle = state.lifecycle

        func to(_ new: DownloadLifecycle, _ effects: [DownloadLifecycleEffect] = [])
            -> DownloadLifecycleTransition {
            next.lifecycle = new
            if new != .paused { next.history.pauseCause = nil }
            if new != .failed { next.history.lastFailure = nil }
            if new != .unverified { next.history.unverifiedReason = nil }
            return .applied(next, effects)
        }
        func fail(_ reason: DownloadFailureReason, _ effects: [DownloadLifecycleEffect] = [])
            -> DownloadLifecycleTransition {
            let result = to(.failed, effects)
            guard case .applied(var failed, let fx) = result else { return result }
            failed.history.lastFailure = reason
            return .applied(failed, fx)
        }
        func pause(_ cause: DownloadPauseCause, _ effects: [DownloadLifecycleEffect] = [])
            -> DownloadLifecycleTransition {
            let result = to(.paused, effects)
            guard case .applied(var paused, let fx) = result else { return result }
            paused.history.pauseCause = cause
            if cause != .storage { paused.history.storagePark = nil }
            return .applied(paused, fx)
        }
        let active: Set<DownloadLifecycle> = [.admitted, .serverPrep, .transferring]
        let illegal = DownloadLifecycleTransition.rejected(.illegal)

        switch event {
        case .pause(let cause):
            guard active.contains(lifecycle) || lifecycle == .planned || lifecycle == .paused
                    || lifecycle == .finalizing else { return illegal }
            // A finalizing body is finished: pausing never discards it; finalization resumes.
            if lifecycle == .finalizing { return .applied(next, []) }
            return pause(cause)

        case .retry(let mode):
            switch mode {
            case .convertResume, .prepReattach:
                guard lifecycle == .paused || lifecycle == .failed else { return illegal }
                return to(.serverPrep)
            case .resumeBlob:
                guard lifecycle == .paused || lifecycle == .failed else { return illegal }
                return to(.transferring)
            case .staticCheckpoint, .freshAttempt:
                guard lifecycle == .paused || lifecycle == .failed || lifecycle == .planned
                        || lifecycle == .unverified || lifecycle == .complete else { return illegal }
                next.history.admissionIntent = nil
                next.history.storagePark = nil
                return to(.admitted)
            }

        case .retryRejected(let reason):
            return fail(reason)

        case .admissionGranted:
            guard lifecycle == .planned else { return illegal }
            next.history.admissionIntent = nil
            return to(.admitted)

        case .prepReattached:
            guard lifecycle == .serverPrep || lifecycle == .paused || lifecycle == .failed
                    || lifecycle == .admitted else { return illegal }
            return to(.serverPrep)

        case .prepHandoff:
            guard lifecycle == .serverPrep else { return illegal }
            return to(.admitted)

        case .prepFailed(let reason):
            guard lifecycle == .serverPrep || lifecycle == .admitted || lifecycle == .paused
                    || lifecycle == .failed else { return illegal }
            return fail(reason)

        case .transferStarted, .taskAdopted:
            guard lifecycle == .admitted || lifecycle == .transferring
                    || (event == .taskAdopted && (lifecycle == .paused || lifecycle == .failed)) else {
                return illegal
            }
            return to(.transferring)

        case .transferProgress:
            // B09: progress never promotes a paused, failed or finalizing row.
            guard lifecycle == .admitted || lifecycle == .transferring else { return illegal }
            return to(.transferring)

        case .checkpointAdvanced:
            // Bytes are recorded by the caller's constrained mutator; lifecycle is untouched.
            return .applied(next, [])

        case .transferRebuilding, .resourceChanged:
            guard lifecycle == .admitted || lifecycle == .transferring
                    || lifecycle == .paused else { return illegal }
            if lifecycle == .paused { return .applied(next, []) }
            return to(.transferring)

        case .rebuildExpired:
            guard lifecycle == .transferring || lifecycle == .admitted else { return illegal }
            return pause(.deferredResume)

        case .transferInterrupted(let reason):
            guard active.contains(lifecycle) else { return illegal }
            switch reason {
            case .cancelledBySystem: return pause(.systemInterrupted)
            case .storage:
                next.history.storagePark = DownloadStoragePark(
                    requiredBytes: nil, measuredAtEpochSeconds: Date().timeIntervalSince1970)
                return pause(.storage)
            default: return pause(.deferredResume)
            }

        case .transferFailed(let reason):
            guard !lifecycle.isTerminal || lifecycle == .failed else { return illegal }
            return fail(reason)

        case .backendUnavailable(let cause):
            guard active.contains(lifecycle) || lifecycle == .paused || lifecycle == .failed else {
                return illegal
            }
            return pause(cause)

        case .bodyCaptured, .bodyAtWorking:
            guard lifecycle == .transferring || lifecycle == .admitted
                    || lifecycle == .finalizing else { return illegal }
            return to(.finalizing, event == .bodyAtWorking ? [.requestFinalization] : [])

        case .finalizeOutcome(let id, let outcome, let source):
            guard lifecycle == .finalizing else { return illegal }
            if next.history.truncation?.countedOutcomeIDs.contains(id) == true {
                return .rejected(.replayed)
            }
            switch outcome {
            case .complete:
                next.history.truncation = nil
                return to(.finalizing, [.publish(.complete)])
            case .unverified(let reason):
                return finalizingPublish(&next, reason: .probeMiss(reason))
            case .incompleteBytes:
                return fail(.validation, [.resetBytesToDurableCheckpoint])
            case .emptyFile:
                return fail(.validation, [.deleteWorkingBody])
            case .truncated:
                var truncation = next.history.truncation
                if truncation == nil || truncation!.sourceKey.provenDifferent(from: source) {
                    truncation = DownloadTruncationHistory(strikes: 0, sourceKey: source)
                }
                truncation!.strikes += 1
                truncation!.countedOutcomeIDs = Array(
                    (truncation!.countedOutcomeIDs + [id])
                        .suffix(DownloadTruncationHistory.rememberedOutcomeLimit))
                next.history.truncation = truncation
                if truncation!.strikes >= maxTruncationStrikes {
                    return finalizingPublish(&next, reason: .truncatedRepeated)
                }
                return fail(.validation, [.deleteWorkingBody])
            }

        case .publishedBodyRevalidated(_, let outcome):
            guard lifecycle == .unverified || lifecycle == .complete else { return illegal }
            switch outcome {
            case .complete:
                next.history.truncation = nil
                return to(.complete)
            case .unverified(let reason):
                let result = to(.unverified)
                guard case .applied(var kept, let fx) = result else { return result }
                kept.history.unverifiedReason = .probeMiss(reason)
                return .applied(kept, fx)
            case .truncated:
                // B54: a published body is never failed or deleted for truncation.
                let result = to(.unverified)
                guard case .applied(var kept, let fx) = result else { return result }
                kept.history.unverifiedReason = .truncatedRepeated
                return .applied(kept, fx)
            case .incompleteBytes:
                return fail(.validation)
            case .emptyFile:
                return fail(.validation, [.deletePublishedBody])
            }

        case .promotionCommitted(let terminal):
            guard lifecycle == .finalizing, terminal == .complete || terminal == .unverified else {
                return illegal
            }
            let reason = next.history.unverifiedReason
            let result = to(terminal)
            guard case .applied(var done, let fx) = result else { return result }
            if terminal == .unverified { done.history.unverifiedReason = reason }
            return .applied(done, fx)

        case .promotionAbandoned:
            guard lifecycle == .finalizing else { return illegal }
            return fail(.internalError)

        case .promotionRecovered(let terminal):
            guard terminal == .complete || terminal == .unverified else { return illegal }
            return to(terminal)

        case .localPlaybackProgressed:
            guard lifecycle == .unverified else { return illegal }
            return to(.complete)

        case .sizeAuditFailed:
            guard lifecycle == .complete || lifecycle == .unverified else { return illegal }
            return fail(.validation)

        case .stallDetected:
            guard lifecycle == .transferring else { return illegal }
            return fail(.stalled)

        case .relaunchObserved:
            return relaunch(next, facts: facts)
        }
    }

    /// The finalize outcome publishes through the promotion recipe; lifecycle stays finalizing
    /// until `promotionCommitted` (R2-2).
    private static func finalizingPublish(
        _ next: inout DownloadLifecycleState,
        reason: DownloadUnverifiedReason
    ) -> DownloadLifecycleTransition {
        next.history.unverifiedReason = reason
        return .applied(next, [.publish(.unverified)])
    }

    /// Relaunch recovery (Appendix C.5), in today's reconcile order.
    private static func relaunch(
        _ state: DownloadLifecycleState,
        facts: DownloadRowFacts
    ) -> DownloadLifecycleTransition {
        var next = state
        func set(_ lifecycle: DownloadLifecycle, _ effects: [DownloadLifecycleEffect] = [],
                 pauseCause: DownloadPauseCause? = nil, failure: DownloadFailureReason? = nil)
            -> DownloadLifecycleTransition {
            next.lifecycle = lifecycle
            next.history.pauseCause = lifecycle == .paused ? (pauseCause ?? next.history.pauseCause) : nil
            if lifecycle == .failed { next.history.lastFailure = failure ?? next.history.lastFailure }
            return .applied(next, effects)
        }
        guard facts.snapshotEligible, !facts.pendingArtifactHead, !facts.deletionPending else {
            return .applied(next, [])
        }
        switch state.lifecycle {
        case .planned:
            return .applied(next, [])
        case .finalizing:
            switch facts.body {
            case .captured, .workingComplete: return .applied(next, [.requestFinalization])
            case .published: return .applied(next, [.requestFinalization])
            case .none: return set(.failed, failure: .internalError)
            }
        case .complete, .unverified:
            return facts.body == .published ? .applied(next, []) : set(.failed, failure: .internalError)
        case .failed:
            return .applied(next, [])
        case .admitted, .serverPrep, .transferring, .paused:
            if facts.route == .plexPrep, !facts.liveTask, state.lifecycle != .paused {
                return set(.serverPrep, [.resetBytesToZero])
            }
            if facts.liveTask, facts.route != .plexPrep {
                return set(.transferring)
            }
            if case .embyConvert(let hasJob) = facts.route, hasJob,
               state.lifecycle == .serverPrep || state.lifecycle == .paused {
                return set(state.lifecycle == .paused ? .paused : .serverPrep,
                           pauseCause: .deferredResume)
            }
            if facts.route == .plexPrep, state.lifecycle == .paused {
                return set(.paused, pauseCause: next.history.pauseCause ?? .deferredResume)
            }
            // Today's table: a durable static partial or any URLSession resume blob stays paused.
            if facts.checkpoint == .resumeBlob
                || (facts.hasResumableCheckpoint && facts.route == .staticRange) {
                return set(.paused, [.resetBytesToDurableCheckpoint],
                           pauseCause: next.history.pauseCause ?? .deferredResume)
            }
            return set(.failed, [.deleteWorkingBody, .clearResumeBlob], failure: .network)
        }
    }
}
