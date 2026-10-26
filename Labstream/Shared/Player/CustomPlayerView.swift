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
    @State private var mobileTopSafeInsetLatch = PlayerTopSafeInsetLatch()
    /// The foldable pose from the shell's single source (division region or DEBUG override).
    @Environment(\.duoPose) private var duoPose
    /// The player's measured safe-area layout frame and insets (global space).
    @State private var mobileGeometry: PlayerTopSafeInsetSample?
    /// Width ÷ height of the decoded picture, reported by the player layer's `videoRect`.
    @State private var mobileVideoAspect: Double?
    /// The read-only hinge interaction's status (`MobilePlayerSceneGeometryReader`).
    @State private var mobileHingeStatus: MobilePlayerPoseResolver.HingeStatus = .unavailable
    /// Active occlusion regions (the outer camera island), global space.
    @State private var mobileOcclusions: [CGRect] = []
    #endif
    #if os(macOS)
    @State private var macSystemCoordinator: VideoNowPlayingCore?
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

    #if !os(tvOS)
    /// Shared admitted-launch entry point for Detail and Offline library presentations.
    init(offlineLaunch launch: OfflinePlaybackLaunch,
         trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
         onClose: (() -> Void)? = nil) {
        self.init(localFile: launch.fileURL, item: launch.item,
                  trickPlayProvider: trickPlayProvider ?? launch.makeTrickPlayProvider(),
                  offlineArtworkSource: launch.artworkSource,
                  offlineTextSubtitles: launch.textSubtitles,
                  offlineChapterImageURLs: launch.chapterImageURLs,
                  onLocalPlaybackProgress: { launch.events.progress(positionMs: $0, durationMs: $1) },
                  onLocalPlaybackObserved: { launch.events.playbackObserved() },
                  onLocalPlaybackClose: { launch.events.close(finalSample: .init(positionMs: $0, durationMs: $1)) },
                  onClose: onClose)
        #if os(visionOS)
        cinemaOrigin = .offline(ratingKey: launch.attemptKey.ratingKey)
        #endif
    }
    #endif

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
         onLocalPlaybackObserved: (() -> Void)? = nil,
         onLocalPlaybackClose: ((Int, Int?) -> Void)? = nil,
         onClose: (() -> Void)? = nil) {
        // Version comes from the bundle (#26) so the offline X-Plex-Version can't drift
        // from the marketing version — same source of truth as the main identity.
        let identity = PlatformClientIdentity.make(clientIdentifier: "offline")
        let client = PlexClient(identity: identity)
        self.init(item: item,
                  controllerFactory: {
                      PlaybackController(item: item,
                                         sessionSource: .offline(OfflinePlaybackSession(
                                            fileURL: localFile,
                                            textSubtitles: offlineTextSubtitles,
                                            chapterImageURLs: offlineChapterImageURLs,
                                            onPlaybackProgress: onLocalPlaybackProgress,
                                            onPlaybackObserved: onLocalPlaybackObserved,
                                            onPlaybackClose: onLocalPlaybackClose)),
                                         identity: identity,
                                         client: client)
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

    #if DEBUG
    /// Exercises the same controller factory used when the player mounts, without presenting UI.
    @MainActor
    func makeControllerForP7Testing() -> PlaybackController { controllerFactory() }
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
                                captionAppearance: controller?.captionAppearance,
                                displayMode: mobileVideoDisplayMode,
                                mobileSystemCoordinator: mobileSystemCoordinator,
                                onVideoAspectChange: { aspect in
                                    if mobileVideoAspect != aspect { mobileVideoAspect = aspect }
                                })
                    // Tabletop: the same layer (never a second one) shrinks to the half above
                    // the hinge; every other arrangement keeps it full-bleed.
                    .padding(.bottom, mobileVideoBottomInset)
                    .ignoresSafeArea()
                    // The AVPlayerLayer itself has no tappable affordances. Keep it out of
                    // hit-testing so the player-surface tap catcher and chrome controls have
                    // deterministic priority on iPhone/iPad.
                    .allowsHitTesting(false)
                #elseif os(macOS)
                PlayerLayerView(player: controller?.player,
                                captionAppearance: controller?.captionAppearance,
                                diagnostics: controller?.diagnostics)
                    .ignoresSafeArea()
                #else
                PlayerLayerView(player: controller?.player,
                                captionAppearance: controller?.captionAppearance)
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
                                       mobileLatchedTopSafeInset: CGFloat(mobileTopSafeInsetLatch.latchedTopInset),
                                       mobileArrangement: mobileArrangement,
                                       mobileCaption: mobileCaption,
                                       onRetry: { controller.retry() },
                                       onClose: onClose == nil ? nil : { requestPlayerClose() })
                        // The chrome toggles the status bar with its own visibility. On iPad that
                        // flips the top inset between 0 and the status-bar height, which would
                        // shift the envelope (and centered overlays) on every reveal/hide, so the
                        // top edge stays on the fixed full-screen origin. Leading/trailing/bottom
                        // stay safe. The top chrome clears the top safe area itself: it pads by
                        // the larger of its authored inset and the top inset measured below
                        // (outside this ignore) and latched per viewport size. Phone-class
                        // full-screen scenes are usually landscape-locked (top inset 0), but a
                        // scene that declines the lock, a large display such as the unfolded
                        // iPhone Duo, or an iPad window can play in portrait.
                        .ignoresSafeArea(.container, edges: .top)
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
                // Same stage-1 visual as the controller-owned transport status, so the
                // pre-controller startup wait and the first-start spinner read as one indicator.
                PlayerTransportSpinner()
            }
        }
        // iOS/iPadOS (#258): the black backdrop and AVPlayerLayer above ignore the safe area so the
        // picture can use the whole display, but the chrome is deliberately laid out inside it.
        // That gives every presentation (streaming, Downloads, local-from-Detail) one stable,
        // rounded-corner-safe envelope. Presenters must not add `.ignoresSafeArea()` on iOS, which
        // would erase the insets for the chrome too; Detail's covers use
        // `customPlayerPresentationSafeArea()` to keep their full-bounds behavior elsewhere.
        .task(id: clockTaskID) { await runPlayer() }
        #if os(iOS)
        // Measured in the safe-area layout frame (the chrome above ignores the top edge). The
        // latch is keyed on the full-bounds size (layout size plus insets): hiding the status bar
        // grows this frame by exactly the inset it removes, so keying on `proxy.size` alone would
        // restart the latch on every chrome toggle.
        .onGeometryChange(for: PlayerTopSafeInsetSample.self) { proxy in
            PlayerTopSafeInsetSample(size: proxy.size, insets: proxy.safeAreaInsets,
                                     frame: proxy.frame(in: .global))
        } action: { sample in
            mobileGeometry = sample
            mobileTopSafeInsetLatch.observe(safeAreaWidth: Double(sample.size.width),
                                            safeAreaHeight: Double(sample.size.height),
                                            top: Double(sample.insets.top),
                                            bottom: Double(sample.insets.bottom),
                                            leading: Double(sample.insets.leading),
                                            trailing: Double(sample.insets.trailing))
        }
        // The player's own scene drives the landscape lock and records every geometry change
        // (rotation, window resize, iPhone Duo fold) as a layout-only event.
        .background {
            MobilePlayerSceneGeometryReader(coordinator: mobileOrientationCoordinator,
                                            onHingeStatusChange: { status in
                                                if mobileHingeStatus != status { mobileHingeStatus = status }
                                            })
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background {
            MobilePlayerOcclusionReader(occlusions: $mobileOcclusions)
        }
        .mobilePlayerDisablesVerticalBar()
        .onAppear {
            mobileOrientationCoordinator.enterLandscapeIfNeeded()
        }
        #endif
        .onDisappear {
            #if os(iOS)
            // A fold, rotation or resize must never reach this path: the presenter keeps the
            // cover (and this view) mounted across geometry changes. Recording it makes a
            // dropped presenter visible in a fold run.
            AppDiagnostics.record(.playback, "player.view_disappear", fields: [
                "had_controller": .bool(controller != nil),
            ])
            mobileSystemCoordinator?.teardown()
            mobileOrientationCoordinator.restoreIfNeeded()
            #endif
            #if os(macOS)
            macSystemCoordinator?.teardown()
            #endif
            #if os(visionOS)
            watchTogetherAttachTask?.cancel()
            watchTogetherAttachTask = nil
            if let generation = cinemaSession.handoffGeneration(for: controller) {
                // The coordinator, not window disappearance, owns the transition. Tag this
                // expected handoff with the generation captured for the retained controller so a
                // late callback cannot affect a replacement Cinema session.
                cinemaSession.transitionCoordinator.playerWindowDidDisappear(
                    generation: generation)
            } else {
                // An actual player dismissal (including single-item playback ending/advancing)
                // leaves SharePlay so peers never retain a ghost participant. The Cinema handoff
                // is recognized above by controller identity plus transition generation.
                watchTogetherCoordinator.leaveIfPlaying(item, playerLaunchEpoch: watchTogetherLaunchEpoch)
                controller?.stop()
                cinemaSession.clear(ifOwnedBy: controller)
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

    /// Where the picture and the control group go, from measured geometry and the pose only
    /// (global space). The pose changes layout; playback never hears about it.
    private var mobileArrangement: MobilePlayerArrangement? {
        guard let geometry = mobileGeometry else { return nil }
        let frame = geometry.frame
        let insets = geometry.insets
        let bounds = CGRect(x: frame.minX - insets.leading, y: frame.minY - insets.top,
                            width: frame.width + insets.leading + insets.trailing,
                            height: frame.height + insets.top + insets.bottom)
        // The top edge sits at the latched inset, so a status-bar toggle never moves the group.
        let top = bounds.minY + max(CGFloat(mobileTopSafeInsetLatch.latchedTopInset), insets.top)
        let safe = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top))
        let pose = MobilePlayerPoseResolver.resolve(shellPose: duoPose, hingeStatus: mobileHingeStatus,
                                                    bounds: bounds)
        return MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: safe, pose: pose,
                                               videoAspect: mobileVideoAspect,
                                               fillsScreen: mobileVideoDisplayMode == .fill,
                                               occlusions: mobileOcclusions)
    }

    private var mobileVideoBottomInset: CGFloat {
        guard let arrangement = mobileArrangement, arrangement.mode == .tabletop else { return 0 }
        let fullHeight = mobileGeometry.map { $0.frame.height + $0.insets.top + $0.insets.bottom } ?? 0
        return max(0, fullHeight - arrangement.videoFrame.height)
    }

    /// "S1, E5" for an episode, the year for anything else.
    private var mobileCaption: String? {
        MediaDetailCaptions.episodeReference(item) ?? item.year.map(String.init)
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
            let systemCoordinator = VideoNowPlayingCore(
                commandProfile: .processWide(fallbackSeconds: 30),
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

#if os(iOS)
struct PlayerTopSafeInsetSample: Equatable {
    let size: CGSize
    let insets: EdgeInsets
    var frame: CGRect = .zero
}

/// Reads the active occlusion regions (the outer display's camera island) for the player, in the
/// global space, so the bottom control group can end before the island in tent and folded
/// landscape. Never hardcoded: the regions come from `reservedRegions(kind: .occlusion)`.
private struct MobilePlayerOcclusionReader: View {
    @Binding var occlusions: [CGRect]

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: Self.regions(in: proxy), initial: true) { _, regions in
                    if occlusions != regions { occlusions = regions }
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func regions(in proxy: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        let origin = proxy.frame(in: .global).origin
        return proxy.reservedRegions(kind: .occlusion)
            .filter(\.isActive)
            .map { $0.frame.offsetBy(dx: origin.x, dy: origin.y) }
    }
}

private extension MobileVideoDisplayMode {
    var videoGravity: AVLayerVideoGravity {
        self == .fill ? .resizeAspectFill : .resizeAspect
    }
}

private extension View {
    /// Full-screen video opts out of the iOS 27.1 vertical bar (Apple's guidance for full-screen
    /// players): the player has no tab bar or toolbar, and the status bar returns to the
    /// horizontal axis, where the chrome's latched top inset clears it.
    @ViewBuilder
    func mobilePlayerDisablesVerticalBar() -> some View {
        if #available(iOS 27.1, *) {
            toolbarVerticalBehavior(.disabled)
        } else {
            self
        }
    }
}
#endif

extension View {
    /// The presenter-side safe-area rule for `CustomPlayerView` (#258). On visionOS, tvOS, and
    /// macOS the call sites that used `.ignoresSafeArea()` keep exactly that behavior. On
    /// iOS/iPadOS this is a no-op: the player keeps its backdrop and picture full-bleed
    /// internally and lays its chrome out in the safe area.
    @ViewBuilder
    func customPlayerPresentationSafeArea() -> some View {
        #if os(iOS)
        self
        #else
        ignoresSafeArea()
        #endif
    }
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
    var captionAppearance: CaptionAppearanceController? = nil
    var diagnostics: PlaybackDiagnostics? = nil

    final class Coordinator {
        weak var captionAppearance: CaptionAppearanceController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.videoGravity = .resizeAspect
        view.setPlayer(player)
        view.displayDiagnostics = diagnostics
        captionAppearance?.attachPlayerLayer(view.playerLayer)
        context.coordinator.captionAppearance = captionAppearance
        return view
    }

    func updateNSView(_ nsView: PlayerLayerHostView, context: Context) {
        nsView.setPlayer(player)
        nsView.displayDiagnostics = diagnostics
        captionAppearance?.attachPlayerLayer(nsView.playerLayer)
        context.coordinator.captionAppearance = captionAppearance
    }

    static func dismantleNSView(_ nsView: PlayerLayerHostView, coordinator: Coordinator) {
        coordinator.captionAppearance?.stopPreview()
        coordinator.captionAppearance?.attachPlayerLayer(nil)
        nsView.stopDisplayObservation()
        nsView.playerLayer.player = nil
    }
}

final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()
    private var loggedZeroSizedLayer = false
    weak var displayDiagnostics: PlaybackDiagnostics? {
        didSet { scheduleDisplayRefresh() }
    }
    private var displayObservers: [NSObjectProtocol] = []

    func stopDisplayObservation() {
        displayObservers.forEach(NotificationCenter.default.removeObserver)
        displayObservers.removeAll()
        displayDiagnostics?.applyHDRDisplayScreen(potentialEDR: nil, currentEDR: nil)
        displayDiagnostics = nil
    }

    private func scheduleDisplayRefresh() {
        // Avoid publishing Observable changes synchronously inside SwiftUI's view update.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let screen = self.window?.screen
            self.displayDiagnostics?.applyHDRDisplayEligibility(AVPlayer.eligibleForHDRPlayback)
            self.displayDiagnostics?.applyHDRDisplayScreen(
                potentialEDR: screen.map { Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue) },
                currentEDR: screen.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) })
        }
    }


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
        displayObservers.forEach(NotificationCenter.default.removeObserver)
        displayObservers.removeAll()
        if let window {
            for (name, object) in [
                (NSWindow.didChangeScreenNotification, window as AnyObject?),
                (NSApplication.didChangeScreenParametersNotification, nil),
                (AVPlayer.eligibleForHDRPlaybackDidChangeNotification, nil)
            ] {
                displayObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: object, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.scheduleDisplayRefresh() }
                })
            }
        }
        scheduleDisplayRefresh()
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
    var captionAppearance: CaptionAppearanceController? = nil
    #if os(iOS)
    var displayMode: MobileVideoDisplayMode = .fit
    var mobileSystemCoordinator: MobilePlayerSystemCoordinator?
    /// Reports the decoded picture's aspect (width ÷ height) from the layer's `videoRect`.
    var onVideoAspectChange: ((Double) -> Void)?
    #endif

    final class Coordinator {
        weak var captionAppearance: CaptionAppearanceController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = PlayerLayerHostView()
        #if os(iOS)
        view.applyVideoGravity(displayMode.videoGravity)
        #else
        view.playerLayer.videoGravity = .resizeAspect
        #endif
        view.playerLayer.player = player
        captionAppearance?.attachPlayerLayer(view.playerLayer)
        context.coordinator.captionAppearance = captionAppearance
        #if os(iOS)
        mobileSystemCoordinator?.attach(playerLayer: view.playerLayer)
        view.onVideoAspectChange = onVideoAspectChange
        #endif
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let hostView = uiView as? PlayerLayerHostView else { return }
        hostView.playerLayer.player = player
        captionAppearance?.attachPlayerLayer(hostView.playerLayer)
        context.coordinator.captionAppearance = captionAppearance
        #if os(iOS)
        hostView.applyVideoGravity(displayMode.videoGravity)
        mobileSystemCoordinator?.attach(playerLayer: hostView.playerLayer)
        hostView.onVideoAspectChange = onVideoAspectChange
        #endif
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.captionAppearance?.stopPreview()
        coordinator.captionAppearance?.attachPlayerLayer(nil)
        guard let hostView = uiView as? PlayerLayerHostView else { return }
        hostView.playerLayer.player = nil
    }
}

private final class PlayerLayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    #if os(iOS)
    /// Mutates the gravity of the one live layer in place, only when it changes, and without an
    /// implicit Core Animation action, so a Fit/Fill change or an update that coincides with a
    /// rotation, resize or fold never animates the crop or replaces the layer.
    func applyVideoGravity(_ gravity: AVLayerVideoGravity) {
        guard playerLayer.videoGravity != gravity else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.videoGravity = gravity
        CATransaction.commit()
    }
    #endif

    #if os(iOS)
    var onVideoAspectChange: ((Double) -> Void)?
    private var videoRectObservation: NSKeyValueObservation?
    private var lastReportedAspect: Double?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        videoRectObservation = window == nil ? nil : playerLayer.observe(\.videoRect,
                                                                         options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.videoRectDidChange()
            }
        }
    }

    private func videoRectDidChange() {
        #if DEBUG
        if PlayerGeometryProbe.isEnabled { PlayerGeometryProbe.recordVideoRect(playerLayer) }
        #endif
        let rect = playerLayer.videoRect
        guard rect.width > 0, rect.height > 0 else { return }
        // Rounded so layer resizes (a fold, a rotation) never re-report the same picture.
        let aspect = (Double(rect.width / rect.height) * 100).rounded() / 100
        guard aspect != lastReportedAspect else { return }
        lastReportedAspect = aspect
        onVideoAspectChange?(aspect)
    }
    #endif
}
#endif
