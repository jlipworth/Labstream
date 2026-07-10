import Foundation

public struct BackgroundFinalizationResult: Sendable, Equatable {
    public let status: DownloadStatus
    public let resultLabel: String
    public let shouldDeleteFile: Bool
    public let validationFailureReason: String?
    public let userFacingErrorMessage: String?

    public init(status: DownloadStatus,
                resultLabel: String,
                shouldDeleteFile: Bool,
                validationFailureReason: String?,
                userFacingErrorMessage: String?) {
        self.status = status
        self.resultLabel = resultLabel
        self.shouldDeleteFile = shouldDeleteFile
        self.validationFailureReason = validationFailureReason
        self.userFacingErrorMessage = userFacingErrorMessage
    }
}

/// Pure mapping from a completed transfer validation outcome to row-state side-effect intent.
///
/// `BackgroundDownloadSession` still performs the filesystem, store, diagnostics, and user-error
/// side effects; this policy pins the semantic contract shared by opaque and static-range
/// finalization paths.
public enum BackgroundFinalizationResultPolicy {
    /// JF-F2 loop guard: consecutive truncation failures for the SAME row before it is parked
    /// instead of deleted. Each truncation failure deletes the file and forces a full re-transcode
    /// from zero, so an environment that reliably kills the encoder near the end (idle-kill,
    /// proxy timeout) would otherwise re-render a long movie forever. After the budget the row is
    /// preserved `.unverified` — playable to its truncation point, sticky across revalidation
    /// (the re-probe re-derives `.truncated` and lands back here), recoverable by delete+re-add.
    public static let maxConsecutiveTruncationFailures = 2

    public static func result(
        for outcome: DownloadCompletionValidation.CompletionOutcome,
        consecutiveTruncationFailures: Int = 0
    ) -> BackgroundFinalizationResult {
        switch outcome {
        case .complete:
            return BackgroundFinalizationResult(
                status: .complete,
                resultLabel: "complete",
                shouldDeleteFile: false,
                validationFailureReason: nil,
                userFacingErrorMessage: nil
            )
        case .emptyFile:
            return BackgroundFinalizationResult(
                status: .failed,
                resultLabel: "failed_empty",
                shouldDeleteFile: true,
                validationFailureReason: "empty_file",
                userFacingErrorMessage: "Downloaded file is empty."
            )
        case .incompleteBytes(let actualBytes, let expectedBytes):
            // NEVER delete: the partial is a valid resume checkpoint for the static range lane;
            // retry continues from the durable file size instead of re-downloading from 0%.
            return BackgroundFinalizationResult(
                status: .failed,
                resultLabel: "failed_incomplete_bytes",
                shouldDeleteFile: false,
                validationFailureReason: "incomplete_bytes",
                userFacingErrorMessage: "Download is incomplete (\(actualBytes / 1_000_000) of \(expectedBytes / 1_000_000) MB). Retry to continue."
            )
        case .truncated(let actualDurationMs, let expectedDurationMs):
            if consecutiveTruncationFailures >= maxConsecutiveTruncationFailures {
                return BackgroundFinalizationResult(
                    status: .unverified,
                    resultLabel: "unverified_truncated_parked",
                    shouldDeleteFile: false,
                    validationFailureReason: "truncated_repeated",
                    userFacingErrorMessage: "Download keeps ending early (\(actualDurationMs / 1000)s of \(expectedDurationMs / 1000)s). Kept as-is; delete and re-download to retry."
                )
            }
            return BackgroundFinalizationResult(
                status: .failed,
                resultLabel: "failed_truncated",
                shouldDeleteFile: true,
                validationFailureReason: "truncated_duration",
                userFacingErrorMessage: "Downloaded file is truncated (\(actualDurationMs / 1000)s of \(expectedDurationMs / 1000)s)."
            )
        case .unverified(let reason):
            return BackgroundFinalizationResult(
                status: .unverified,
                resultLabel: "unverified_\(reason)",
                shouldDeleteFile: false,
                validationFailureReason: reason,
                userFacingErrorMessage: nil
            )
        }
    }
}
