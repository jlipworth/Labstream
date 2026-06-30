import Foundation

public enum BackgroundOpaqueCompletionDisposition: Sendable, Equatable {
    case cancelled
    case pauseWithResumeData
    case failNonResumableStream
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
                                   supportsPersistedResumeData: Bool) -> BackgroundOpaqueCompletionDisposition {
        guard errorCode != NSURLErrorCancelled else { return .cancelled }
        guard hasResumeData else { return .fail }
        return supportsPersistedResumeData ? .pauseWithResumeData : .failNonResumableStream
    }
}
