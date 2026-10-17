#if DEBUG
import PMSKit
import SwiftUI

/// Deterministic iPhone/iPad player fixture (#258): presents the real shared `CustomPlayerView`
/// over a locally generated clip of a selectable source aspect, with no network, credentials, or
/// browse state, using the same full-screen-cover + landscape preflight as Detail. Production
/// launches never reach this surface.
struct MobilePlayerFixtureView: View {
    private enum Phase {
        case preparing
        case ready(URL)
        case closed
        case failed(String)
    }

    @State private var phase: Phase = .preparing
    @State private var presentingPlayer = false
    @State private var orientationCoordinator = MobilePlayerOrientationCoordinator()

    var body: some View {
        ZStack {
            switch phase {
            case .preparing:
                ProgressView("Preparing fixture video…")
            case .ready(let url):
                Color.black
                    .ignoresSafeArea()
                    .fullScreenCover(isPresented: $presentingPlayer,
                                     onDismiss: { phase = .closed }) {
                        fixturePlayer(url: url)
                    }
            case .closed:
                VStack(spacing: 24) {
                    Text("Player closed")
                        .accessibilityIdentifier("mobile.fixture.player.closed")
                    Button("Reopen Player") {
                        phase = .preparing
                        Task { await prepare() }
                    }
                    .accessibilityIdentifier("mobile.fixture.player.reopen")
                }
            case .failed(let message):
                Text("Fixture failed: \(message)")
                    .accessibilityIdentifier("mobile.fixture.player.failed")
            }
        }
        .task { await prepare() }
    }

    private func fixturePlayer(url: URL) -> some View {
        let item = DebugPlayerFixtureMedia.item
        let identity = PlatformClientIdentity.make(clientIdentifier: "offline")
        let client = PlexClient(identity: identity)
        return CustomPlayerView(item: item,
                                controllerFactory: {
                                    let controller = PlaybackController(
                                        item: item,
                                        sessionSource: .offline(OfflinePlaybackSession(fileURL: url)),
                                        identity: identity,
                                        client: client)
                                    if DebugUITestLaunchConfiguration.playerFixtureStartsPaused {
                                        holdPaused(controller)
                                    }
                                    return controller
                                },
                                onClose: { presentingPlayer = false })
            .withMobileOrientationCoordinator(orientationCoordinator)
    }

    /// Pause once the local item is playing so the chrome stays revealed in the paused state.
    private func holdPaused(_ controller: PlaybackController) {
        Task { @MainActor [weak controller] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let controller else { return }
                if controller.player.currentItem?.status == .readyToPlay {
                    try? await Task.sleep(for: .milliseconds(500))
                    controller.requestPause()
                    return
                }
            }
        }
    }

    private func prepare() async {
        do {
            let size = DebugUITestLaunchConfiguration.playerFixtureAspect.encodedSize
            let url = try await DebugPlayerFixtureMedia.ensureVideoFile(width: size.width,
                                                                        height: size.height)
            phase = .ready(url)
            await orientationCoordinator.enterLandscapeBeforePresentationIfNeeded()
            presentingPlayer = true
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}
#endif
