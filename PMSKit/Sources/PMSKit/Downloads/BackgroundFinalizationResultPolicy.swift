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
                resultLabel: unverifiedResultLabel(reason: reason),
                shouldDeleteFile: false,
                validationFailureReason: reason,
                userFacingErrorMessage: nil
            )
        }
    }

    /// Bounded `unverified_*` label (audit lens 8, B-1). The AVFoundation probe reason is
    /// free-form; a dynamic `unverified_\(reason)` could reach the redactor's 24-char bare-token
    /// threshold and be blanked to "[token]" in the jsonl. Keep the LABEL under that limit —
    /// sanitized and capped — while the full reason still travels in `validationFailureReason`.
    public static func unverifiedResultLabel(reason: String) -> String {
        let sanitized = DiagnosticRedactor.fieldKey(reason)
        let capped = String(sanitized.prefix(12))
            .trimmingCharacters(in: CharacterSet(charactersIn: "_.:-"))
        return "unverified_" + (capped.isEmpty || capped == "field" ? "probe" : capped)
    }
}
