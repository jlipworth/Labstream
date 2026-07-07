import Testing
@testable import PMSKit

@Suite("Background finalization result policy")
struct BackgroundFinalizationResultPolicyTests {

    @Test("Validated transfers mark complete and preserve the file")
    func completeResult() {
        #expect(BackgroundFinalizationResultPolicy.result(for: .complete) == BackgroundFinalizationResult(
            status: .complete,
            resultLabel: "complete",
            shouldDeleteFile: false,
            validationFailureReason: nil,
            userFacingErrorMessage: nil
        ))
    }

    @Test("Empty transfers fail, delete the placeholder file, and stay retryable")
    func emptyFileResult() {
        #expect(BackgroundFinalizationResultPolicy.result(for: .emptyFile) == BackgroundFinalizationResult(
            status: .failed,
            resultLabel: "failed_empty",
            shouldDeleteFile: true,
            validationFailureReason: "empty_file",
            userFacingErrorMessage: "Downloaded file is empty."
        ))
    }

    @Test("Byte-incomplete static transfers fail but PRESERVE the resume checkpoint")
    func incompleteBytesResult() {
        #expect(BackgroundFinalizationResultPolicy.result(for: .incompleteBytes(
            actualBytes: 67_108_864, expectedBytes: 5_857_580_532
        )) == BackgroundFinalizationResult(
            status: .failed,
            resultLabel: "failed_incomplete_bytes",
            shouldDeleteFile: false,
            validationFailureReason: "incomplete_bytes",
            userFacingErrorMessage: "Download is incomplete (67 of 5857 MB). Retry to continue."
        ))
    }

    @Test("Truncated transfers fail, delete the file, and surface duration context")
    func truncatedResult() {
        #expect(BackgroundFinalizationResultPolicy.result(
            for: .truncated(actualDurationMs: 12_000, expectedDurationMs: 60_000)
        ) == BackgroundFinalizationResult(
            status: .failed,
            resultLabel: "failed_truncated",
            shouldDeleteFile: true,
            validationFailureReason: "truncated_duration",
            userFacingErrorMessage: "Downloaded file is truncated (12s of 60s)."
        ))
    }

    @Test("Unverified transfers preserve bytes and stay playable")
    func unverifiedResult() {
        #expect(BackgroundFinalizationResultPolicy.result(
            for: .unverified(reason: "timeout_not_ready")
        ) == BackgroundFinalizationResult(
            status: .unverified,
            resultLabel: "unverified_timeout_not_ready",
            shouldDeleteFile: false,
            validationFailureReason: "timeout_not_ready",
            userFacingErrorMessage: nil
        ))
    }
}
