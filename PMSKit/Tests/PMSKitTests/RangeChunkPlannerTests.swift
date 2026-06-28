import Foundation
import Testing
@testable import PMSKit

@Suite("Range chunk planner")
struct RangeChunkPlannerTests {
    // MARK: rangeHeaderValue

    @Test("Offset 0 with no chunk bound emits no Range header (plain GET)")
    func offsetZeroOpenEndedNoHeader() {
        let planner = RangeChunkPlanner(chunkSize: 0)
        #expect(planner.rangeHeaderValue(offset: 0, expectedBytes: nil) == nil)
        #expect(planner.rangeHeaderValue(offset: 0, expectedBytes: 1_000) == nil)
    }

    @Test("Open-ended planner resumes from a non-zero offset")
    func offsetOpenEndedResumes() {
        let planner = RangeChunkPlanner(chunkSize: 0)
        #expect(planner.rangeHeaderValue(offset: 500, expectedBytes: nil) == "bytes=500-")
    }

    @Test("Chunked planner emits a closed range from offset 0")
    func chunkedFromZero() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.rangeHeaderValue(offset: 0, expectedBytes: nil) == "bytes=0-99")
    }

    @Test("Chunked planner advances the window by the chunk size")
    func chunkedAdvances() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.rangeHeaderValue(offset: 100, expectedBytes: nil) == "bytes=100-199")
    }

    @Test("Chunked planner clamps the final chunk to the expected size")
    func chunkedClampsToExpected() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        // Only 30 bytes remain of a 130-byte file.
        #expect(planner.rangeHeaderValue(offset: 100, expectedBytes: 130) == "bytes=100-129")
    }

    @Test("Offset at or past expected size yields an open range that the server answers with 416")
    func offsetBeyondExpected() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.rangeHeaderValue(offset: 130, expectedBytes: 130) == "bytes=130-")
    }

    // MARK: writeDecision

    @Test("206 partial content appends the finished chunk onto the durable partial")
    func write206Appends() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.writeDecision(httpStatus: 206, offset: 100) == .append)
    }

    @Test("200 means the server ignored Range and sent the whole resource — replace")
    func write200Replaces() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.writeDecision(httpStatus: 200, offset: 0) == .replaceWhole)
        #expect(planner.writeDecision(httpStatus: 200, offset: 500) == .replaceWhole)
    }

    @Test("416 range-not-satisfiable means the durable partial already holds the whole file")
    func write416Complete() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.writeDecision(httpStatus: 416, offset: 130) == .alreadyComplete)
    }

    @Test("Any other status is a server failure carrying the code")
    func writeOtherFails() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.writeDecision(httpStatus: 404, offset: 0) == .failServer(status: 404))
        #expect(planner.writeDecision(httpStatus: 500, offset: 100) == .failServer(status: 500))
        #expect(planner.writeDecision(httpStatus: 204, offset: 0) == .failServer(status: 204))
    }

    // MARK: nextStep (only consulted after a 206 append)

    @Test("Known size: complete once the durable partial reaches the expected size")
    func nextKnownComplete() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.nextStep(partialSize: 130, expectedBytes: 130, chunkBytes: 30) == .complete)
        #expect(planner.nextStep(partialSize: 131, expectedBytes: 130, chunkBytes: 31) == .complete)
    }

    @Test("Known size: continue from the new durable offset while bytes remain")
    func nextKnownContinue() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.nextStep(partialSize: 100, expectedBytes: 130, chunkBytes: 100) == .continueFrom(offset: 100))
    }

    @Test("Known size: a chunk that added zero bytes but is not complete is a stall, not an infinite loop")
    func nextKnownStall() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.nextStep(partialSize: 50, expectedBytes: 130, chunkBytes: 0) == .stalled)
    }

    @Test("Unknown size, open-ended: a single chunk got the rest of the file")
    func nextUnknownOpenComplete() {
        let planner = RangeChunkPlanner(chunkSize: 0)
        #expect(planner.nextStep(partialSize: 9_999, expectedBytes: nil, chunkBytes: 9_999) == .complete)
    }

    @Test("Unknown size, chunked: a short read marks EOF")
    func nextUnknownShortRead() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.nextStep(partialSize: 250, expectedBytes: nil, chunkBytes: 50) == .complete)
    }

    @Test("Unknown size, chunked: a full chunk keeps going")
    func nextUnknownFullContinue() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.nextStep(partialSize: 200, expectedBytes: nil, chunkBytes: 100) == .continueFrom(offset: 200))
    }

    @Test("Unknown size, chunked: a zero-byte chunk completes rather than spinning")
    func nextUnknownZeroComplete() {
        let planner = RangeChunkPlanner(chunkSize: 100)
        #expect(planner.nextStep(partialSize: 200, expectedBytes: nil, chunkBytes: 0) == .complete)
    }
}
