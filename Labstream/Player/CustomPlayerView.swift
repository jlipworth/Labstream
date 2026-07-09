import AVFoundation
import PMSKit
import SwiftUI
#if os(macOS)
import AppKit
import QuartzCore
#elseif canImport(UIKit)
import UIKit
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
    #if os(iOS) || os(macOS)
    /// Only read to build the authenticated Now Playing artwork request; the player
    /// itself never touches browse state.
    @Environment(AppModel.self) private var appModel
    #endif
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
    #if os(iOS)
    @State private var mobileSystemCoordinator = MobilePlayerSystemCoordinator()
    @State private var mobileOrientationCoordinator = MobilePlayerOrientationCoordinator()
    #endif
    #if os(macOS)
    @State private var macSystemCoordinator = MacPlayerSystemCoordinator()
    #endif

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
                #if os(iOS)
                PlayerLayerView(player: controller?.player,
                                mobileSystemCoordinator: mobileSystemCoordinator)
                    .ignoresSafeArea()
                    // The AVPlayerLayer itself has no tappable affordances. Keep it out of
                    // hit-testing so the player-surface tap catcher and chrome controls have
                    // deterministic priority on iPhone/iPad.
                    .allowsHitTesting(false)
                #else
                PlayerLayerView(player: controller?.player)
                    .ignoresSafeArea()
                #endif

                if let controller {
                    #if os(iOS)
                    CustomPlayerChrome(controller: controller,
                                       title: item.title,
                                       scrubState: $scrubState,
                                       trickPlayProvider: trickPlayProvider,
                                       mobileSystemCoordinator: mobileSystemCoordinator,
                                       onRetry: { controller.retry() },
                                       onClose: onClose,
                                       allowsRealityTheater: allowsRealityTheater)
                    #else
                    CustomPlayerChrome(controller: controller,
                                       title: item.title,
                                       scrubState: $scrubState,
                                       trickPlayProvider: trickPlayProvider,
                                       onRetry: { controller.retry() },
                                       onClose: onClose,
                                       allowsRealityTheater: allowsRealityTheater)
                    #endif
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
        #if os(iOS)
        .onAppear {
            mobileOrientationCoordinator.enterLandscapeIfNeeded()
        }
        #endif
        .onDisappear {
            #if os(iOS)
            mobileSystemCoordinator.teardown()
            mobileOrientationCoordinator.restoreIfNeeded()
            #endif
            #if os(macOS)
            macSystemCoordinator.teardown()
            #endif
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
            // backgrounds; otherwise ordinary in-app video pauses on background. The same
            // authenticated transcode request the browse grids use gives Now Playing a
            // lock-screen poster at roughly card size.
            let artworkRequest = MediaArtwork.imageRequest(path: item.thumb,
                                                           appModel: appModel,
                                                           pixelWidth: 600,
                                                           pixelHeight: 900)
            mobileSystemCoordinator.configure(controller: playback, item: item,
                                              artworkRequest: artworkRequest)
            #endif
            #if os(macOS)
            let artworkRequest = MediaArtwork.imageRequest(path: item.thumb,
                                                           appModel: appModel,
                                                           pixelWidth: 600,
                                                           pixelHeight: 900)
            macSystemCoordinator.configure(controller: playback, item: item,
                                           artworkRequest: artworkRequest)
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
                    #if os(iOS)
                    mobileSystemCoordinator.updateNowPlayingInfo()
                    #endif
                    #if os(macOS)
                    macSystemCoordinator.updateNowPlayingInfo()
                    #endif
                }
            }
        }
    }

    @MainActor
    private func refreshScrubberClock(from controller: PlaybackController) {
        tickCustomScrubberClock(&scrubState, from: controller, fallbackDurationMs: item.duration ?? 0)
    }
}

#if os(macOS)
/// Minimal AppKit bridge whose backing layer is AVPlayerLayer.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.videoGravity = .resizeAspect
        view.setPlayer(player)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerHostView, context: Context) {
        nsView.setPlayer(player)
    }
}

final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()
    private var loggedZeroSizedLayer = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayerHost()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayerHost()
    }

    func setPlayer(_ player: AVPlayer?) {
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
        NSLog("LabstreamMacPlayerLayer: player %@", player == nil ? "detached" : "attached")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()

        if bounds.width < 2 || bounds.height < 2 {
            if !loggedZeroSizedLayer {
                loggedZeroSizedLayer = true
                NSLog("LabstreamMacPlayerLayer: zero-sized AVPlayerLayer bounds=%@", NSStringFromRect(bounds))
            }
        } else if loggedZeroSizedLayer {
            loggedZeroSizedLayer = false
            NSLog("LabstreamMacPlayerLayer: AVPlayerLayer bounds restored=%@", NSStringFromRect(bounds))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NSLog("LabstreamMacPlayerLayer: view %@", window == nil ? "detached from window" : "attached to window")
    }

    private func configureLayerHost() {
        // Layer-HOSTING contract: assign the custom layer BEFORE wantsLayer, or AppKit treats the
        // view as merely layer-backed and may manage/replace the layer tree it thinks it owns.
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.addSublayer(playerLayer)
        layer = rootLayer
        wantsLayer = true
    }
}
#else
/// Minimal UIKit bridge whose backing layer is AVPlayerLayer.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    #if os(iOS)
    var mobileSystemCoordinator: MobilePlayerSystemCoordinator?
    #endif

    func makeUIView(context: Context) -> UIView {
        let view = PlayerLayerHostView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        #if os(iOS)
        mobileSystemCoordinator?.attach(playerLayer: view.playerLayer)
        #endif
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let hostView = uiView as? PlayerLayerHostView else { return }
        hostView.playerLayer.player = player
        #if os(iOS)
        mobileSystemCoordinator?.attach(playerLayer: hostView.playerLayer)
        #endif
    }
}

private final class PlayerLayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
#endif
