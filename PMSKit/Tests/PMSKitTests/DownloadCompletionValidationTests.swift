import Testing
import Foundation
@testable import PMSKit

// GH #135 Stage 2: characterization of the unified download completion-validation rules. These pin
// the behavior the opaque (`didFinishDownloadingTo`) pipeline already shipped, BEFORE the range
// (`didCompleteWithError`) pipeline was funneled through the same decisions — so the refactor that
// makes both paths share this logic is verifiable.

@Suite("Download completion validation")
struct DownloadCompletionValidationTests {

    // MARK: HEVC fixup container gate (#127: gate on container, not lane)

    @Test func hevcFixupRunsForMP4Family() {
        for ext in ["mp4", "m4v", "mov", "MP4", "MOV"] {
            #expect(DownloadCompletionValidation.needsHEVCTagFixup(pathExtension: ext), "expected fixup for .\(ext)")
        }
    }

    @Test func hevcFixupSkippedForNonMP4Family() {
        for ext in ["mkv", "ts", "webm", "avi", ""] {
            #expect(!DownloadCompletionValidation.needsHEVCTagFixup(pathExtension: ext), "expected no fixup for .\(ext)")
        }
    }

    // MARK: Error-page guard (status + MIME)

    @Test func errorPageReasonAcceptsRealMedia() {
        #expect(DownloadCompletionValidation.errorPageReason(httpStatusCode: 200, mimeType: "video/mp4") == nil)
        #expect(DownloadCompletionValidation.errorPageReason(httpStatusCode: 206, mimeType: "video/x-matroska") == nil)
        #expect(DownloadCompletionValidation.errorPageReason(httpStatusCode: nil, mimeType: nil) == nil)
    }

    @Test func errorPageReasonRejectsNon2xx() {
        #expect(DownloadCompletionValidation.errorPageReason(httpStatusCode: 400, mimeType: "video/mp4") == "Server returned HTTP 400.")
        #expect(DownloadCompletionValidation.errorPageReason(httpStatusCode: 404, mimeType: nil) == "Server returned HTTP 404.")
        #expect(DownloadCompletionValidation.errorPageReason(httpStatusCode: 500, mimeType: "text/html") == "Server returned HTTP 500.")
    }

    @Test func errorPageReasonRejectsTextualBodiesOn2xx() {
        #expect(DownloadCompletionValidation.errorPageReason(httpStatusCode: 200, mimeType: "text/html") == "Server returned a text/html page, not a video.")
        #expect(DownloadCompletionValidation.errorPageReason(httpStatusCode: 200, mimeType: "application/json") == "Server returned a application/json page, not a video.")
        #expect(DownloadCompletionValidation.errorPageReason(httpStatusCode: 200, mimeType: "APPLICATION/XML") == "Server returned a application/xml page, not a video.")
    }

    // MARK: Truncation rule (0.80 of expected source duration)

    @Test func truncationNeedsBothDurations() {
        #expect(!DownloadCompletionValidation.isTruncated(expectedDurationMs: nil, actualDurationMs: 1000))
        #expect(!DownloadCompletionValidation.isTruncated(expectedDurationMs: 10_000, actualDurationMs: nil))
        #expect(!DownloadCompletionValidation.isTruncated(expectedDurationMs: 0, actualDurationMs: 0))
    }

    @Test func truncationThresholdEdges() {
        // expected 10_000ms → cutoff is 8_000ms (strictly below = truncated).
        #expect(DownloadCompletionValidation.isTruncated(expectedDurationMs: 10_000, actualDurationMs: 7_999))
        #expect(!DownloadCompletionValidation.isTruncated(expectedDurationMs: 10_000, actualDurationMs: 8_000))
        #expect(!DownloadCompletionValidation.isTruncated(expectedDurationMs: 10_000, actualDurationMs: 10_000))
    }

    @Test func shortClipComparedAgainstItsOwnDurationIsNotTruncated() {
        // A legitimate 30s trailer that decodes to ~30s is complete, not truncated.
        #expect(!DownloadCompletionValidation.isTruncated(expectedDurationMs: 30_000, actualDurationMs: 30_000))
    }

    // MARK: Terminal outcome

    @Test func outcomePlayedAndFullIsComplete() {
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: 10_000, actualDurationMs: 10_000) == .complete)
        // Unknown durations can't prove truncation → complete.
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: nil, actualDurationMs: nil) == .complete)
    }

    @Test func outcomeZeroBytesIsFailedEmptyEvenWhenProbeMisses() {
        #expect(DownloadCompletionValidation.outcome(played: false, probeReason: "item_failed",
                                                     expectedDurationMs: 10_000, actualDurationMs: nil,
                                                     downloadedBytes: 0) == .emptyFile)
    }

    @Test func outcomePlayedButShortIsTruncated() {
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: 10_000, actualDurationMs: 1_000)
                == .truncated(actualDurationMs: 1_000, expectedDurationMs: 10_000))
    }

    @Test func outcomeProbeMissIsUnverifiedNotFailed() {
        // The #98 leniency — and the H3 fix that makes the RANGE path behave like the opaque path:
        // an inconclusive probe keeps the file (`.unverified`), it is never condemned to `.failed`.
        #expect(DownloadCompletionValidation.outcome(played: false, probeReason: "timeout_not_ready",
                                                     expectedDurationMs: 10_000, actualDurationMs: nil)
                == .unverified(reason: "timeout_not_ready"))
        // A not-played file is never reported truncated even if a (partial) duration was decoded.
        #expect(DownloadCompletionValidation.outcome(played: false, probeReason: "item_failed",
                                                     expectedDurationMs: 10_000, actualDurationMs: 500)
                == .unverified(reason: "item_failed"))
    }
}
