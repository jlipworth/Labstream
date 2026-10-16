import Foundation
import Testing
@testable import PMSKit

@Suite("Static range remainder request policy")
struct StaticRangeRemainderRequestPolicyTests {
    @Test("Remainder requests are always open-ended from the durable offset")
    func openEndedRange() {
        let policy = StaticRangeRemainderRequestPolicy()

        #expect(policy.rangeHeaderValue(offset: 0) == "bytes=0-")
        #expect(policy.rangeHeaderValue(offset: 500) == "bytes=500-")
        #expect(policy.rangeHeaderValue(offset: -10) == "bytes=0-")
    }

    @Test("Closed-range requests cover exactly [offset, offset + length - 1]")
    func closedRange() {
        let policy = StaticRangeRemainderRequestPolicy()

        #expect(policy.rangeHeaderValue(offset: 0, length: 100) == "bytes=0-99")
        #expect(policy.rangeHeaderValue(offset: 500, length: 250) == "bytes=500-749")
        #expect(policy.rangeHeaderValue(offset: -10, length: 100) == "bytes=0-99")
    }

    @Test("Remainder expected body bytes are known only with a total size")
    func expectedBodyBytes() {
        let policy = StaticRangeRemainderRequestPolicy()

        #expect(policy.expectedBodyBytes(offset: 400, expectedBytes: 1_000) == 600)
        #expect(policy.expectedBodyBytes(offset: 400, expectedBytes: nil) == nil)
        #expect(policy.expectedBodyBytes(offset: 1_200, expectedBytes: 1_000) == 0)
    }

    @Test("Closed segments expect their own length, not the whole-file remainder")
    func expectedBodyBytesForClosedSegment() {
        let policy = StaticRangeRemainderRequestPolicy()

        // Mid-file segment: its own length, never the remainder.
        #expect(policy.expectedBodyBytes(offset: 0, expectedBytes: 10_000, segmentLength: 512) == 512)
        #expect(policy.expectedBodyBytes(offset: 512, expectedBytes: 10_000, segmentLength: 512) == 512)
        // Tail segment: clamped to the remainder.
        #expect(policy.expectedBodyBytes(offset: 9_800, expectedBytes: 10_000, segmentLength: 512) == 200)
        // Unknown total: the closed segment's length is still exact.
        #expect(policy.expectedBodyBytes(offset: 512, expectedBytes: nil, segmentLength: 512) == 512)
        // nil segmentLength keeps open-ended remainder semantics.
        #expect(policy.expectedBodyBytes(offset: 400, expectedBytes: 1_000, segmentLength: nil) == 600)
        #expect(policy.expectedBodyBytes(offset: 400, expectedBytes: nil, segmentLength: nil) == nil)
    }

    @Test("Response status maps to a body write decision", arguments: [
        // 206 partial content appends the response body onto the durable partial.
        (206, StaticRangeBodyWrite.append),
        // 200 means the server ignored Range and sent the whole resource.
        (200, StaticRangeBodyWrite.replaceWhole),
        // 416 range-not-satisfiable means the durable partial already holds the whole file.
        (416, StaticRangeBodyWrite.alreadyComplete),
        // Any other status is a server failure carrying the code.
        (404, StaticRangeBodyWrite.failServer(status: 404)),
        (500, StaticRangeBodyWrite.failServer(status: 500)),
        (204, StaticRangeBodyWrite.failServer(status: 204)),
    ])
    func writeDecision(httpStatus: Int, expected: StaticRangeBodyWrite) {
        #expect(StaticRangeRemainderRequestPolicy().writeDecision(httpStatus: httpStatus) == expected)
    }

    struct NextStepRow: Sendable, CustomTestStringConvertible {
        let note: String
        let partialSize: Int
        let expectedBytes: Int?
        let bodyBytes: Int
        let expected: StaticRangeRemainderNext

        var testDescription: String { note }
    }

    @Test("Durable partial progress maps to the next remainder step", arguments: [
        NextStepRow(note: "known size: complete once the partial reaches the expected size",
                    partialSize: 130, expectedBytes: 130, bodyBytes: 30, expected: .complete),
        NextStepRow(note: "known size: complete once the partial passes the expected size",
                    partialSize: 131, expectedBytes: 130, bodyBytes: 31, expected: .complete),
        NextStepRow(note: "known size: continue from the new durable offset while bytes remain",
                    partialSize: 100, expectedBytes: 130, bodyBytes: 100, expected: .continueFrom(offset: 100)),
        NextStepRow(note: "known size: a body that added zero bytes but is not complete is a stall",
                    partialSize: 50, expectedBytes: 130, bodyBytes: 0, expected: .stalled),
        NextStepRow(note: "unknown size: a successful open-ended remainder is final",
                    partialSize: 9_999, expectedBytes: nil, bodyBytes: 9_999, expected: .complete),
        NextStepRow(note: "unknown size: an empty successful open-ended remainder is final",
                    partialSize: 0, expectedBytes: nil, bodyBytes: 0, expected: .complete),
    ])
    func nextStep(_ row: NextStepRow) {
        #expect(StaticRangeRemainderRequestPolicy().nextStep(
            partialSize: row.partialSize,
            expectedBytes: row.expectedBytes,
            bodyBytes: row.bodyBytes
        ) == row.expected)
    }
}
