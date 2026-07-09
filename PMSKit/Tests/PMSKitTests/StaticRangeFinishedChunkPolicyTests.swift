import Testing
@testable import PMSKit

@Suite("Static range finished chunk policy")
struct StaticRangeFinishedChunkPolicyTests {

    @Test("Hard halt discards the finished temp before it is written")
    func hardHaltDiscards() {
        #expect(StaticRangeFinishedChunkPolicy.shouldDiscardBeforeStash(
            isHalted: true,
            persistedStatusPaused: false
        ))
        #expect(StaticRangeFinishedChunkPolicy.disposition(
            isHalted: true,
            persistedStatusPaused: false
        ) == .discardTemp)
    }

    @Test("Paused halt preserves the completed chunk and leaves the row paused")
    func pausedHaltPreserves() {
        #expect(!StaticRangeFinishedChunkPolicy.shouldDiscardBeforeStash(
            isHalted: true,
            persistedStatusPaused: true
        ))
        #expect(StaticRangeFinishedChunkPolicy.disposition(
            isHalted: true,
            persistedStatusPaused: true
        ) == .writeThenPause)
    }


    @Test("Normal chunks continue")
    func normalContinues() {
        #expect(StaticRangeFinishedChunkPolicy.disposition(
            isHalted: false,
            persistedStatusPaused: false
        ) == .writeThenContinue)
    }
}
