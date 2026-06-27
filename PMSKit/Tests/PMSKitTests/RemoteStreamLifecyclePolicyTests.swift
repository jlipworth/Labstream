import Testing
@testable import PMSKit

@Suite("Remote stream lifecycle policy")
struct RemoteStreamLifecyclePolicyTests {
    @Test("Reopen result is accepted only for current non-cancelled generation")
    func acceptsOnlyCurrentNonCancelledGeneration() {
        #expect(RemoteStreamLifecyclePolicy.acceptsReopenResult(capturedGeneration: 7,
                                                               currentGeneration: 7,
                                                               isCancelled: false))
        #expect(!RemoteStreamLifecyclePolicy.acceptsReopenResult(capturedGeneration: 7,
                                                                currentGeneration: 8,
                                                                isCancelled: false))
        #expect(!RemoteStreamLifecyclePolicy.acceptsReopenResult(capturedGeneration: 7,
                                                                currentGeneration: 7,
                                                                isCancelled: true))
    }

    @Test("Same play session skips prior stop")
    func samePlaySessionSkipsPriorStop() {
        #expect(RemoteStreamLifecyclePolicy.priorSessionStopDecision(priorPlaySessionID: "session-1",
                                                                    reopenedPlaySessionID: "session-1") == .skip(reason: "same_play_session"))
    }

    @Test("Changed or absent play session defers prior stop")
    func changedOrAbsentPlaySessionDefersStop() {
        #expect(RemoteStreamLifecyclePolicy.priorSessionStopDecision(priorPlaySessionID: "session-1",
                                                                    reopenedPlaySessionID: "session-2") == .deferStop(reason: "after_reopen_item_detached"))
        #expect(RemoteStreamLifecyclePolicy.priorSessionStopDecision(priorPlaySessionID: nil,
                                                                    reopenedPlaySessionID: "session-2") == .deferStop(reason: "after_reopen_item_detached"))
        #expect(RemoteStreamLifecyclePolicy.priorSessionStopDecision(priorPlaySessionID: "session-1",
                                                                    reopenedPlaySessionID: nil) == .deferStop(reason: "after_reopen_item_detached"))
    }

    @Test("Final teardown stops active remote session exactly once")
    func finalTeardownStopsActiveRemoteSessionExactlyOnce() {
        #expect(RemoteStreamLifecyclePolicy.finalSessionStopDecision(hasRemoteStream: true,
                                                                    didAlreadyStop: false) == .stop)
        #expect(RemoteStreamLifecyclePolicy.finalSessionStopDecision(hasRemoteStream: true,
                                                                    didAlreadyStop: true) == .skip(reason: "already_stopped"))
        #expect(RemoteStreamLifecyclePolicy.finalSessionStopDecision(hasRemoteStream: false,
                                                                    didAlreadyStop: false) == .skip(reason: "not_remote_stream"))
    }
}
