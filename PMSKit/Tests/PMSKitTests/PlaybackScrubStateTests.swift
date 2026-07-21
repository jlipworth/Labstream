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

    @Test("programmatic commit is clamped and held like a scrub commit")
    func programmaticCommitIsHeld() {
        var state = PlaybackScrubState(durationMs: 120_000, livePositionMs: 80_000)

        #expect(state.commit(toMs: 150_000) == 120_000)
        #expect(!state.isDragging)
        #expect(state.displayedPositionMs == 120_000)

        state.updateLivePosition(81_000)
        #expect(state.displayedPositionMs == 120_000)

        state.updateLivePosition(119_000)
        #expect(state.displayedPositionMs == 119_000)
    }

    @Test("hold flag keeps committed target pinned despite a within-tolerance live reading (GH #110)")
    func holdFlagPreventsPrematureToleranceClear() {
        var state = PlaybackScrubState(durationMs: 120_000, livePositionMs: 64_000)

        state.beginDrag(livePositionMs: 64_000)
        state.updateDrag(fraction: 67_000.0 / 120_000.0)
        #expect(state.commit() == 67_000)
        #expect(state.displayedPositionMs == 67_000)

        // Mid-reopen the live clock briefly reports a value within the 2000ms tolerance of the
        // target; without the lifecycle guard this would clear committedTargetMs and let the label
        // fall through to a (possibly stale) live position, producing the oscillation. With the
        // hold set, the committed target stays pinned.
        state.updateLivePosition(67_500, holdCommittedTarget: true)
        #expect(state.displayedPositionMs == 67_000)

        // It also must NOT clear when the live clock bounces back to the stale pre-seek position.
        state.updateLivePosition(64_000, holdCommittedTarget: true)
        #expect(state.displayedPositionMs == 67_000)

        // Once the presenter releases the hold and the clock has genuinely caught up, the
        // tolerance-clear retires the committed target and the live position takes over.
        state.updateLivePosition(67_200, holdCommittedTarget: false)
        #expect(state.displayedPositionMs == 67_200)
    }

    @Test("a rapid second scrub seeded from displayedPositionMs resumes at the held target, not the stale clock")
    func rapidSecondScrubStartsFromHeldTarget() {
        var state = PlaybackScrubState(durationMs: 120_000, livePositionMs: 10_000)

        state.beginDrag(livePositionMs: 10_000)
        state.updateDrag(fraction: 60_000.0 / 120_000.0)
        #expect(state.commit() == 60_000)

        // The seek is still rebuilding: the live clock keeps reporting the pre-seek offset,
        // held off by the lifecycle guard so the display stays pinned to the target.
        state.updateLivePosition(10_400, holdCommittedTarget: true)
        #expect(state.displayedPositionMs == 60_000)

        // A presenter that seeds the next drag from the raw player clock would restart the
        // scrub at 10s; seeding from displayedPositionMs (the tvOS call-site contract)
        // resumes exactly at the committed target.
        state.beginDrag(livePositionMs: state.displayedPositionMs)
        #expect(state.displayedPositionMs == 60_000)
        state.updateDrag(fraction: 70_000.0 / 120_000.0)
        #expect(state.commit() == 70_000)
        #expect(state.displayedPositionMs == 70_000)
    }
}
