import Testing
@testable import PMSKit

@Suite("Background finalization result policy")
struct BackgroundFinalizationResultPolicyTests {

    @Test("Each completion outcome maps to its full finalization result", arguments: [
        // Validated transfers mark complete and preserve the file.
        (.complete, BackgroundFinalizationResult(
            status: .complete,
            resultLabel: "complete",
            shouldDeleteFile: false,
            validationFailureReason: nil,
            userFacingErrorMessage: nil
        )),
        // Empty transfers fail, delete the placeholder file, and stay retryable.
        (.emptyFile, BackgroundFinalizationResult(
            status: .failed,
            resultLabel: "failed_empty",
            shouldDeleteFile: true,
            validationFailureReason: "empty_file",
            userFacingErrorMessage: "Downloaded file is empty."
        )),
        // Byte-incomplete static transfers fail but PRESERVE the resume checkpoint.
        (.incompleteBytes(actualBytes: 67_108_864, expectedBytes: 5_857_580_532), BackgroundFinalizationResult(
            status: .failed,
            resultLabel: "failed_incomplete_bytes",
            shouldDeleteFile: false,
            validationFailureReason: "incomplete_bytes",
            userFacingErrorMessage: "Download is incomplete (67 of 5857 MB). Retry to continue."
        )),
        // Truncated transfers fail, delete the file, and surface duration context.
        (.truncated(actualDurationMs: 12_000, expectedDurationMs: 60_000), BackgroundFinalizationResult(
            status: .failed,
            resultLabel: "failed_truncated",
            shouldDeleteFile: true,
            validationFailureReason: "truncated_duration",
            userFacingErrorMessage: "Downloaded file is truncated (12s of 60s)."
        )),
        // Unverified transfers preserve bytes and stay playable.
        // B-1: the result LABEL is bounded below the redactor's 24-char bare-token threshold;
        // the untruncated reason still travels in `validationFailureReason`.
        (.unverified(reason: "timeout_not_ready"), BackgroundFinalizationResult(
            status: .unverified,
            resultLabel: "unverified_timeout_not",
            shouldDeleteFile: false,
            validationFailureReason: "timeout_not_ready",
            userFacingErrorMessage: nil
        )),
    ] as [(DownloadCompletionValidation.CompletionOutcome, BackgroundFinalizationResult)])
    func outcomeResult(outcome: DownloadCompletionValidation.CompletionOutcome,
                       expected: BackgroundFinalizationResult) {
        #expect(BackgroundFinalizationResultPolicy.result(for: outcome) == expected)
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

    @Test("Revalidating a published body never fails or deletes it for truncation (B54)")
    func revalidationKeepsPublishedTruncatedBody() {
        // After a relaunch the in-memory strike count restarts at 1; the parked, published body
        // must still survive its re-probe.
        let result = BackgroundFinalizationResultPolicy.result(
            for: .truncated(actualDurationMs: 6_480_000, expectedDurationMs: 7_200_000),
            consecutiveTruncationFailures: 1,
            revalidatingPublishedFile: true)
        #expect(result.status == .unverified)
        #expect(!result.shouldDeleteFile)
        // A fresh transfer still fails and deletes on its first strike.
        let fresh = BackgroundFinalizationResultPolicy.result(
            for: .truncated(actualDurationMs: 6_480_000, expectedDurationMs: 7_200_000),
            consecutiveTruncationFailures: 1)
        #expect(fresh.status == .failed)
        #expect(fresh.shouldDeleteFile)
    }
}
