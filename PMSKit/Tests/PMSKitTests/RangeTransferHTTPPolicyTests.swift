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
}
