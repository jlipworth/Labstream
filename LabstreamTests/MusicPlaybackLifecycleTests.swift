import Testing
@testable import Labstream

@MainActor
struct MusicPlaybackLifecycleTests {
    @Test func itemReplacementRejectsQueuedOldItemCallbacks() {
        let lifecycle = MusicPlaybackLifecycle()
        let oldItem = lifecycle.advance()
        var mutations: [String] = []
        let queuedOldStatus = { lifecycle.perform(ifCurrent: oldItem) { mutations.append("status") } }
        let queuedOldEnd = { lifecycle.perform(ifCurrent: oldItem) { mutations.append("end") } }

        let newItem = lifecycle.advance()
        queuedOldStatus()
        queuedOldEnd()
        lifecycle.perform(ifCurrent: newItem) { mutations.append("new") }

        #expect(mutations == ["new"])
    }

    @Test func stopRejectsPlayerArtworkAndAudioCallbacks() {
        let lifecycle = MusicPlaybackLifecycle()
        let playing = lifecycle.advance()
        var mutations: [String] = []
        let queuedCallbacks = ["time", "rate", "heartbeat", "artwork", "interruption", "route"]
            .map { label in { lifecycle.perform(ifCurrent: playing) { mutations.append(label) } } }

        lifecycle.advance() // stop
        queuedCallbacks.forEach { $0() }

        #expect(mutations.isEmpty)
    }

    @Test func configureInvalidatesEarlierConfiguredQueue() {
        let lifecycle = MusicPlaybackLifecycle()
        let queueA = lifecycle.advance()
        let queueB = lifecycle.advance()
        var visibleQueue = "B"

        lifecycle.perform(ifCurrent: queueA) { visibleQueue = "A" }
        lifecycle.perform(ifCurrent: queueB) { visibleQueue = "B-current" }

        #expect(visibleQueue == "B-current")
    }
}
