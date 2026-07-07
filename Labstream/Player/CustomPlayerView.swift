import AVFoundation
import PMSKit
import SwiftUI
import UIKit
#if os(iOS)
import AVKit
#endif

/// The app's video player: app-owned chrome + scrubber over an `AVPlayerLayer` presenter.
///
/// This is now the ONLY video player. The former AVKit `AVPlayerViewController` path — and the
/// default-off Settings toggle that used to route to this view — have been removed. The
/// app-owned scrubber gives deterministic seek intent and avoids the native AVKit control/chrome
/// seek weirdness that motivated the switch.
struct CustomPlayerView: View {
    @Environment(CustomCinemaSessionStore.self) private var cinemaSession
    @Environment(RealityTheaterSessionStore.self) private var realityTheaterSession
    #if os(visionOS)
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif

    private let item: MediaItem
    private let controllerFactory: @MainActor () -> PlaybackController
    private let trickPlayProvider: (any TrickPlayThumbnailProviding)?
    private let onClose: (() -> Void)?
    private let onRequestPlay: ((MediaItem) -> Void)?
    private let allowsRealityTheater: Bool
    /// Where this playback was launched from, recorded on the Cinema session so exit returns to the
    /// origin instead of always Home detail (#87).
    private let cinemaOrigin: CinemaOrigin

    @State private var controller: PlaybackController?
    @State private var scrubState: PlaybackScrubState
    @State private var clockTaskID = UUID()
    /// Drives the iOS window player's Picture in Picture button. Inert on visionOS (the
    /// Cinema/Theater surfaces reuse `PlayerLayerView` but never spin up a PiP controller).
    @State private var pipCoordinator = PlayerPiPCoordinator()

    init(item: MediaItem,
         controllerFactory: @escaping @MainActor () -> PlaybackController,
         trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
         cinemaOrigin: CinemaOrigin = .systemEntry,
         onClose: (() -> Void)? = nil,
         onRequestPlay: ((MediaItem) -> Void)? = nil,
         allowsRealityTheater: Bool = false) {
        self.item = item
        self.controllerFactory = controllerFactory
        self.trickPlayProvider = trickPlayProvider
        self.cinemaOrigin = cinemaOrigin
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
    init(localFile: URL,
         item: MediaItem,
         trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
         offlineTextSubtitles: [OfflineTextSubtitleTrack] = [],
         offlineChapterImageURLs: [Int: URL] = [:],
         cinemaOrigin: CinemaOrigin? = nil,
         onLocalPlaybackProgress: ((Int, Int?) -> Void)? = nil,
         onClose: (() -> Void)? = nil) {
        // Version comes from the bundle (#26) so the offline X-Plex-Version can't drift
        // from the marketing version — same source of truth as the main identity.
        let identity = PlatformClientIdentity.make(clientIdentifier: "offline")
        let client = PlexClient(identity: identity)
        self.init(item: item,
                  controllerFactory: {
                      PlaybackController(localFile: localFile,
                                         item: item,
                                         identity: identity,
                                         client: client,
                                         offlineTextSubtitles: offlineTextSubtitles,
                                         offlineChapterImageURLs: offlineChapterImageURLs,
                                         onLocalPlaybackProgress: onLocalPlaybackProgress)
                  },
                  trickPlayProvider: trickPlayProvider,
                  // A local file is always an offline origin; default to the item's own ratingKey
                  // when the caller doesn't pass an explicit one (#87).
                  cinemaOrigin: cinemaOrigin ?? .offline(ratingKey: item.ratingKey),
                  onClose: onClose,
                  onRequestPlay: nil,
                  allowsRealityTheater: true)
    }

    var body: some View {
        #if os(visionOS)
        let isDetachedToCinema = cinemaSession.presentationState != .closed
        #else
        let isDetachedToCinema = false
        #endif

        ZStack {
            (isDetachedToCinema ? Color.clear : Color.black)
                .ignoresSafeArea()

            if !isDetachedToCinema {
                PlayerLayerView(player: controller?.player, pipCoordinator: pipCoordinator)
                    .ignoresSafeArea()

                if let controller {
                    CustomPlayerChrome(controller: controller,
                                       title: item.title,
                                       scrubState: $scrubState,
                                       trickPlayProvider: trickPlayProvider,
                                       pipCoordinator: pipCoordinator,
                                       onRetry: { controller.retry() },
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
        .onDisappear {
            if cinemaSession.presentationState == .closed {
                controller?.stop()
                cinemaSession.clear()
                realityTheaterSession.clear()
                #if os(visionOS)
                Task { @MainActor in await dismissImmersiveSpace() }
                #endif
            }
        }
    }

    private func runPlayer() async {
        await MainActor.run {
            let playback = controllerFactory()
            playback.onAdvanceToNext = onRequestPlay
            playback.onPlaybackEnded = onClose
            controller = playback
            #if os(iOS)
            // Keep playing into the PiP window or an active AirPlay route when the app
            // backgrounds; otherwise the coordinator's resign-active pause is correct for
            // ordinary in-app video.
            playback.suppressBackgroundPause = { [pipCoordinator, weak playback] in
                pipCoordinator.isActive || playback?.player.isExternalPlaybackActive == true
            }
            #endif
            #if os(visionOS)
            cinemaSession.activate(title: item.title,
                                   item: item,
                                   origin: cinemaOrigin,
                                   controller: playback,
                                   geometry: CustomCinemaGeometry(item: item,
                                                                  mediaIndex: playback.mediaIndex),
                                   trickPlayProvider: trickPlayProvider)
            #endif
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
}

/// Minimal UIKit bridge whose backing layer is AVPlayerLayer.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    /// iOS window path only: the coordinator that hangs a PiP controller off this layer.
    /// The visionOS Cinema/Theater callers leave it nil so no PiP controller is created.
    var pipCoordinator: PlayerPiPCoordinator? = nil

    func makeUIView(context: Context) -> UIView {
        let view = PlayerLayerHostView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        #if os(iOS)
        pipCoordinator?.attach(to: view.playerLayer)
        #endif
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let hostView = uiView as? PlayerLayerHostView else { return }
        hostView.playerLayer.player = player
        #if os(iOS)
        pipCoordinator?.attach(to: hostView.playerLayer)
        #endif
    }
}

private final class PlayerLayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

/// Owns the iOS Picture in Picture controller for the window player.
///
/// PiP is only meaningful for the iOS window path — the visionOS Cinema/Theater surfaces
/// reuse `PlayerLayerView` but must not spin up a PiP controller — so all AVKit wiring
/// lives behind `#if os(iOS)`. The cross-platform `isPossible`/`isActive` flags let the
/// chrome's own `#if os(iOS)` button react without introducing a second conditional type.
@MainActor
@Observable
final class PlayerPiPCoordinator {
    private(set) var isPossible = false
    private(set) var isActive = false

    #if os(iOS)
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var delegateShim: PiPDelegateShim?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var attachedLayer: AVPlayerLayer?

    /// Hang a PiP controller off the player layer. Idempotent per layer: the representable
    /// calls this on every `updateUIView`, so re-attaching to the same layer is a no-op.
    func attach(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              attachedLayer !== layer,
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        attachedLayer = layer
        let shim = PiPDelegateShim(onStart: { [weak self] in self?.isActive = true },
                                   onStop: { [weak self] in self?.isActive = false })
        controller.delegate = shim
        self.controller = controller
        self.delegateShim = shim
        // `isPictureInPicturePossible` only flips true once an item is ready to render, so
        // observe it to drive the toggle button's visibility instead of polling.
        possibleObservation = controller.observe(\.isPictureInPicturePossible,
                                                 options: [.initial, .new]) { [weak self] ctrl, _ in
            let possible = ctrl.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }
    #endif
}

#if os(iOS)
/// Retained delegate shim: `AVPictureInPictureController.delegate` is weak, so the
/// coordinator holds this strongly. AVKit invokes the delegate on the main thread, so the
/// class is `@MainActor` with a `@preconcurrency` conformance (runtime-asserted isolation).
@MainActor
private final class PiPDelegateShim: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    private let onStart: @MainActor () -> Void
    private let onStop: @MainActor () -> Void

    init(onStart: @escaping @MainActor () -> Void, onStop: @escaping @MainActor () -> Void) {
        self.onStart = onStart
        self.onStop = onStop
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        onStart()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onStop()
    }
}

/// Round AirPlay route picker that matches the chrome's monochrome glass buttons.
struct AirPlayRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.backgroundColor = .clear
        // The chrome tints everything white; keep the AirPlay glyph monochrome in both its
        // idle and active states instead of falling back to the system-accent blue.
        picker.tintColor = .white
        picker.activeTintColor = .white
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
