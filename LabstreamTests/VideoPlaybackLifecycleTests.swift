import Testing
@testable import Labstream

@MainActor
struct VideoPlaybackLifecycleTests {
    @Test func callbacksQueuedBeforeReplacementAreRejected() {
        var generation = 1
        let callbacks = queuedCallbacks(capturing: generation)

        generation += 1 // replacement item owns all subsequent callback authority

        #expect(callbacks.allSatisfy { !$0(generation) })
    }

    @Test func callbacksQueuedBeforeStopAreRejected() {
        var generation = 7
        let callbacks = queuedCallbacks(capturing: generation)

        generation += 1 // stop invalidates work before final stopped reporting

        #expect(callbacks.allSatisfy { !$0(generation) })
    }

    @Test func onlyCurrentNonCancelledCallbackIsAccepted() {
        #expect(VideoPlaybackLifecyclePolicy.accepts(capturedGeneration: 4,
                                                     currentGeneration: 4))
        #expect(!VideoPlaybackLifecyclePolicy.accepts(capturedGeneration: 4,
                                                      currentGeneration: 4,
                                                      isCancelled: true))
    }

    /// Characterizes the callback classes guarded in `PlaybackController`: `.playing` KVO,
    /// heartbeat, marker/subtitle tick, artwork, notification, and watchdog completion.
    private func queuedCallbacks(capturing generation: Int) -> [(Int) -> Bool] {
        (0..<6).map { _ in
            { current in
                VideoPlaybackLifecyclePolicy.accepts(capturedGeneration: generation,
                                                      currentGeneration: current)
            }
        }
    }
}
