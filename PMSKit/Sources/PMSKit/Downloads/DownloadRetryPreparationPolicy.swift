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
