import Testing
@testable import PMSKit

@Suite("Foreground static range health policy")
struct StaticRangeTaskHealthPolicyTests {
    private let policy = StaticRangeTaskHealthPolicy()
    private let length = 512 * 1_024 * 1_024

    private func verdict(active: Double = 70, duration: Double = 60,
                         baseline: Int = 0, bytes: Int = 60 * 60 * 1_024,
                         length: Int? = nil, context: String = "background_wake",
                         used: Bool = false) -> StaticRangeTaskHealthPolicy.Decision {
        policy.decide(activeSeconds: active, sampleSeconds: duration,
                      baselineBytes: baseline, currentBytes: bytes,
                      rangeLength: length ?? self.length,
                      creationContext: context, recoveryUsed: used)
    }

    @Test func settleAndWindow() {
        #expect(policy.settleSeconds == 10)
        #expect(policy.windowSeconds == 60)
        #expect(verdict(active: 69) == .insufficientWindow)
        #expect(verdict(duration: 59) == .insufficientWindow)
        #expect(verdict() == .reissue)
    }

    @Test func rateBoundary() {
        #expect(verdict(bytes: 128 * 1_024 * 60 - 1) == .reissue)
        #expect(verdict(bytes: 128 * 1_024 * 60) == .rateAboveGate)
        #expect(verdict(bytes: 0) == .reissue)
    }

    @Test func remainingTimeAndNearFinish() {
        let bytes = 60 * 60 * 1_024
        #expect(verdict(bytes: bytes, length: bytes + 60 * 1_024 * 600) == .nearFinish)
        #expect(verdict(bytes: bytes, length: bytes + 60 * 1_024 * 600 + 1) == .reissue)
        #expect(verdict(bytes: length, length: length) == .nearFinish)
        #expect(verdict(bytes: 0, length: 0) == .nearFinish)
    }

    @Test func discardCapIncludingExactBoundaryAndFreshCounter() {
        let cap = 256 * 1_024 * 1_024
        #expect(policy.maximumDiscardBytes == cap)
        #expect(verdict(baseline: cap - 60, bytes: cap) == .reissue)
        #expect(verdict(baseline: cap - 60, bytes: cap + 1) == .discardCap)
        #expect(!policy.canDiscard(cap + 1))
        #expect(policy.canDiscard(cap))
    }

    @Test func provenanceAndOneShot() {
        for context in ["unknown", "foreground", "inactive"] {
            #expect(verdict(context: context) == .provenance)
        }
        #expect(verdict(used: true) == .alreadyUsed)
    }

    @Test func counterReset() {
        #expect(verdict(baseline: 100, bytes: 99) == .counterReset)
    }

    @Test func injectableGates() {
        let custom = StaticRangeTaskHealthPolicy(settleSeconds: 1, windowSeconds: 2,
            maximumRate: 10, minimumRemainingSeconds: 3, maximumDiscardBytes: 20)
        #expect(custom.decide(activeSeconds: 3, sampleSeconds: 2, baselineBytes: 0,
            currentBytes: 10, rangeLength: 100, creationContext: "background_wake",
            recoveryUsed: false) == .reissue)
        #expect(custom.resultSeconds == 30)
    }
}
