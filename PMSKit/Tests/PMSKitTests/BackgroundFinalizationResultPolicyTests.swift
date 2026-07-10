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

    @Test("Repeated truncation failures park the row unverified instead of re-deleting forever")
    func truncationLoopGuard() {
        // First and second failure: normal fail+delete (the file is genuinely truncated and a
        // retry may succeed against a healthier server/session).
        for failures in [0, 1] {
            let result = BackgroundFinalizationResultPolicy.result(
                for: .truncated(actualDurationMs: 6_480_000, expectedDurationMs: 7_200_000),
                consecutiveTruncationFailures: failures)
            #expect(result.status == .failed)
            #expect(result.shouldDeleteFile)
        }
        // At the budget: park `.unverified`, preserve the file, and say why — no more automatic
        // from-zero re-transcodes of a long movie.
        let parked = BackgroundFinalizationResultPolicy.result(
            for: .truncated(actualDurationMs: 6_480_000, expectedDurationMs: 7_200_000),
            consecutiveTruncationFailures: BackgroundFinalizationResultPolicy.maxConsecutiveTruncationFailures)
        #expect(parked == BackgroundFinalizationResult(
            status: .unverified,
            resultLabel: "unverified_truncated_parked",
            shouldDeleteFile: false,
            validationFailureReason: "truncated_repeated",
            userFacingErrorMessage: "Download keeps ending early (6480s of 7200s). Kept as-is; delete and re-download to retry."
        ))
        // Past the budget (revalidation re-derives `.truncated`): stays parked, still preserved.
        let stillParked = BackgroundFinalizationResultPolicy.result(
            for: .truncated(actualDurationMs: 6_480_000, expectedDurationMs: 7_200_000),
            consecutiveTruncationFailures: 5)
        #expect(stillParked.status == .unverified)
        #expect(!stillParked.shouldDeleteFile)
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
