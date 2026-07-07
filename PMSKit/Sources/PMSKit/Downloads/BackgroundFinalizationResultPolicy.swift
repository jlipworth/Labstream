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
    public static func result(
        for outcome: DownloadCompletionValidation.CompletionOutcome
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
        case .truncated(let actualDurationMs, let expectedDurationMs):
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
