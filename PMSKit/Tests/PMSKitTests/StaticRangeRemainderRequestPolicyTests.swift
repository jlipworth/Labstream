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

    @Test("Remainder expected body bytes are known only with a total size")
    func expectedBodyBytes() {
        let policy = StaticRangeRemainderRequestPolicy()

        #expect(policy.expectedBodyBytes(offset: 400, expectedBytes: 1_000) == 600)
        #expect(policy.expectedBodyBytes(offset: 400, expectedBytes: nil) == nil)
        #expect(policy.expectedBodyBytes(offset: 1_200, expectedBytes: 1_000) == 0)
    }

    @Test("206 partial content appends the response body onto the durable partial")
    func write206Appends() {
        let policy = StaticRangeRemainderRequestPolicy()
        #expect(policy.writeDecision(httpStatus: 206) == .append)
    }

    @Test("200 means the server ignored Range and sent the whole resource")
    func write200Replaces() {
        let policy = StaticRangeRemainderRequestPolicy()
        #expect(policy.writeDecision(httpStatus: 200) == .replaceWhole)
    }

    @Test("416 range-not-satisfiable means the durable partial already holds the whole file")
    func write416Complete() {
        let policy = StaticRangeRemainderRequestPolicy()
        #expect(policy.writeDecision(httpStatus: 416) == .alreadyComplete)
    }

    @Test("Any other status is a server failure carrying the code")
    func writeOtherFails() {
        let policy = StaticRangeRemainderRequestPolicy()
        #expect(policy.writeDecision(httpStatus: 404) == .failServer(status: 404))
        #expect(policy.writeDecision(httpStatus: 500) == .failServer(status: 500))
        #expect(policy.writeDecision(httpStatus: 204) == .failServer(status: 204))
    }

    @Test("Known size: complete once the durable partial reaches the expected size")
    func nextKnownComplete() {
        let policy = StaticRangeRemainderRequestPolicy()
        #expect(policy.nextStep(partialSize: 130, expectedBytes: 130, bodyBytes: 30) == .complete)
        #expect(policy.nextStep(partialSize: 131, expectedBytes: 130, bodyBytes: 31) == .complete)
    }

    @Test("Known size: continue from the new durable offset while bytes remain")
    func nextKnownContinue() {
        let policy = StaticRangeRemainderRequestPolicy()
        #expect(policy.nextStep(partialSize: 100, expectedBytes: 130, bodyBytes: 100) == .continueFrom(offset: 100))
    }

    @Test("Known size: a response body that added zero bytes but is not complete is a stall")
    func nextKnownStall() {
        let policy = StaticRangeRemainderRequestPolicy()
        #expect(policy.nextStep(partialSize: 50, expectedBytes: 130, bodyBytes: 0) == .stalled)
    }

    @Test("Unknown size: a successful open-ended remainder is final")
    func nextUnknownComplete() {
        let policy = StaticRangeRemainderRequestPolicy()
        #expect(policy.nextStep(partialSize: 9_999, expectedBytes: nil, bodyBytes: 9_999) == .complete)
        #expect(policy.nextStep(partialSize: 0, expectedBytes: nil, bodyBytes: 0) == .complete)
    }
}
