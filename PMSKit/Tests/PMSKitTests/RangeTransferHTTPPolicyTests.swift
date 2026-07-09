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

    @Test("Range request start parses normal and open-ended byte ranges")
    func rangeRequestStart() {
        #expect(RangeTransferHTTPPolicy.rangeRequestStart("bytes=0-67108863") == 0)
        #expect(RangeTransferHTTPPolicy.rangeRequestStart(" bytes=1048576- ") == 1_048_576)
        #expect(RangeTransferHTTPPolicy.rangeRequestStart("bytes=-500") == nil)
        #expect(RangeTransferHTTPPolicy.rangeRequestStart("items=0-") == nil)
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
}
