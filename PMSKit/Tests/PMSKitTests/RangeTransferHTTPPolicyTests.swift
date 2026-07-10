import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

@Suite("Range transfer HTTP policy")
struct RangeTransferHTTPPolicyTests {
    @Test("Range request shape distinguishes open-ended remainders from legacy closed ranges")
    func rangeRequestShape() {
        #expect(RangeTransferHTTPPolicy.rangeRequestShape(nil) == .missing)
        #expect(RangeTransferHTTPPolicy.rangeRequestShape("bytes=10-") == .openEnded)
        #expect(RangeTransferHTTPPolicy.rangeRequestShape(" bytes=0-67108863 ") == .closed)
        #expect(RangeTransferHTTPPolicy.rangeRequestShape("items=10-") == .invalid)
        #expect(RangeTransferHTTPPolicy.rangeRequestShape("bytes=-500") == .invalid)
    }

    @Test("If-Range validator rejects weak ETags and falls back to Last-Modified")
    func validator() {
        #expect(RangeTransferHTTPPolicy.strongIfRangeValidator(etag: " \"abc\" ", lastModified: "date") == "\"abc\"")
        #expect(RangeTransferHTTPPolicy.strongIfRangeValidator(etag: "W/\"abc\"", lastModified: "date") == "date")
        #expect(RangeTransferHTTPPolicy.strongIfRangeValidator(etag: "", lastModified: "date") == "date")
        #expect(RangeTransferHTTPPolicy.strongIfRangeValidator(etag: nil, lastModified: nil) == nil)
    }

    @Test("Content-Range parsing returns start and total while treating star total as unknown")
    func contentRangeParsing() {
        #expect(RangeTransferHTTPPolicy.contentRangeStart("bytes 100-199/1000") == 100)
        #expect(RangeTransferHTTPPolicy.contentRangeTotal("bytes 100-199/1000") == 1000)
        #expect(RangeTransferHTTPPolicy.contentRangeTotal("bytes */1000") == 1000)
        #expect(RangeTransferHTTPPolicy.contentRangeTotal("bytes 100-199/*") == nil)
        #expect(RangeTransferHTTPPolicy.contentRangeStart("not-a-range") == nil)
    }

    @Test("Internally resumed range bodies are accepted only for exact assembled temps")
    func internallyResumedBodyAcceptance() {
        #expect(RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeBody(
            baseOffset: 1_000,
            contentRangeStart: 1_020,
            stashBytes: 64,
            expectedBodyBytes: 64))
        #expect(!RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeBody(
            baseOffset: 1_000,
            contentRangeStart: 1_000,
            stashBytes: 64,
            expectedBodyBytes: 64))
        #expect(!RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeBody(
            baseOffset: 1_000,
            contentRangeStart: 2_000,
            stashBytes: 64,
            expectedBodyBytes: 64))
        #expect(!RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeBody(
            baseOffset: 1_000,
            contentRangeStart: 1_020,
            stashBytes: 63,
            expectedBodyBytes: 64))
    }

    @Test("A blob-resumed segment finishing out of order still passes the internal-resume escape")
    func blobResumedOutOfOrderSegmentAccepted() {
        // Lens 2 F1 composition: a CLOSED tail segment [2_048, 2_048 + 512) is blob-resumed after
        // a network blip — URLSession re-requests mid-segment, so the response Content-Range
        // starts past the segment's base offset while the assembled temp holds the FULL segment
        // body. When it finishes OUT OF ORDER (durable < baseOffset, the held branch), the same
        // escape the in-order path uses must accept it at the segment's base offset with the
        // stash's actual length; rejecting it burns offset-mismatch budget on a healthy train.
        let segmentLength = 512
        #expect(RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeBody(
            baseOffset: 2_048,
            contentRangeStart: 2_048 + 128,     // resumed mid-segment
            stashBytes: segmentLength,          // temp holds the whole segment body
            expectedBodyBytes: segmentLength))
        // An out-of-order resumed body that is NOT the whole segment stays rejected.
        #expect(!RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeBody(
            baseOffset: 2_048,
            contentRangeStart: 2_048 + 128,
            stashBytes: segmentLength - 128,
            expectedBodyBytes: segmentLength))
    }

    @Test("Range request start parses normal and open-ended byte ranges")
    func rangeRequestStart() {
        #expect(RangeTransferHTTPPolicy.rangeRequestStart("bytes=0-67108863") == 0)
        #expect(RangeTransferHTTPPolicy.rangeRequestStart(" bytes=1048576- ") == 1_048_576)
        #expect(RangeTransferHTTPPolicy.rangeRequestStart("bytes=-500") == nil)
        #expect(RangeTransferHTTPPolicy.rangeRequestStart("items=0-") == nil)
    }

    @Test("Range request end parses only closed ranges so segment length can be recovered")
    func rangeRequestEnd() {
        // Closed range: inclusive end bound → length is (end - start + 1).
        #expect(RangeTransferHTTPPolicy.rangeRequestEnd("bytes=0-67108863") == 67_108_863)
        #expect(RangeTransferHTTPPolicy.rangeRequestEnd(" bytes=1048576-2097151 ") == 2_097_151)
        // Open-ended, absent, prefix-only, or malformed → no end bound.
        #expect(RangeTransferHTTPPolicy.rangeRequestEnd("bytes=1048576-") == nil)
        #expect(RangeTransferHTTPPolicy.rangeRequestEnd(nil) == nil)
        #expect(RangeTransferHTTPPolicy.rangeRequestEnd("bytes=-500") == nil)
        #expect(RangeTransferHTTPPolicy.rangeRequestEnd("items=0-100") == nil)
    }

    // #220: an HTTP 200 body replaces the whole partial only when it is plausibly the whole
    // resource. On an UNCHANGED resource (validator equal, or unknowable) a size mismatch means
    // a truncated body and must be rejected rather than overwrite a good partial checkpoint.
    // A CHANGED resource (both validators present and different) keeps the honest replace.
    @Test("200 replaceWhole adoption requires the body to plausibly be the whole resource")
    func replaceWholeAdoption() {
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 1_000, expectedBytes: 1_000,
            storedValidator: "\"etag-a\"", responseValidator: "\"etag-a\""))
        #expect(!RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: 1_000,
            storedValidator: "\"etag-a\"", responseValidator: "\"etag-a\""))
        #expect(!RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: 1_000,
            storedValidator: nil, responseValidator: nil))
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: 1_000,
            storedValidator: "\"etag-a\"", responseValidator: "\"etag-b\""))
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: nil,
            storedValidator: nil, responseValidator: nil))
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: 0,
            storedValidator: nil, responseValidator: nil))
        #expect(!RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: nil, expectedBytes: 1_000,
            storedValidator: nil, responseValidator: nil))
    }

    // Audit B.3 residual weakness: the validator-diff branch adopted a changed-resource 200 of
    // ANY size. A body shorter than its own declared Content-Length is truncated by definition
    // and must never be adopted, changed resource or not.
    @Test("200 replaceWhole adoption rejects bodies truncated against their own Content-Length")
    func replaceWholeContentLengthGuard() {
        #expect(!RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: 1_000,
            storedValidator: "\"etag-a\"", responseValidator: "\"etag-b\"",
            responseContentLength: 900))
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 900, expectedBytes: 1_000,
            storedValidator: "\"etag-a\"", responseValidator: "\"etag-b\"",
            responseContentLength: 900))
        #expect(!RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: nil,
            storedValidator: nil, responseValidator: nil,
            responseContentLength: 900))
        // Unknown Content-Length keeps the pre-existing semantics.
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: 1_000,
            storedValidator: "\"etag-a\"", responseValidator: "\"etag-b\"",
            responseContentLength: nil))
    }
}
