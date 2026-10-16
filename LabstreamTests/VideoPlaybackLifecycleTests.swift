import Testing
@testable import Labstream

@MainActor
struct VideoPlaybackLifecycleTests {
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

    @Test func onlyCurrentNonCancelledCallbackIsAccepted() {
        #expect(VideoPlaybackLifecyclePolicy.accepts(capturedGeneration: 4,
                                                     currentGeneration: 4))
        #expect(!VideoPlaybackLifecyclePolicy.accepts(capturedGeneration: 4,
                                                      currentGeneration: 4,
                                                      isCancelled: true))
    }

}
