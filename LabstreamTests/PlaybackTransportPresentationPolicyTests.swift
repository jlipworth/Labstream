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

    @Test("A transient Offline initial wait never publishes an overlay")
    @MainActor
    func transientOfflineInitialWait() async throws {
        let state = PlaybackTransportStatusState(initialPreparationDelay: .milliseconds(20))
        state.set(.preparingLocal(isPaused: false, hasObservedPlayback: false))
        #expect(state.status == .none)

        state.set(.none)
        try await Task.sleep(for: .milliseconds(40))
        #expect(state.status == .none)
    }

    @Test("A sustained Offline initial wait publishes preparation after the threshold")
    @MainActor
    func sustainedOfflineInitialWait() async throws {
        let state = PlaybackTransportStatusState(initialPreparationDelay: .milliseconds(20))
        state.set(.preparingLocal(isPaused: false, hasObservedPlayback: false))
        #expect(state.status == .none)

        try await Task.sleep(for: .milliseconds(40))
        #expect(state.status == .preparingLocal(
            isPaused: false,
            hasObservedPlayback: false
        ))

        state.set(.preparingLocal(isPaused: false, hasObservedPlayback: false))
        #expect(state.status == .preparingLocal(
            isPaused: false,
            hasObservedPlayback: false
        ))
    }

    @Test("Remote, post-start local, reconnect, and failure statuses remain immediate")
    @MainActor
    func immediateStatuses() {
        let state = PlaybackTransportStatusState(initialPreparationDelay: .seconds(60))

        state.set(.buffering)
        #expect(state.status == .buffering)
        state.set(.preparingLocal(isPaused: false, hasObservedPlayback: true))
        #expect(state.status == .preparingLocal(
            isPaused: false,
            hasObservedPlayback: true
        ))
        state.set(.reconnecting)
        #expect(state.status == .reconnecting)
        state.set(.failed(message: "Try again."))
        #expect(state.status == .failed(message: "Try again."))
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
