import Testing
@testable import PMSKit

@Suite("Playback scrub state")
struct PlaybackScrubStateTests {
    @Test("dragging displays clamped draft position and commit returns target")
    func draggingClampsAndCommitsTarget() {
        var state = PlaybackScrubState(durationMs: 120_000)

        state.beginDrag(livePositionMs: 42_000)
        #expect(state.isDragging)
        #expect(state.displayedPositionMs == 42_000)

        state.updateDrag(fraction: 0.5)
        #expect(state.displayedPositionMs == 60_000)

        state.updateDrag(fraction: 1.4)
        #expect(state.displayedPositionMs == 120_000)
        #expect(state.commit() == 120_000)
        #expect(!state.isDragging)
        #expect(state.displayedPositionMs == 120_000)
    }

    @Test("cancel restores live display")
    func cancelRestoresLiveDisplay() {
        var state = PlaybackScrubState(durationMs: 90_000)

        state.updateLivePosition(12_345)
        state.beginDrag(livePositionMs: 12_345)
        state.updateDrag(fraction: 0.75)
        #expect(state.displayedPositionMs == 67_500)

        state.cancel()
        #expect(!state.isDragging)
        #expect(state.displayedPositionMs == 12_345)
    }

    @Test("unknown duration cannot commit a seek target")
    func unknownDurationCannotCommit() {
        var state = PlaybackScrubState(durationMs: 0)

        state.beginDrag(livePositionMs: 10_000)
        state.updateDrag(fraction: 0.5)

        #expect(state.displayedPositionMs == 10_000)
        #expect(state.commit() == nil)
        #expect(!state.isDragging)
    }

    @Test("committed target remains displayed until live clock catches up")
    func committedTargetDoesNotSnapBackWhileBuffering() {
        var state = PlaybackScrubState(durationMs: 120_000, livePositionMs: 80_000)

        state.beginDrag(livePositionMs: 80_000)
        state.updateDrag(fraction: 0.25)
        #expect(state.commit() == 30_000)
        #expect(state.displayedPositionMs == 30_000)

        state.updateLivePosition(80_500)
        #expect(state.displayedPositionMs == 30_000)

        state.updateLivePosition(31_000)
        #expect(state.displayedPositionMs == 31_000)
    }

    @Test("new drag clears pending committed target")
    func newDragClearsCommittedTarget() {
        var state = PlaybackScrubState(durationMs: 120_000, livePositionMs: 80_000)

        state.beginDrag(livePositionMs: 80_000)
        state.updateDrag(fraction: 0.25)
        #expect(state.commit() == 30_000)
        #expect(state.displayedPositionMs == 30_000)

        state.beginDrag(livePositionMs: 79_000)
        #expect(state.displayedPositionMs == 79_000)
    }
}
