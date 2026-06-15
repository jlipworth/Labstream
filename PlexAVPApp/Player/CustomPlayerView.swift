import AVFoundation
import PMSKit
import SwiftUI
import UIKit

/// The app's video player: app-owned chrome + scrubber over an `AVPlayerLayer` presenter.
///
/// This is now the ONLY video player. The former AVKit `AVPlayerViewController` path — and the
/// default-off Settings toggle that used to route to this view — have been removed. The
/// app-owned scrubber gives deterministic seek intent and avoids the native AVKit control/chrome
/// seek weirdness that motivated the switch.
struct CustomPlayerView: View {
    @Environment(CustomCinemaSessionStore.self) private var cinemaSession
    @Environment(RealityTheaterSessionStore.self) private var realityTheaterSession
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    private let item: MediaItem
    private let controllerFactory: @MainActor () -> PlaybackController
    private let trickPlayProvider: (any TrickPlayThumbnailProviding)?
    private let onClose: (() -> Void)?
    private let onRequestPlay: ((MediaItem) -> Void)?
    private let allowsRealityTheater: Bool

    @State private var controller: PlaybackController?
    @State private var scrubState: PlaybackScrubState
    @State private var clockTaskID = UUID()
    @State private var isReconnecting = false

    init(item: MediaItem,
         controllerFactory: @escaping @MainActor () -> PlaybackController,
         trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
         onClose: (() -> Void)? = nil,
         onRequestPlay: ((MediaItem) -> Void)? = nil,
         allowsRealityTheater: Bool = false) {
        self.item = item
        self.controllerFactory = controllerFactory
        self.trickPlayProvider = trickPlayProvider
        self.onClose = onClose
        self.onRequestPlay = onRequestPlay
        self.allowsRealityTheater = allowsRealityTheater
        _scrubState = State(initialValue: PlaybackScrubState(durationMs: item.duration ?? 0,
                                                            livePositionMs: item.viewOffset ?? 0))
    }

    /// Offline initializer: plays a downloaded file through the custom player.
    ///
    /// Mirrors the contract of the retired `PlayerView.init(localFile:item:onClose:)`. A pure
    /// offline file needs no server session, but `PlaybackController` still wants an identity +
    /// client for type symmetry, so we synthesize a throwaway pair here. Callers that already
    /// hold an `AppModel` can use `init(item:controllerFactory:…)` with a local-file factory if
    /// they prefer their real identity/client.
    init(localFile: URL, item: MediaItem, onClose: (() -> Void)? = nil) {
        let identity = ClientIdentity(clientIdentifier: "offline",
                                      product: "VisionPlex",
                                      version: "0.1.0",
                                      deviceName: "Apple Vision Pro")
        let client = PlexClient(identity: identity)
        self.init(item: item,
                  controllerFactory: {
                      PlaybackController(localFile: localFile,
                                         item: item,
                                         identity: identity,
                                         client: client)
                  },
                  trickPlayProvider: nil,
                  onClose: onClose,
                  onRequestPlay: nil,
                  allowsRealityTheater: true)
    }

    var body: some View {
        let isDetachedToCinema = cinemaSession.presentationState != .closed

        ZStack {
            (isDetachedToCinema ? Color.clear : Color.black)
                .ignoresSafeArea()

            if !isDetachedToCinema {
                PlayerLayerView(player: controller?.player)
                    .ignoresSafeArea()

                if let controller {
                    CustomPlayerChrome(controller: controller,
                                       title: item.title,
                                       scrubState: $scrubState,
                                       trickPlayProvider: trickPlayProvider,
                                       isReconnecting: isReconnecting,
                                       onRetry: { retry(controller) },
                                       onClose: onClose,
                                       allowsRealityTheater: allowsRealityTheater)
                }
            }

            if controller == nil {
                ProgressView()
                    .controlSize(.large)
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .task(id: clockTaskID) { await runPlayer() }
        .task(id: isReconnecting) { await reconnectWatchdog() }
        .onDisappear {
            if cinemaSession.presentationState == .closed {
                controller?.stop()
                cinemaSession.clear()
                realityTheaterSession.clear()
                Task { @MainActor in await dismissImmersiveSpace() }
            }
        }
    }

    @MainActor
    private func makeController() -> PlaybackController {
        let playback = controllerFactory()
        playback.onAdvanceToNext = onRequestPlay
        playback.onPlaybackEnded = onClose
        playback.onPlaybackActive = { isReconnecting = false }
        return playback
    }

    private func runPlayer() async {
        await MainActor.run {
            let playback = makeController()
            controller = playback
            cinemaSession.activate(title: item.title, controller: playback)
            refreshScrubberClock(from: playback)
            playback.start()
            Task { @MainActor in
                _ = await playback.loadChaptersIfNeeded()
            }
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                if let controller {
                    refreshScrubberClock(from: controller)
                }
            }
        }
    }

    @MainActor
    private func refreshScrubberClock(from controller: PlaybackController) {
        tickCustomScrubberClock(&scrubState, from: controller, fallbackDurationMs: item.duration ?? 0)
    }

    @MainActor
    private func retry(_ controller: PlaybackController) {
        isReconnecting = true
        controller.retry()
    }

    private func reconnectWatchdog() async {
        guard isReconnecting else { return }
        try? await Task.sleep(for: .seconds(20))
        await MainActor.run {
            guard isReconnecting, let controller else { return }
            isReconnecting = false
            controller.surfaceReconnectTimeout()
        }
    }
}

/// Minimal UIKit bridge whose backing layer is AVPlayerLayer.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> UIView {
        let view = PlayerLayerHostView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let hostView = uiView as? PlayerLayerHostView else { return }
        hostView.playerLayer.player = player
    }
}

private final class PlayerLayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
