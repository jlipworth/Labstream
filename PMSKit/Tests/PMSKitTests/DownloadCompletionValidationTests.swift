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

    // MARK: Byte-completeness (headset 416 evidence: a truncated legacy bounded body was
    // finalized `.complete` because the moov-led MP4 passed the probe with its full metadata
    // duration; a trailing-moov sibling probe-missed into a stuck `.unverified` loop instead)

    @Test func outcomeShortStaticBytesIsIncompleteEvenWhenProbePasses() {
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: 7_200_000, actualDurationMs: 7_200_000,
                                                     downloadedBytes: 67_108_864,
                                                     expectedExactBytes: 5_857_580_532)
                == .incompleteBytes(actualBytes: 67_108_864, expectedBytes: 5_857_580_532))
    }

    @Test func outcomeShortStaticBytesIsIncompleteNotUnverifiedWhenProbeMisses() {
        #expect(DownloadCompletionValidation.outcome(played: false, probeReason: "item_failed",
                                                     expectedDurationMs: nil, actualDurationMs: nil,
                                                     downloadedBytes: 1_543_503_872,
                                                     expectedExactBytes: 2_400_000_000)
                == .incompleteBytes(actualBytes: 1_543_503_872, expectedBytes: 2_400_000_000))
    }

    @Test func outcomeExactStaticBytesIsNotIncomplete() {
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: nil, actualDurationMs: nil,
                                                     downloadedBytes: 2_400_000_000,
                                                     expectedExactBytes: 2_400_000_000) == .complete)
    }

    @Test func outcomeWithoutExactExpectedBytesNeverReportsIncomplete() {
        // Transcode lanes only have byte ESTIMATES and must pass nil — a finished transcode is
        // legitimately smaller than its source part.
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: nil, actualDurationMs: nil,
                                                     downloadedBytes: 100,
                                                     expectedExactBytes: nil) == .complete)
    }

    @Test func outcomeZeroBytesStaysEmptyNotIncomplete() {
        #expect(DownloadCompletionValidation.outcome(played: false, probeReason: "item_failed",
                                                     expectedDurationMs: nil, actualDurationMs: nil,
                                                     downloadedBytes: 0,
                                                     expectedExactBytes: 2_400_000_000) == .emptyFile)
    }

    @Test func isIncompleteRequiresBothSidesKnownAndPositive() {
        #expect(DownloadCompletionValidation.isIncomplete(downloadedBytes: 10, expectedExactBytes: 20))
        #expect(!DownloadCompletionValidation.isIncomplete(downloadedBytes: 20, expectedExactBytes: 20))
        #expect(!DownloadCompletionValidation.isIncomplete(downloadedBytes: 30, expectedExactBytes: 20))
        #expect(!DownloadCompletionValidation.isIncomplete(downloadedBytes: nil, expectedExactBytes: 20))
        #expect(!DownloadCompletionValidation.isIncomplete(downloadedBytes: 10, expectedExactBytes: nil))
        #expect(!DownloadCompletionValidation.isIncomplete(downloadedBytes: 10, expectedExactBytes: 0))
        #expect(!DownloadCompletionValidation.isIncomplete(downloadedBytes: 0, expectedExactBytes: 20))
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

    // MARK: JF-F2 — forward-only lanes use the tightened truncation validation

    @Test func forwardOnlyTruncationThresholdEdges() {
        // expected 10_000ms → forward-only cutoff is 9_500ms (strictly below = truncated).
        let threshold = DownloadCompletionValidation.forwardOnlyTruncationThreshold
        #expect(DownloadCompletionValidation.isTruncated(expectedDurationMs: 10_000, actualDurationMs: 9_499,
                                                         threshold: threshold))
        #expect(!DownloadCompletionValidation.isTruncated(expectedDurationMs: 10_000, actualDurationMs: 9_500,
                                                          threshold: threshold))
        // The default lane keeps the looser 0.80 cutoff.
        #expect(!DownloadCompletionValidation.isTruncated(expectedDurationMs: 10_000, actualDurationMs: 9_499))
    }

    @Test func outcomeForwardOnlyCatchesCleanEncoderKillAtNinetyPercent() {
        // A cleanly killed encoder stream at 90% used to finalize `.complete` (0.80 threshold).
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: 7_200_000, actualDurationMs: 6_480_000,
                                                     forwardOnly: true)
                == .truncated(actualDurationMs: 6_480_000, expectedDurationMs: 7_200_000))
        // The same durations on a non-forward-only lane keep today's outcome.
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: 7_200_000, actualDurationMs: 6_480_000)
                == .complete)
        // Container/metadata slop within 5% is still complete on the forward-only lane.
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: 7_200_000, actualDurationMs: 7_150_000,
                                                     forwardOnly: true)
                == .complete)
    }

    @Test func outcomeForwardOnlyUnknownDurationIsUnverifiedNotComplete() {
        // Nil source duration used to skip the truncation guard entirely and bless the row
        // `.complete`; a forward-only row must stay `.unverified` (playable, re-checked later,
        // and revalidation re-derives the same outcome — the state is sticky, not re-promoted).
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: nil, actualDurationMs: 6_480_000,
                                                     forwardOnly: true)
                == .unverified(reason: "duration_unconfirmed"))
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: 0, actualDurationMs: 6_480_000,
                                                     forwardOnly: true)
                == .unverified(reason: "duration_unconfirmed"))
        // A probe that played but decoded no duration is equally unconfirmable.
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: 7_200_000, actualDurationMs: nil,
                                                     forwardOnly: true)
                == .unverified(reason: "duration_unconfirmed"))
        // Other lanes keep the historical leniency (their byte checks are the real gate).
        #expect(DownloadCompletionValidation.outcome(played: true, probeReason: "played",
                                                     expectedDurationMs: nil, actualDurationMs: nil)
                == .complete)
    }
}
