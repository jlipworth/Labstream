import Foundation

/// Pure entry-gate decisions for `DownloadManager.retry` before backend-specific retry work begins.
///
/// The app layer still owns store/session mutations and backend calls. This policy pins the small
/// predicates that decide whether a tap is a manual queue-paused static resume, whether a paused row
/// should resume persisted URLSession data, and whether server-prep rows should reattach instead of
/// starting a new backend download.
public enum DownloadRetryPreparationPolicy {
    public static func isManualStaticResumeWhileQueuePaused(isQueuePaused: Bool,
                                                            isStaticRangeRecord: Bool,
                                                            status: DownloadStatus) -> Bool {
        isQueuePaused
            && isStaticRangeRecord
            && (status == .paused || status == .failed || status == .queued)
    }

    public static func shouldResumePausedEmbyConvert(status: DownloadStatus,
                                                     resumeMode: DownloadResumeMode?,
                                                     isEmbyRecord: Bool,
                                                     hasEmbyConvertJobID: Bool) -> Bool {
        status == .paused
            && resumeMode == .serverPrepThenStatic
            && isEmbyRecord
            && hasEmbyConvertJobID
    }

    public static func shouldResumePersistedURLSessionData(status: DownloadStatus,
                                                           supportsPersistedResumeData: Bool,
                                                           hasResumeData: Bool) -> Bool {
        status == .paused && supportsPersistedResumeData && hasResumeData
    }

    /// Which transfer lane a persisted URLSession resume blob must be resumed on. Range-checkpoint
    /// rows (static byte-range, and the static half of server-prep) accumulate a Range segment's
    /// body in the blob's task; registering that task in the opaque lane would move its
    /// partial-body temp as a whole file at completion and corrupt the download.
    public enum PersistedResumeLane: Sendable, Equatable {
        case rangeCheckpoint
        case opaque
    }

    public static func persistedResumeDataLane(resumeMode: DownloadResumeMode?) -> PersistedResumeLane {
        switch resumeMode {
        case .staticByteRange, .serverPrepThenStatic:
            return .rangeCheckpoint
        case .liveForwardOnly, nil:
            return .opaque
        }
    }

    public static func shouldResumePausedPlexServerPrep(status: DownloadStatus,
                                                        resumeMode: DownloadResumeMode?,
                                                        isJellyfinRecord: Bool,
                                                        isEmbyRecord: Bool,
                                                        optimizeTargetName: String?,
                                                        hasIncompleteStaticPartial: Bool) -> Bool {
        guard status == .paused,
              resumeMode == .serverPrepThenStatic,
              !isJellyfinRecord,
              !isEmbyRecord,
              let optimizeTargetName,
              !optimizeTargetName.isEmpty,
              !hasIncompleteStaticPartial else {
            return false
        }
        return true
    }

    public static func attemptCanContinue(isRetrying: Bool,
                                          rowIsPresent: Bool,
                                          rowStatus: DownloadStatus?) -> Bool {
        isRetrying && rowIsPresent && rowStatus != .paused
    }
}
