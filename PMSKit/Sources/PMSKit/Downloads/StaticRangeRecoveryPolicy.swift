import Foundation

/// Pure recovery decisions for static byte-range download rows.
///
/// The app layer still owns URLSession, backend authentication, durable checkpoint IO, diagnostics,
/// and user-facing errors. This policy captures the small but load-bearing state-machine rules so
/// relaunch/retry recovery can be tested without app state or simulators.
public enum StaticRangeRecoveryPolicy {

    public enum FinalizeDecision: Equatable, Sendable {
        /// Terminal/non-static/not-yet-complete rows should not enter finalization.
        case ignore
        /// A finalization is already in progress for this row; callers should treat recovery as
        /// handled and avoid re-entering the finalize path.
        case alreadyFinalizing
        /// The durable partial appears complete enough to hand to final validation.
        case start(checkpointBytes: Int)
    }

    public enum DeferredResumeDisposition: Equatable, Sendable {
        /// Keep an automatic resume intent durable as `.queued`; used when a system/adopted
        /// continuation needs backend auth before it can rebuild the next request.
        case queuedActiveIntent
        /// The row has a durable checkpoint and should wait as a normal paused resumable download.
        case pausedAtCheckpoint
        /// No durable bytes survived; keep the visible row retryable but do not pretend it can
        /// resume from a checkpoint.
        case failedNoCheckpoint
    }

    /// Whether a row's transfer mode is the app-managed static byte-range lane.
    public static func isStaticRangeRecord(_ record: DownloadRecord) -> Bool {
        let backend = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
        let lane = record.metadata?.resolvedDownloadLane() ?? .original
        let mode = record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey)
            ?? DownloadResumeMode.resolved(backend: backend, lane: lane)
        return mode == .staticByteRange
    }

    /// Decide if a persisted static-range row should be handed to final-file validation.
    public static func finalizeDecision(for record: DownloadRecord,
                                        checkpointBytes: Int,
                                        isAlreadyFinalizing: Bool) -> FinalizeDecision {
        if record.status == .complete || record.status == .unverified || record.status == .failed {
            return .ignore
        }
        guard isStaticRangeRecord(record),
              record.progress.isFinite,
              record.progress >= 1.0,
              checkpointBytes > 0 else {
            return .ignore
        }
        if isAlreadyFinalizing { return .alreadyFinalizing }
        return .start(checkpointBytes: checkpointBytes)
    }

    /// Decide what visible state a static-range row should hold while backend/auth state is missing.
    public static func deferredResumeDisposition(checkpointBytes: Int,
                                                 preserveActiveIntent: Bool) -> DeferredResumeDisposition {
        if preserveActiveIntent { return .queuedActiveIntent }
        if checkpointBytes > 0 { return .pausedAtCheckpoint }
        return .failedNoCheckpoint
    }

    /// Queue pause suppresses automatic resume unless the user explicitly resumed this row while
    /// the global queue remains paused.
    public static func shouldWaitForManualResume(isQueuePaused: Bool,
                                                 wasManuallyResumedWhileQueuePaused: Bool) -> Bool {
        isQueuePaused && !wasManuallyResumedWhileQueuePaused
    }

    /// Before backend retry dispatch, static paused rows must become inactive so async backend
    /// guards do not interpret the user's resume tap as a cancellation. This includes rows with no
    /// durable bytes yet: they still need a clean byte-0 retry path.
    public static func shouldMarkPausedRowInactiveBeforeBackendRetry(_ record: DownloadRecord) -> Bool {
        record.status == .paused && isStaticRangeRecord(record)
    }

    /// A queued/downloading system-resume intent is not a live URLSession task once recovery has
    /// decided to rebuild via the backend path. Drop it to an inactive status before retry dispatch
    /// so duplicate-active guards do not no-op the replacement task.
    public static func shouldMarkSystemResumeInactiveBeforeRetry(_ record: DownloadRecord) -> Bool {
        (record.status == .queued || record.status == .downloading) && isStaticRangeRecord(record)
    }

    /// Restart counters should survive adopted relaunch restarts that did not append forward
    /// progress, otherwise validator/offset livelock bounds can be reset by each rebuilt request.
    public static func shouldPreserveRangeRestartCounters(reason: String) -> Bool {
        reason == "validatorChanged" || reason == "adoptedChunkFailed"
    }
}
