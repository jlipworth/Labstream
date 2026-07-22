import AVFoundation
import PMSKit
import RealityKit
import SwiftUI

/// User-tunable posture adjustment for the immersive Cinema screen.
///
/// The base geometry still comes from the content aspect ratio; this value stores only the
/// viewer's posture preference so it can be applied consistently as different items enter Cinema.
struct CustomCinemaScreenAdjustment: Equatable, Sendable {
    static let `default` = CustomCinemaScreenAdjustment()
    static let reclinedPreset = CustomCinemaScreenAdjustment(pitchDegrees: 12,
                                                            verticalDeltaMeters: 1.50,
                                                            distanceDeltaMeters: 0)
    static let lyingDownPreset = CustomCinemaScreenAdjustment(pitchDegrees: 42,
                                                             verticalDeltaMeters: 2.80,
                                                             distanceDeltaMeters: -0.35)

    static let pitchDegreesRange: ClosedRange<Float> = (-45)...60
    static let verticalDeltaRange: ClosedRange<Float> = (-1.20)...3.80
    static let distanceDeltaRange: ClosedRange<Float> = (-1.5)...1.0

    private enum DefaultsKey {
        static let pitchDegrees = "cinema.screenAdjustment.pitchDegrees"
        static let verticalDeltaMeters = "cinema.screenAdjustment.verticalDeltaMeters"
        static let distanceDeltaMeters = "cinema.screenAdjustment.distanceDeltaMeters"
    }

    var pitchDegrees: Float = 0
    var verticalDeltaMeters: Float = 0
    var distanceDeltaMeters: Float = 0

    var pitchRadians: Float { pitchDegrees * .pi / 180 }

    var clamped: CustomCinemaScreenAdjustment {
        CustomCinemaScreenAdjustment(
            pitchDegrees: pitchDegrees.clamped(to: Self.pitchDegreesRange),
            verticalDeltaMeters: verticalDeltaMeters.clamped(to: Self.verticalDeltaRange),
            distanceDeltaMeters: distanceDeltaMeters.clamped(to: Self.distanceDeltaRange)
        )
    }

    static func load() -> CustomCinemaScreenAdjustment {
        let defaults = UserDefaults.standard
        return CustomCinemaScreenAdjustment(
            pitchDegrees: Float(defaults.double(forKey: DefaultsKey.pitchDegrees)),
            verticalDeltaMeters: Float(defaults.double(forKey: DefaultsKey.verticalDeltaMeters)),
            distanceDeltaMeters: Float(defaults.double(forKey: DefaultsKey.distanceDeltaMeters))
        ).clamped
    }

    func persist() {
        let value = clamped
        let defaults = UserDefaults.standard
        defaults.set(Double(value.pitchDegrees), forKey: DefaultsKey.pitchDegrees)
        defaults.set(Double(value.verticalDeltaMeters), forKey: DefaultsKey.verticalDeltaMeters)
        defaults.set(Double(value.distanceDeltaMeters), forKey: DefaultsKey.distanceDeltaMeters)
    }
}

/// Meter-based layout snapshot for the custom-player Cinema scene.
struct CustomCinemaGeometry: Equatable, Sendable {
    static let `default` = CustomCinemaGeometry(aspectRatio: 16.0 / 9.0)

    /// The active picture aspect ratio, clamped to sane flat-video bounds. The old Cinema
    /// scene hard-coded a 16:9 plane, which made 16:9 content feel too close while narrower
    /// 4:3-ish content happened to feel better. This snapshot lets the immersive plane and its
    /// hit target match the actual content instead of one fixed wall.
    var aspectRatio: Float
    var screenWidthMeters: Float
    var screenDistanceMeters: Float
    var verticalOffsetMeters: Float
    var pitchRadians: Float

    init(aspectRatio rawAspectRatio: Float,
         screenWidthMeters: Float? = nil,
         screenDistanceMeters: Float? = nil,
         verticalOffsetMeters: Float? = nil,
         pitchRadians: Float? = nil) {
        let aspect = rawAspectRatio.isFinite ? rawAspectRatio.clamped(to: 1.0...2.76) : 16.0 / 9.0
        self.aspectRatio = aspect

        // Preserve the good 4:3-ish feel, but make 16:9 and scope content a little less
        // face-filling. Values are deliberately conservative because this must be headset-tuned.
        let defaultHeight: Float
        let defaultDistance: Float
        let defaultVertical: Float
        switch aspect {
        case ..<1.55:        // 4:3 / Academy-ish
            defaultHeight = 5.10
            defaultDistance = 6.80
            defaultVertical = 0.55
        case 1.55..<2.05:    // 16:9 / 1.85
            defaultHeight = 4.75
            defaultDistance = 7.75
            defaultVertical = 0.55
        default:             // 2.20 / 2.35 / scope
            defaultHeight = 4.05
            defaultDistance = 7.75
            defaultVertical = 0.48
        }

        let computedWidth = defaultHeight * aspect
        self.screenWidthMeters = (screenWidthMeters ?? computedWidth).clamped(to: 4.2...9.8)
        self.screenDistanceMeters = (screenDistanceMeters ?? defaultDistance).clamped(to: 4.8...9.0)
        self.verticalOffsetMeters = (verticalOffsetMeters ?? defaultVertical).clamped(to: (-1.0)...4.6)
        self.pitchRadians = (pitchRadians ?? 0).clamped(to: (-Float.pi / 4)...(Float.pi / 3))
    }

    init(item: MediaItem, mediaIndex: Int) {
        let aspect: Float? = item.media.flatMap { media in
            let selected = media.indices.contains(mediaIndex) ? media[mediaIndex] : media.first
            guard let width = selected?.width, let height = selected?.height,
                  width > 0, height > 0 else { return nil }
            return Float(width) / Float(height)
        }
        self.init(aspectRatio: aspect ?? 16.0 / 9.0)
    }

    var screenHeightMeters: Float { screenWidthMeters / aspectRatio }
    var screenPosition: SIMD3<Float> { SIMD3<Float>(0, verticalOffsetMeters, -screenDistanceMeters) }

    func applying(_ adjustment: CustomCinemaScreenAdjustment) -> CustomCinemaGeometry {
        let value = adjustment.clamped
        return CustomCinemaGeometry(
            aspectRatio: aspectRatio,
            screenWidthMeters: screenWidthMeters,
            screenDistanceMeters: screenDistanceMeters + value.distanceDeltaMeters,
            verticalOffsetMeters: verticalOffsetMeters + value.verticalDeltaMeters,
            pitchRadians: value.pitchRadians
        )
    }

    var debugSummary: String {
        String(format: "aspect %.2f · width %.1fm · distance %.1fm · vertical %.2fm · pitch %.0f°",
               aspectRatio, screenWidthMeters, screenDistanceMeters, verticalOffsetMeters,
               pitchRadians * 180 / .pi)
    }
}

/// Shared identifiers and active-session state for the custom-player Cinema scaffold.
///
/// Cinema Mode reuses the real SwiftUI player chrome (`CustomPlayerChrome`) hosted as a
/// `RealityView` attachment over the video surface, so the immersive transport is at visual parity
/// with the windowed player instead of the old hand-drawn RealityKit button rail.
///
/// Apple's own `AVPlayerViewController` cinema environment is only reachable through AVKit, which
/// this app deliberately removed — so Cinema Mode stays an app-owned visionOS scene that leans on
/// Apple primitives (`ImmersiveSpace`, `RealityView`, SwiftUI attachments) and renders the same
/// `AVPlayer` the custom player already owns.
///
enum CustomCinemaMode {
    static let immersiveSpaceID = "custom-player-cinema"
    static let mainWindowID = "main-window"

    /// The custom-player "Cinema" scene is visible while we iterate on the immersive theater route.
    static let isUserVisible = true
}

/// The browse tab the current view tree lives under, injected by `RootView` into each browse-tab
/// `NavigationStack` so a shared `DetailView` can record the right Cinema origin on exit (#87).
/// `nil` outside the browse tabs (no online-tab origin to capture).
private struct CinemaOriginTabKey: EnvironmentKey {
    static let defaultValue: CinemaTab? = nil
}

extension EnvironmentValues {
    var cinemaOriginTab: CinemaTab? {
        get { self[CinemaOriginTabKey.self] }
        set { self[CinemaOriginTabKey.self] = newValue }
    }
}

@Observable
@MainActor
final class CustomCinemaSessionStore {
    enum PresentationState: Equatable {
        case closed
        case inTransition
        case open
    }

    var title: String?
    /// The item being played, kept so Exit Cinema can route back to its detail page (the "content
    /// submenu") instead of the app home screen. Preserved across `stopAndClearForImmersiveExit`
    /// (which only tears down the live controller) and only dropped in `clear()`.
    var item: MediaItem?
    /// Where playback was launched from, so Cinema exit returns to the ORIGIN (offline Downloads,
    /// the originating browse tab) instead of always Home detail (#87). Preserved exactly like
    /// `item` — survives `stopAndClearForImmersiveExit`, dropped only in `clear()`.
    var origin: CinemaOrigin = .systemEntry
    var controller: PlaybackController?
    /// The Watch Together `playerLaunchEpoch` the windowed player captured when `controller` was
    /// minted, carried across the Cinema handoff so the immersive scaffold presents the same epoch
    /// on attach/leave. Preserved like `item` across `stopAndClearForImmersiveExit` (the exit's
    /// `leaveIfPlaying` runs before `clear()`), dropped only in `clear()`.
    var watchTogetherLaunchEpoch: UInt64?
    private var baseGeometry: CustomCinemaGeometry = .default
    var geometry: CustomCinemaGeometry = .default
    var screenAdjustment: CustomCinemaScreenAdjustment = .load()
    var trickPlayProvider: (any TrickPlayThumbnailProviding)?
    var presentationState: PresentationState = .closed
    var pendingReturnItem: MediaItem?
    var pendingReturnAutoPlay = false
    /// True when the pending exit is an Up Next advance to a DIFFERENT online item (not a plain
    /// close/playback-ended), so the exit router can special-case autoplay vs. the offline fallback.
    var pendingAdvancingToNext = false

    var player: AVPlayer? { controller?.player }
    var hasActivePlayer: Bool { controller != nil }

    func activate(title: String,
                  item: MediaItem,
                  origin: CinemaOrigin = .systemEntry,
                  controller: PlaybackController,
                  geometry: CustomCinemaGeometry = .default,
                  trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
                  watchTogetherLaunchEpoch: UInt64? = nil) {
        self.title = title
        self.item = item
        self.origin = origin
        self.controller = controller
        self.watchTogetherLaunchEpoch = watchTogetherLaunchEpoch
        baseGeometry = geometry
        screenAdjustment = CustomCinemaScreenAdjustment.load()
        self.geometry = geometry.applying(screenAdjustment)
        self.trickPlayProvider = trickPlayProvider
        pendingReturnItem = nil
        pendingReturnAutoPlay = false
        pendingAdvancingToNext = false
    }

    func prepareExit(returningTo item: MediaItem?, autoPlay: Bool, advancingToNext: Bool) {
        pendingReturnItem = item
        pendingReturnAutoPlay = autoPlay
        pendingAdvancingToNext = advancingToNext
        presentationState = .inTransition
    }

    func updateScreenAdjustment(_ adjustment: CustomCinemaScreenAdjustment) {
        let value = adjustment.clamped
        screenAdjustment = value
        value.persist()
        geometry = baseGeometry.applying(value)
    }

    func nudgeScreenAdjustment(pitchDegrees: Float = 0,
                               verticalDeltaMeters: Float = 0,
                               distanceDeltaMeters: Float = 0) {
        var next = screenAdjustment
        next.pitchDegrees += pitchDegrees
        next.verticalDeltaMeters += verticalDeltaMeters
        next.distanceDeltaMeters += distanceDeltaMeters
        updateScreenAdjustment(next)
    }

    func applyReclinedScreenPreset() {
        updateScreenAdjustment(.reclinedPreset)
    }

    func applyLyingDownScreenPreset() {
        updateScreenAdjustment(.lyingDownPreset)
    }

    func resetScreenAdjustment() {
        updateScreenAdjustment(.default)
    }

    /// Tear down the active playback session before the immersive space is dismissed.
    ///
    /// Cinema deliberately does not preserve or rehydrate the player window — earlier restore hacks
    /// caused Home-screen bugs plus duplicate audio on device. One `AVPlayer` session enters Cinema,
    /// and that same session is stopped before leaving; the exit then routes to the item's detail
    /// page (see the scaffold's `onDisappear`).
    func stopAndClearForImmersiveExit() {
        let activeController = controller
        title = nil
        controller = nil
        trickPlayProvider = nil
        presentationState = .inTransition
        activeController?.stop()
    }

    func clear() {
        title = nil
        item = nil
        origin = .systemEntry
        controller = nil
        watchTogetherLaunchEpoch = nil
        baseGeometry = .default
        geometry = .default.applying(screenAdjustment)
        trickPlayProvider = nil
        pendingReturnItem = nil
        pendingReturnAutoPlay = false
        pendingAdvancingToNext = false
        presentationState = .closed
    }
}

/// Black immersive theater surface for the custom player.
///
/// Cinema Mode renders a single `RealityView` attachment — the real `PlayerLayerView` video surface
/// with the real `CustomPlayerChrome` composited on top — placed and scaled as a cinema screen in a
/// dimmed (`.ultraDark`) immersive space. Co-locating the video and the controls in one attachment
/// gives the immersive transport full parity with the windowed player — the same materials,
/// scrubber with trick-play, and quality/subtitle/audio/speed/chapter/stats menus — for free.
///
/// The screen entity is built once and only repositioned/rescaled; the chrome manages its own
/// reveal/auto-hide and exit. Nothing here rebuilds the entity tree per frame (the previous
/// hand-drawn rail did, which is hostile to attachments).
struct CustomCinemaScaffoldView: View {
    @Environment(CustomCinemaSessionStore.self) private var session
    @Environment(WatchTogetherCoordinator.self) private var watchTogetherCoordinator
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow

    @State private var scrubState = PlaybackScrubState(durationMs: 0, livePositionMs: 0)
    /// Watch Together attach maintenance moves here for the Cinema session: the windowed player's
    /// task is cancelled when its window dismisses for the immersive handoff, but playback (and its
    /// item replacements) continues here, so the coordinator must keep re-attaching from Cinema.
    @State private var watchTogetherAttachTask: Task<Void, Never>?

    /// Holds the live attachment entity so the scrubber clock can re-run placement until RealityKit
    /// has laid the attachment out (and thus reports a real intrinsic size to calibrate against).
    @State private var entityBox = EntityBox()

    private static let screenAttachmentID = "custom-cinema-screen"

    /// Authoring resolution (in points) of the screen attachment. Higher is crisper at cinema
    /// scale, at the cost of attachment-texture memory. The physical size comes from
    /// `CustomCinemaGeometry` via `place(_:geometry:)`, not from this point count — see that method
    /// for why the point count must NOT be treated as meters.
    private static let attachmentWidthPoints: CGFloat = 1920

    var body: some View {
        RealityView { content, attachments in
            if let screen = attachments.entity(for: Self.screenAttachmentID) {
                entityBox.entity = screen
                Self.place(screen, geometry: session.geometry)
                content.add(screen)
            }
        } update: { _, attachments in
            if let screen = attachments.entity(for: Self.screenAttachmentID) {
                entityBox.entity = screen
                Self.place(screen, geometry: session.geometry)
            }
        } attachments: {
            Attachment(id: Self.screenAttachmentID) {
                CustomCinemaScreen(session: session,
                                   scrubState: $scrubState,
                                   onRetry: { session.controller?.retry() },
                                   widthPoints: Self.attachmentWidthPoints)
            }
        }
        .preferredSurroundingsEffect(.ultraDark)
        .onAppear {
            session.presentationState = .open
            bindCinemaCallbacks()
            startWatchTogetherAttachMaintenance()
        }
        .onDisappear {
            watchTogetherAttachTask?.cancel()
            watchTogetherAttachTask = nil
            finishCinemaDismissal()
        }
        .task { await runScrubberClock() }
    }

    private func runScrubberClock() async {
        while !Task.isCancelled {
            await MainActor.run { tick() }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    @MainActor
    private func startWatchTogetherAttachMaintenance() {
        guard let controller = session.controller, let item = session.item else { return }
        watchTogetherAttachTask?.cancel()
        let launchEpoch = session.watchTogetherLaunchEpoch
        watchTogetherAttachTask = Task { @MainActor in
            await maintainWatchTogetherAttachment(coordinator: watchTogetherCoordinator,
                                                  controller: controller,
                                                  item: item,
                                                  launchEpoch: launchEpoch) {
                session.controller === controller && session.presentationState != .closed
            }
        }
    }

    @MainActor
    private func bindCinemaCallbacks() {
        guard let controller = session.controller else { return }
        controller.onAdvanceToNext = { next in
            Task { @MainActor in
                await requestCinemaExit(returningTo: next, autoPlay: true, advancingToNext: true)
            }
        }
        controller.onPlaybackEnded = {
            Task { @MainActor in
                await requestCinemaExit(returningTo: session.item, autoPlay: false, advancingToNext: false)
            }
        }
    }

    @MainActor
    private func requestCinemaExit(returningTo item: MediaItem?, autoPlay: Bool, advancingToNext: Bool) async {
        guard session.presentationState != .inTransition else { return }
        session.prepareExit(returningTo: item ?? session.item, autoPlay: autoPlay,
                            advancingToNext: advancingToNext)
        await dismissImmersiveSpace()
    }

    @MainActor
    private func finishCinemaDismissal() {
        let returnItem = session.pendingReturnItem ?? session.item
        if let sharedItem = session.item {
            // Leaving the immersive player ends this single-item Watch Together participation.
            // This runs only on Cinema exit, never during the window-to-Cinema handoff.
            watchTogetherCoordinator.leaveIfPlaying(sharedItem,
                                                    playerLaunchEpoch: session.watchTogetherLaunchEpoch)
        }
        let destination = CinemaExitRouting.resolve(origin: session.origin,
                                                    hasReturnItem: returnItem != nil,
                                                    autoPlay: session.pendingReturnAutoPlay,
                                                    advancingToNext: session.pendingAdvancingToNext)
        session.stopAndClearForImmersiveExit()
        // Offline never touches the online router (that path is Home + server-fetch only); online
        // origins return to their own tab; system entries keep the legacy Home-detail behavior.
        // Keep the final app composition in a deterministic adapter rather than hiding it in this
        // ImmersiveSpace callback, while PMSKit remains the authority for the routing decision.
        CinemaAppRouting.dispatch(
            destination,
            returnItem: returnItem,
            openOnlineTabItem: { item, autoPlay, tab in
                SystemEntryRouter.shared.open(item: item, autoPlay: autoPlay, onTab: tab)
            },
            openSystemEntryItem: { item, autoPlay in
                SystemEntryRouter.shared.open(item: item, autoPlay: autoPlay)
            },
            openOfflineDownload: { ratingKey in
                SystemEntryRouter.shared.openOffline(ratingKey: ratingKey)
            })
        openWindow(id: CustomCinemaMode.mainWindowID)
        session.clear()
    }

    @MainActor
    private func tick() {
        // Re-run placement each tick until the attachment has a valid laid-out size; `place` is
        // idempotent once calibrated (it measures intrinsic size, which is independent of the scale
        // it sets), so this also self-heals if RealityKit lays the attachment out late.
        if let screen = entityBox.entity {
            Self.place(screen, geometry: session.geometry)
        }
        bindCinemaCallbacks()
        guard let controller = session.controller else { return }
        tickCustomScrubberClock(&scrubState, from: controller, fallbackDurationMs: session.item?.duration ?? 0)
    }

    @MainActor
    private static func place(_ entity: Entity, geometry: CustomCinemaGeometry) {
        entity.position = geometry.screenPosition
        entity.orientation = simd_quatf(angle: geometry.pitchRadians, axis: SIMD3<Float>(1, 0, 0))

        // A RealityView attachment is NOT authored at 1 point = 1 meter. RealityKit renders the
        // SwiftUI view into a mesh whose physical size is the view's point size divided by a system
        // pixel density (~1360 pt/m), so a 1920-pt-wide attachment is already ~1.4 m wide at
        // scale 1.0. The previous code scaled by `widthMeters / widthPoints`, i.e. ~1360× too
        // small, collapsing the whole cinema screen to a few millimeters — present and hit-testable
        // but invisible at cinema distance (audio plays, screen reads as "pure black, no controls").
        //
        // Measure the attachment's actual intrinsic width instead and scale THAT to the target,
        // so we never hard-code the density. `relativeTo: entity` yields bounds in the entity's own
        // space, excluding its current scale, so this is stable to call repeatedly.
        let intrinsicWidth = entity.visualBounds(relativeTo: entity).extents.x
        guard intrinsicWidth > 0.0001 else { return }   // not laid out yet — a later tick recalibrates
        let scale = geometry.screenWidthMeters / intrinsicWidth
        entity.scale = SIMD3<Float>(repeating: scale)
    }
}

/// Reference holder for the live screen attachment entity.
///
/// `Entity` is a class; storing it in a tiny box lets the SwiftUI view keep a stable handle across
/// RealityView closures and the scrubber clock without re-triggering `@State` invalidation.
private final class EntityBox {
    var entity: Entity?
}

/// The cinema "screen": the shared video surface with the shared player chrome on top.
private struct CustomCinemaScreen: View {
    let session: CustomCinemaSessionStore
    @Binding var scrubState: PlaybackScrubState
    let onRetry: () -> Void
    let widthPoints: CGFloat

    var body: some View {
        let geometry = session.geometry
        let height = max(widthPoints / CGFloat(geometry.aspectRatio), 1)

        ZStack {
            Color.black

            if let controller = session.controller {
                PlayerLayerView(player: controller.player)
                    .ignoresSafeArea()

                CustomPlayerChrome(controller: controller,
                                   title: session.title ?? "Cinema",
                                   scrubState: $scrubState,
                                   trickPlayProvider: session.trickPlayProvider,
                                   onRetry: onRetry,
                                   onClose: nil)
            } else {
                CinemaIdlePlaceholder()
            }
        }
        .frame(width: widthPoints, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
    }
}

/// Shown when Cinema opens without an active player (defensive — entry normally activates one).
private struct CinemaIdlePlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 64, weight: .semibold))
            Text("No active playback")
                .font(.title3.weight(.semibold))
            Text("Start a video, then enter Cinema from the player controls.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(40)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
