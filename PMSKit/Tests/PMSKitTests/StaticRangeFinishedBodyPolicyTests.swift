import Testing
@testable import PMSKit

@Suite("Static range finished body policy")
struct StaticRangeFinishedBodyPolicyTests {
    @Test("Hard halt discards a finished body before stashing")
    func hardHaltDiscards() {
        #expect(StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(
            isHalted: true,
            persistedStatusPaused: false
        ))
        #expect(StaticRangeFinishedBodyPolicy.disposition(
            isHalted: true,
            persistedStatusPaused: false
        ) == .discardTemp)
    }

    @Test("Paused halt preserves a finished body and then stays paused")
    func pausedHaltPreserves() {
        #expect(!StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(
            isHalted: true,
            persistedStatusPaused: true
        ))
        #expect(StaticRangeFinishedBodyPolicy.disposition(
            isHalted: true,
            persistedStatusPaused: true
        ) == .writeThenPause)
    }

    @Test("Unhalted finished body continues normally")
    func unhaltedContinues() {
        #expect(StaticRangeFinishedBodyPolicy.disposition(
            isHalted: false,
            persistedStatusPaused: false
        ) == .writeThenContinue)
    }
}
