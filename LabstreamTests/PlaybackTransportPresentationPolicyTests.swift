import Testing
@testable import Labstream

@Suite("Source-aware playback transport presentation (#257)")
struct PlaybackTransportPresentationPolicyTests {
    @Test("Offline initial wait uses local preparation rather than buffering")
    func offlineInitialWait() {
        let status = resolved(source: .localFile, waiting: true)
        #expect(status == .preparingLocal(isPaused: false, hasObservedPlayback: false))
        let content = PlayerTransportStatusContent(status: status)
        #expect(content.title == "Preparing…")
        #expect(content.detail == "Opening the downloaded video on this device.")
        #expect(!content.title.contains("Buffer"))
    }

    @Test("Remote initial wait and rebuffer retain streaming terminology")
    func remoteWaits() {
        let initial = resolved(source: .remote, waiting: true)
        let rebuffer = resolved(source: .remote, waiting: true, hasPlayed: true)

        #expect(initial == .buffering)
        #expect(rebuffer == .buffering)
        #expect(PlayerTransportStatusContent(status: initial).title == "Buffering…")
        #expect(PlayerTransportStatusContent(status: rebuffer).detail?.contains("stream") == true)
    }

    @Test("Paused local wait never produces paused buffering copy")
    func pausedOfflineWait() {
        let status = resolved(source: .localFile, waiting: true, paused: true)
        #expect(status == .preparingLocal(isPaused: true, hasObservedPlayback: false))
        let content = PlayerTransportStatusContent(status: status)
        #expect(content.title == "Paused — preparing…")
        #expect(!content.title.contains("buffering"))

        let remoteStatus = resolved(source: .remote, waiting: true, paused: true)
        #expect(remoteStatus == .pausedBuffering)
        #expect(PlayerTransportStatusContent(status: remoteStatus).title == "Paused — buffering…")
    }

    @Test("Post-start local wait remains visible with honest local-media wording")
    func postStartOfflineWait() {
        let status = resolved(source: .localFile, waiting: true, hasPlayed: true)
        #expect(status == .preparingLocal(isPaused: false, hasObservedPlayback: true))
        let content = PlayerTransportStatusContent(status: status)
        #expect(content.title == "Preparing…")
        #expect(content.detail == "Preparing the downloaded video on this device.")
    }

    @Test("Reconnect takes precedence over local or remote waiting")
    func reconnectPrecedence() {
        for source in [PlaybackTransportPresentationPolicy.Source.localFile, .remote] {
            #expect(resolved(
                source: source,
                waiting: true,
                reconnecting: true
            ) == .reconnecting)
        }
    }

    @Test("Failure takes precedence over reconnect and waiting")
    func failurePrecedence() {
        let status = resolved(
            source: .localFile,
            waiting: true,
            reconnecting: true,
            failed: true,
            failureMessage: "Try again."
        )
        #expect(status == .failed(message: "Try again."))
        let content = PlayerTransportStatusContent(status: status)
        #expect(content.title == "Playback failed")
        #expect(content.detail == "Try again.")
    }

    @Test("No technical wait leaves the overlay hidden")
    func noWait() {
        #expect(resolved(source: .localFile, waiting: false) == .none)
        #expect(resolved(source: .remote, waiting: false) == .none)
    }

    private func resolved(
        source: PlaybackTransportPresentationPolicy.Source,
        waiting: Bool,
        paused: Bool = false,
        hasPlayed: Bool = false,
        reconnecting: Bool = false,
        failed: Bool = false,
        failureMessage: String? = nil
    ) -> PlaybackTransportStatus {
        PlaybackTransportPresentationPolicy.status(.init(
            source: source,
            isFailed: failed,
            failureMessage: failureMessage,
            isReconnecting: reconnecting,
            isWaitingForMedia: waiting,
            isPaused: paused,
            hasObservedPlayback: hasPlayed
        ))
    }
}
