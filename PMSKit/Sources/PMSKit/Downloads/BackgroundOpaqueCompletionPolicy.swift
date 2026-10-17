import Foundation

public enum BackgroundOpaqueCompletionDisposition: Sendable, Equatable {
    case cancelled
    case pauseWithResumeData
    case failNonResumableStream
    /// B09: the OS cancelled a forward-only task. Fail retryable with a real reason rather than
    /// treating it as a user cancel that leaves the row `.downloading` with no task.
    case failSystemInterrupted
    /// B26: the disk filled (`DownloadDiskSpacePolicy.isOutOfSpace`). Fail with the storage-full
    /// reason the range lane uses; resuming into the same full disk only fails again.
    case failStorageFull
    case fail
}

/// Pure terminal error mapping for the opaque URLSession download lane.
///
/// Transient retry is attempted before this policy is consulted. Once the task is not going to be
/// retried immediately, resume data is still meaningful for persisted-resume-safe static lanes:
/// keep the row paused and store the blob. Forward-only transcode/remux streams can also receive a
/// resume blob from URLSession, but resuming them by byte offset is unsafe, so they fail with a
/// restart-required message instead of silently attempting a corrupt 200/416-prone resume.
public enum BackgroundOpaqueCompletionPolicy {
    public static func disposition(errorCode: Int,
                                   hasResumeData: Bool,
                                   supportsPersistedResumeData: Bool,
                                   isSystemInitiatedCancel: Bool = false,
                                   isOutOfSpace: Bool = false) -> BackgroundOpaqueCompletionDisposition {
        if isOutOfSpace, errorCode != NSURLErrorCancelled { return .failStorageFull }
        if errorCode == NSURLErrorCancelled {
            guard isSystemInitiatedCancel else { return .cancelled }
            return hasResumeData && supportsPersistedResumeData
                ? .pauseWithResumeData : .failSystemInterrupted
        }
        guard hasResumeData else { return .fail }
        return supportsPersistedResumeData ? .pauseWithResumeData : .failNonResumableStream
    }
}

/// B09: distinguishes an OS-initiated background cancellation from an app-initiated one. The
/// system stamps `NSURLErrorBackgroundTaskCancelledReasonKey` on the -999 it delivers when it
/// cancels background tasks itself; app pause/cancel/supersede never carries it.
public enum BackgroundSystemCancellationPolicy {
    public static func isSystemInitiatedCancel(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
            && nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil
    }
}
