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
    @Environment(MusicPlayerController.self) private var musicPlayer
    /// Only read to resolve an authority-fenced artwork descriptor; playback transport remains
    /// independent from browse state.
    @Environment(AppModel.self) private var appModel
    @Environment(\.artworkPipeline) private var artworkPipeline
    #if os(visionOS)
    @Environment(CustomCinemaSessionStore.self) private var cinemaSession
    @Environment(WatchTogetherCoordinator.self) private var watchTogetherCoordinator
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif

    private let item: MediaItem
    private let controllerFactory: @MainActor () -> PlaybackController
    private let trickPlayProvider: (any TrickPlayThumbnailProviding)?
    private var offlineArtworkSource: OfflineArtworkSource?
    private var isLocalPlayback: Bool
    private let onClose: (() -> Void)?
    private let onRequestPlay: ((MediaItem) -> Void)?
    #if os(visionOS)
    /// Where this playback was launched from, recorded on the Cinema session so exit returns to the
    /// origin instead of always Home detail (#87).
    private var cinemaOrigin: CinemaOrigin
    #endif

    @State private var controller: PlaybackController?
    @State private var scrubState: PlaybackScrubState
    @State private var clockTaskID = UUID()
    #if os(iOS)
    private var mobileOrientationCoordinator: MobilePlayerOrientationCoordinator
    @State private var mobileSystemCoordinator: MobilePlayerSystemCoordinator?
    @AppStorage(PlaybackPreferences.Keys.mobileVideoDisplayMode)
    private var mobileVideoDisplayModeRaw = MobileVideoDisplayMode.fit.rawValue
    #endif
    #if os(macOS)
    @State private var macSystemCoordinator: MacPlayerSystemCoordinator?
    #endif
    #if os(visionOS)
    @State private var watchTogetherAttachTask: Task<Void, Never>?
    /// The coordinator's `playerLaunchEpoch` captured when this view's controller was created.
    /// Presented back on attach and dismissal so the coordinator can tell whether this player
    /// belongs to the current SharePlay launch or is a superseded pre-launch player.
    @State private var watchTogetherLaunchEpoch: UInt64?
    #endif

    init(item: MediaItem,
         controllerFactory: @escaping @MainActor () -> PlaybackController,
         trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
         onClose: (() -> Void)? = nil,
         onRequestPlay: ((MediaItem) -> Void)? = nil) {
        self.item = item
        self.controllerFactory = controllerFactory
        self.trickPlayProvider = trickPlayProvider
        self.offlineArtworkSource = nil
        self.isLocalPlayback = false
        #if os(visionOS)
        self.cinemaOrigin = .systemEntry
        #endif
        self.onClose = onClose
        self.onRequestPlay = onRequestPlay
        #if os(iOS)
        self.mobileOrientationCoordinator = MobilePlayerOrientationCoordinator()
        #endif
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
         offlineArtworkSource: OfflineArtworkSource? = nil,
         offlineTextSubtitles: [OfflineTextSubtitleTrack] = [],
         offlineChapterImageURLs: [Int: URL] = [:],
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
                  onClose: onClose,
                  onRequestPlay: nil)
        self.offlineArtworkSource = offlineArtworkSource
        self.isLocalPlayback = true
        #if os(visionOS)
        // A local file is always an offline origin; default to the item's own ratingKey (#87).
        cinemaOrigin = .offline(ratingKey: item.ratingKey)
        #endif
    }

    #if os(iOS)
    /// Shares the detail surface's player-session orientation owner with each player instance.
    /// The API only exists in the mobile product; other platforms do not compile orientation
    /// ownership or a source-compatible no-op substitute.
    func withMobileOrientationCoordinator(_ coordinator: MobilePlayerOrientationCoordinator) -> CustomPlayerView {
        var copy = self
        copy.mobileOrientationCoordinator = coordinator
        return copy
    }
    #endif

    #if os(visionOS)
    /// Override the visionOS Cinema return route without carrying a spatial-only initializer
    /// argument in the iOS, macOS, or tvOS product interfaces.
    func withCinemaOrigin(_ origin: CinemaOrigin) -> CustomPlayerView {
        var copy = self
        copy.cinemaOrigin = origin
        return copy
    }
    #endif

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
                                displayMode: mobileVideoDisplayMode,
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
                                       mobileVideoDisplayMode: mobileVideoDisplayModeBinding,
                                       mobileSystemCoordinator: mobileSystemCoordinator,
                                       onRetry: { controller.retry() },
                                       onClose: onClose == nil ? nil : { requestPlayerClose() })
                    #else
                    CustomPlayerChrome(controller: controller,
                                       title: item.title,
                                       scrubState: $scrubState,
                                       trickPlayProvider: trickPlayProvider,
                                       onRetry: { controller.retry() },
                                       onClose: onClose)
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
            mobileSystemCoordinator?.teardown()
            mobileOrientationCoordinator.restoreIfNeeded()
            #endif
            #if os(macOS)
            macSystemCoordinator?.teardown()
            #endif
            #if os(visionOS)
            watchTogetherAttachTask?.cancel()
            watchTogetherAttachTask = nil
            if cinemaSession.presentationState == .closed {
                // An actual player dismissal (including single-item playback ending/advancing)
                // leaves SharePlay so peers never retain a ghost participant. The Cinema handoff
                // sets a non-closed presentation state before this view disappears, so it keeps
                // the session and live PlaybackController coordinated in the immersive scaffold.
                watchTogetherCoordinator.leaveIfPlaying(item, playerLaunchEpoch: watchTogetherLaunchEpoch)
                controller?.stop()
                cinemaSession.clear()
                Task { @MainActor in await dismissImmersiveSpace() }
            }
            #else
            // Non-vision platforms have no Cinema handoff. A disappearing player owns its
            // controller outright, matching the old compatibility store's always-closed fallback.
            controller?.stop()
            #endif
        }
    }

    #if os(iOS)
    private var mobileVideoDisplayMode: MobileVideoDisplayMode {
        MobileVideoDisplayMode.persisted(mobileVideoDisplayModeRaw)
    }

    private var mobileVideoDisplayModeBinding: Binding<MobileVideoDisplayMode> {
        Binding(get: { mobileVideoDisplayMode },
                set: { mobileVideoDisplayModeRaw = $0.rawValue })
    }
    #endif

    private func runPlayer() async {
        await MainActor.run {
            let playback = controllerFactory()
            playback.onAdvanceToNext = onRequestPlay
            playback.onPlaybackEnded = onClose == nil ? nil : { requestPlayerClose() }
            controller = playback
            let artworkDescriptor = PlayerArtworkDescriptorPolicy.descriptor(
                isLocalPlayback: isLocalPlayback,
                offlineSource: offlineArtworkSource,
                path: item.thumb ?? item.art,
                appModel: appModel,
                pixelWidth: 600,
                pixelHeight: 900)
            playback.configureExternalArtwork(descriptor: artworkDescriptor,
                                              pipeline: artworkPipeline)
            #if os(iOS)
            // Keep playing into the PiP window or an active AirPlay route when the app
            // backgrounds; otherwise ordinary in-app video pauses on background. The same
            // authenticated transcode request the browse grids use gives Now Playing a
            // lock-screen poster at roughly card size.
            let systemCoordinator = MobilePlayerSystemCoordinator(
                mediaSession: musicPlayer.systemMediaSessionCoordinator)
            mobileSystemCoordinator = systemCoordinator
            systemCoordinator.configure(controller: playback,
                                        item: item,
                                        artworkDescriptor: artworkDescriptor,
                                        artworkPipeline: artworkPipeline)
            #endif
            #if os(macOS)
            let systemCoordinator = MacPlayerSystemCoordinator(
                mediaSession: musicPlayer.systemMediaSessionCoordinator)
            macSystemCoordinator = systemCoordinator
            systemCoordinator.configure(controller: playback,
                                         item: item,
                                         artworkDescriptor: artworkDescriptor,
                                         artworkPipeline: artworkPipeline)
            #endif
            #if os(visionOS)
            // Capture the launch epoch in the same synchronous block that mints the controller: a
            // SharePlay launch that lands after this point supersedes THIS player, and the stale
            // epoch is what lets the coordinator recognize that on attach and dismissal.
            let launchEpoch = watchTogetherCoordinator.playerLaunchEpoch
            watchTogetherLaunchEpoch = launchEpoch
            cinemaSession.activate(title: item.title,
                                   item: item,
                                   origin: cinemaOrigin,
                                   controller: playback,
                                   geometry: CustomCinemaGeometry(item: item,
                                                                  mediaIndex: playback.mediaIndex),
                                   trickPlayProvider: trickPlayProvider,
                                   watchTogetherLaunchEpoch: launchEpoch)
            #endif
            refreshScrubberClock(from: playback)
            playback.start()
            #if os(visionOS)
            watchTogetherAttachTask?.cancel()
            watchTogetherAttachTask = Task { @MainActor in
                await attachWatchTogetherCoordinatorWhenReady(for: playback, launchEpoch: launchEpoch)
            }
            #endif
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
                    mobileSystemCoordinator?.updateNowPlayingInfo()
                    #endif
                    #if os(macOS)
                    macSystemCoordinator?.updateNowPlayingInfo()
                    #endif
                }
            }
        }
    }

    @MainActor
    private func refreshScrubberClock(from controller: PlaybackController) {
        tickCustomScrubberClock(&scrubState, from: controller, fallbackDurationMs: item.duration ?? 0)
    }

    @MainActor
    private func requestPlayerClose() {
        #if os(iOS)
        Task { @MainActor in
            await mobileOrientationCoordinator.restoreBeforeDismissal()
            onClose?()
        }
        #else
        onClose?()
        #endif
    }

    #if os(visionOS)
    @MainActor
    private func attachWatchTogetherCoordinatorWhenReady(for playback: PlaybackController,
                                                         launchEpoch: UInt64) async {
        await maintainWatchTogetherAttachment(coordinator: watchTogetherCoordinator,
                                              controller: playback,
                                              item: item,
                                              launchEpoch: launchEpoch) { controller === playback }
    }
    #endif
}

/// Offline playback is a strict provenance boundary: if its persisted side-asset owner or content
/// generation is absent, system metadata remains text-only. It must never reinterpret a persisted
/// thumb path using whichever account happens to be authenticated now.
@MainActor
enum PlayerArtworkDescriptorPolicy {
    static func descriptor(isLocalPlayback: Bool,
                           offlineSource: OfflineArtworkSource?,
                           path: String?,
                           appModel: AppModel,
                           pixelWidth: Int,
                           pixelHeight: Int) -> ArtworkRequestDescriptor? {
        if isLocalPlayback {
            return offlineSource?.descriptor(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
        return MediaArtwork.descriptor(path: path,
                                       appModel: appModel,
                                       pixelWidth: pixelWidth,
                                       pixelHeight: pixelHeight)
    }
}

#if os(visionOS)
/// Keep the group-session playback coordinator bound to `controller.player` for as long as `isOwner`
/// holds. A lifetime observer rather than a bounded poll: the SharePlay session can activate at any
/// time (the user may linger on the FaceTime activation sheet), the first player item can take
/// arbitrarily long to mint on a slow remote transcode decision, and PlaybackController.load()
/// replaces player.currentItem on quality/track switches, retries, and stall recovery — every
/// replacement item must be re-attached or AVPlayerPlaybackCoordinator silently stops syncing it
/// (the delegate pins one AVPlayerItem by identity). Only a SUCCESSFUL attach marks that item done,
/// so a not-yet-consented player retries once participation is granted; losing the session resets so
/// a later session attaches fresh. The `isOwner` predicate lets both the windowed player and the
/// Cinema scaffold run this against the same live controller across a window→immersive handoff
/// without the loop outliving the surface that started it. `launchEpoch` is the coordinator epoch
/// this controller was minted under; a player from a stale epoch (superseded by a SharePlay
/// launch) is refused attachment so it can never race the launch's replacement player.
@MainActor
func maintainWatchTogetherAttachment(coordinator: WatchTogetherCoordinator,
                                     controller: PlaybackController,
                                     item: MediaItem,
                                     launchEpoch: UInt64?,
                                     isOwner: @escaping @MainActor () -> Bool) async {
    var attachedRevision: SharePlayPlaybackAttachmentRevision<ObjectIdentifier>?
    while !Task.isCancelled {
        guard isOwner() else { return }
        if !coordinator.hasActiveSession {
            attachedRevision = nil
        } else if let currentItem = controller.player.currentItem {
            let revision = SharePlayPlaybackAttachmentRevision(
                sessionGeneration: coordinator.playbackSessionGeneration,
                itemID: ObjectIdentifier(currentItem))
            if revision != attachedRevision,
               coordinator.attachPlaybackCoordinatorIfReady(player: controller.player, item: item,
                                                            launchEpoch: launchEpoch) {
                attachedRevision = revision
            }
        }
        try? await Task.sleep(for: .milliseconds(250))
    }
}
#endif

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
    var displayMode: MobileVideoDisplayMode = .fit
    var mobileSystemCoordinator: MobilePlayerSystemCoordinator?
    #endif

    func makeUIView(context: Context) -> UIView {
        let view = PlayerLayerHostView()
        #if os(iOS)
        view.playerLayer.videoGravity = displayMode == .fill ? .resizeAspectFill : .resizeAspect
        #else
        view.playerLayer.videoGravity = .resizeAspect
        #endif
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
        hostView.playerLayer.videoGravity = displayMode == .fill ? .resizeAspectFill : .resizeAspect
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
