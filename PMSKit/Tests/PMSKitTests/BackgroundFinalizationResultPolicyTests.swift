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
