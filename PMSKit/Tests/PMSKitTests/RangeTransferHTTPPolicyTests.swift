import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PMSKit

@Suite("Range transfer HTTP policy")
struct RangeTransferHTTPPolicyTests {
    @Test("Segment classification distinguishes bounded, background, and continuous ranges")
    func segmentKind() {
        #expect(RangeTransferHTTPPolicy.segmentKind(rangeHeader: nil, foregroundChunkSize: 64) == .boundedCheckpoint)
        #expect(RangeTransferHTTPPolicy.segmentKind(rangeHeader: "bytes=10-", foregroundChunkSize: 64) == .continuousRemainder)
        #expect(RangeTransferHTTPPolicy.segmentKind(rangeHeader: "bytes=10-20", foregroundChunkSize: 64) == .boundedCheckpoint)
        #expect(RangeTransferHTTPPolicy.segmentKind(rangeHeader: "bytes=10-100", foregroundChunkSize: 64) == .backgroundCheckpoint)
        #expect(RangeTransferHTTPPolicy.segmentKind(rangeHeader: "items=10-", foregroundChunkSize: 64) == .boundedCheckpoint)
    }

    @Test("Closed range length is inclusive and rejects malformed or reversed specs")
    func closedRangeLength() {
        #expect(RangeTransferHTTPPolicy.closedRangeLength("0-0") == 1)
        #expect(RangeTransferHTTPPolicy.closedRangeLength("10-20") == 11)
        #expect(RangeTransferHTTPPolicy.closedRangeLength("20-10") == nil)
        #expect(RangeTransferHTTPPolicy.closedRangeLength("10-") == nil)
        #expect(RangeTransferHTTPPolicy.closedRangeLength("10-20,30-40") == nil)
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

    @Test("Internally resumed closed range chunks are accepted only for exact assembled temps")
    func internallyResumedChunkAcceptance() {
        #expect(RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeChunk(
            baseOffset: 1_000,
            contentRangeStart: 1_020,
            stashBytes: 64,
            expectedSegmentBytes: 64))
        #expect(!RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeChunk(
            baseOffset: 1_000,
            contentRangeStart: 1_000,
            stashBytes: 64,
            expectedSegmentBytes: 64))
        #expect(!RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeChunk(
            baseOffset: 1_000,
            contentRangeStart: 2_000,
            stashBytes: 64,
            expectedSegmentBytes: 64))
        #expect(!RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeChunk(
            baseOffset: 1_000,
            contentRangeStart: 1_020,
            stashBytes: 63,
            expectedSegmentBytes: 64))
    }

    @Test("Range request start parses normal and open-ended byte ranges")
    func rangeRequestStart() {
        #expect(RangeTransferHTTPPolicy.rangeRequestStart("bytes=0-67108863") == 0)
        #expect(RangeTransferHTTPPolicy.rangeRequestStart(" bytes=1048576- ") == 1_048_576)
        #expect(RangeTransferHTTPPolicy.rangeRequestStart("bytes=-500") == nil)
        #expect(RangeTransferHTTPPolicy.rangeRequestStart("items=0-") == nil)
    }

    @Test("Durable checkpoint segments exclude continuous remainders")
    func durableSegments() {
        #expect(RangeTransferHTTPPolicy.isDurableCheckpointSegment(.boundedCheckpoint))
        #expect(RangeTransferHTTPPolicy.isDurableCheckpointSegment(.backgroundCheckpoint))
        #expect(!RangeTransferHTTPPolicy.isDurableCheckpointSegment(.continuousRemainder))
    }

    // #220: an HTTP 200 body replaces the whole partial only when it is plausibly the whole
    // resource. On an UNCHANGED resource (validator equal, or unknowable) a size mismatch means
    // a truncated body and must be rejected rather than overwrite a good partial checkpoint.
    // A CHANGED resource (both validators present and different) keeps the honest replace.
    @Test("200 replaceWhole adoption requires the body to plausibly be the whole resource")
    func replaceWholeAdoption() {
        // Exact size match on an unchanged resource → adopt.
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 1_000, expectedBytes: 1_000,
            storedValidator: "\"etag-a\"", responseValidator: "\"etag-a\""))
        // Size mismatch, validator proves resource unchanged → truncated body, reject.
        #expect(!RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: 1_000,
            storedValidator: "\"etag-a\"", responseValidator: "\"etag-a\""))
        // Size mismatch, validators unknown → cannot prove it's the whole resource, reject.
        #expect(!RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: 1_000,
            storedValidator: nil, responseValidator: nil))
        // Size mismatch but the resource demonstrably changed → whole NEW resource, adopt.
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: 1_000,
            storedValidator: "\"etag-a\"", responseValidator: "\"etag-b\""))
        // No expected size on record → no basis to reject, adopt.
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: nil,
            storedValidator: nil, responseValidator: nil))
        #expect(RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: 400, expectedBytes: 0,
            storedValidator: nil, responseValidator: nil))
        // Unstatable stash after a successful move is broken state → reject to retry.
        #expect(!RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
            stashBytes: nil, expectedBytes: 1_000,
            storedValidator: nil, responseValidator: nil))
    }
}
