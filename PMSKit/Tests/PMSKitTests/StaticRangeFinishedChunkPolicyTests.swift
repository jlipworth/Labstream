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
            persistedStatusPaused: false,
            segmentKind: .boundedCheckpoint,
            gracefulPauseRequested: true
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
            persistedStatusPaused: true,
            segmentKind: .continuousRemainder,
            gracefulPauseRequested: false
        ) == .writeThenPause)
    }

    @Test("Graceful pause after a durable checkpoint writes then pauses")
    func gracefulDurablePause() {
        #expect(StaticRangeFinishedChunkPolicy.disposition(
            isHalted: false,
            persistedStatusPaused: false,
            segmentKind: .boundedCheckpoint,
            gracefulPauseRequested: true
        ) == .writeThenPause)
        #expect(StaticRangeFinishedChunkPolicy.disposition(
            isHalted: false,
            persistedStatusPaused: false,
            segmentKind: .backgroundCheckpoint,
            gracefulPauseRequested: true
        ) == .writeThenPause)
    }

    @Test("Graceful pause is ignored for continuous remainders")
    func gracefulContinuousRemainderContinues() {
        #expect(StaticRangeFinishedChunkPolicy.disposition(
            isHalted: false,
            persistedStatusPaused: false,
            segmentKind: .continuousRemainder,
            gracefulPauseRequested: true
        ) == .writeThenContinue)
    }

    @Test("Normal chunks continue")
    func normalContinues() {
        #expect(StaticRangeFinishedChunkPolicy.disposition(
            isHalted: false,
            persistedStatusPaused: false,
            segmentKind: .boundedCheckpoint,
            gracefulPauseRequested: false
        ) == .writeThenContinue)
    }
}
