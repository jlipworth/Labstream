import Testing
@testable import Labstream

@MainActor
struct VideoPlaybackLifecycleTests {
    private final class GenerationBox {
        var value: Int
        init(_ value: Int) { self.value = value }
    }

    @Test func reconnectWatchdogSpansPlayerItemGenerationChanges() {
        let authority = PlaybackReconnectWatchdogAuthority()
        let deadline = authority.arm()
        var playerItemGeneration = 10
        playerItemGeneration += 1
        #expect(playerItemGeneration == 11)
        #expect(authority.accepts(deadline))
    }

    @Test func rearmingOrEndingReconnectRejectsOldDeadline() {
        let authority = PlaybackReconnectWatchdogAuthority()
        let first = authority.arm()
        let second = authority.arm()
        #expect(!authority.accepts(first))
        #expect(authority.accepts(second))
        authority.end()
        #expect(!authority.accepts(second))
    }

    @Test func interruptionResumeAuthoritySurvivesItemObserverRebind() {
        let authority = AudioInterruptionResumeAuthority()
        authority.interruptionBegan(wasPlaying: true)

        // PlaybackController.load() rebinds observers here; session authority is untouched.
        #expect(authority.interruptionEnded(shouldResume: true))
        #expect(!authority.interruptionEnded(shouldResume: true))
    }

    @Test func interruptionResumeAuthorityRespectsPauseAndTeardown() {
        let authority = AudioInterruptionResumeAuthority()
        authority.interruptionBegan(wasPlaying: false)
        #expect(!authority.interruptionEnded(shouldResume: true))

        authority.interruptionBegan(wasPlaying: true)
        authority.reset()
        #expect(!authority.interruptionEnded(shouldResume: true))
    }

    @Test func callbacksQueuedBeforeReplacementAreRejected() {
        let generation = GenerationBox(1)
        let sink = PlaybackLifecycleCallbackSink<Int> { $0 == generation.value }
        let captured = generation.value

        generation.value += 1 // replacement item owns all subsequent callback authority

        #expect(!sink.perform(.videoPlaying, generation: captured) {
            Issue.record("stale replacement callback mutated production state")
        })
    }

    @Test func callbacksQueuedBeforeStopAreRejected() {
        let generation = GenerationBox(7)
        let sink = PlaybackLifecycleCallbackSink<Int> { $0 == generation.value }
        let captured = generation.value

        generation.value += 1 // stop invalidates work before final stopped reporting

        for kind in [PlaybackLifecycleCallbackKind.videoHeartbeat, .videoMarker, .videoPlaying] {
            #expect(!sink.perform(kind, generation: captured) {
                Issue.record("stale stop callback mutated production state")
            })
        }
    }

    @Test func onlyCurrentNonCancelledCallbackIsAccepted() {
        #expect(VideoPlaybackLifecyclePolicy.accepts(capturedGeneration: 4,
                                                     currentGeneration: 4))
        #expect(!VideoPlaybackLifecyclePolicy.accepts(capturedGeneration: 4,
                                                      currentGeneration: 4,
                                                      isCancelled: true))
    }

}
