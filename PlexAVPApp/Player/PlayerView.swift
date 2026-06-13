import SwiftUI
import AVKit
import PMSKit

/// SwiftUI wrapper around `AVPlayerViewController` that plays a Plex title in the
/// visionOS system cinema environment.
///
/// One playback path serves both streaming and offline:
///   • `init(item:server:token:identity:client:)` — runs the transcode decision and
///     plays `start.m3u8`, seeking to `viewOffset` and reporting timeline/scrobble.
///   • `init(localFile:item:)` — plays a downloaded local file through the same
///     `AVPlayer`/`AVPlayerViewController` (and cinema environment), no server calls.
///
/// Present this as the exclusive content of its window scene so the system shows the
/// expanded/docked cinema screen (see `CinemaEnvironment`).
struct PlayerView: View {
    /// Builds the controller. The `Int?` is an optional resume override (ms) used when the
    /// player is REBUILT to recover from a wedged AVKit state after a failure — the fresh
    /// controller resumes at the captured live playhead instead of the item's saved offset.
    /// The optional `PlexClient` is a one-shot recovery client for #33, used only on Retry
    /// rebuilds to avoid reusing a poisoned pooled connection.
    private let controllerFactory: @MainActor (Int?, PlexClient?) -> PlaybackController

    /// Dismiss hook for the presenting container (the `.fullScreenCover` in `DetailView`).
    /// AVPlayerViewController does NOT supply a system Close button on visionOS, so without
    /// this the viewer has no way out of the cover. When non-nil we render our own top-leading
    /// close affordance below. Optional + defaulting to nil keeps all existing call sites
    /// source-compatible.
    private let onClose: (() -> Void)?

    /// Advance hook for "Up Next" autoplay (#15). When the controller resolves a next
    /// episode and either the countdown elapses, the user taps "Play Now", or the item
    /// plays to end (and wasn't cancelled), the controller calls this with the next
    /// `MediaItem`. The presenting container (DetailView's `.fullScreenCover`) handles it by
    /// swapping the presented item so this view + its controller rebuild for the next
    /// episode. Optional + defaulting to nil keeps all existing call sites source-compatible.
    private let onRequestPlay: ((MediaItem) -> Void)?

    /// The active bitrate cap (kbps), persisted so the in-player Quality menu and the
    /// rest of the app share one source of truth. `0` means "Maximum / Original".
    @AppStorage("maxVideoBitrateKbps") private var maxVideoBitrateKbps: Int = 8000

    /// The live controller, published up from the representable's coordinator once it has
    /// been created on the main actor. We can't build a `@MainActor PlaybackController` in
    /// `View.init` under Swift 6 strict isolation, so the representable hands it back via
    /// `onControllerReady` and we observe its `playbackError` here to drive the failure
    /// overlay (#8 / P3+P4). Nil until the player view controller is first made.
    @State private var controller: PlaybackController?

    /// Bumped to force a FULL teardown + rebuild of the `AVPlayerViewController` (via `.id`)
    /// when recovering from a playback failure. An in-place `retry()` (item swap) inherits
    /// AVKit's wedged control/cinema-experience state after a failure — only a fresh view
    /// controller clears it, restoring the transport chrome and un-dimming the environment.
    @State private var playerGeneration = 0

    /// Resume target (ms) handed to the rebuilt controller so recovery resumes at the live
    /// playhead we captured at failure time, not the stale on-disk offset. `nil` on first build.
    @State private var rebuildResumeMs: Int?

    /// True from the moment a failure-recovery rebuild starts until the fresh controller reports
    /// genuine playback (`onPlaybackActive`). Drives the "Reconnecting…" overlay (GH #33): during
    /// the rebuild `controller` is nil and the cold load may never enter
    /// `.waitingToPlayAtSpecifiedRate` (when `start.m3u8` itself hangs), so neither the #21
    /// spinner nor any `if let controller` overlay renders — leaving a bare black canvas with no
    /// exit. This flag is independent of `controller`, so the overlay (spinner + Close) covers
    /// that whole window.
    @State private var isReconnecting = false

    /// How long the reconnect watchdog waits for a recovery rebuild to reach playback before
    /// giving up and surfacing the Retry/Close failure overlay (GH #33). Comfortably above a
    /// healthy cold-start prime, below the ~30s the OS takes to evict a poisoned socket.
    private let reconnectTimeoutSeconds: Double = 20

    /// Fresh control-plane client handed to the NEXT recovery rebuild (#33). Nil for the normal
    /// first build and cleared after the rebuilt controller is published.
    @State private var rebuildClientOverride: PlexClient?

    /// Streaming initializer (contract).
    ///
    /// `maxVideoBitrateKbps` is optional: when omitted the controller starts at the
    /// persisted `@AppStorage` cap, which the in-player Quality menu can then change.
    /// `mediaIndex` selects which `Media` version of the item to stream when the title
    /// ships multiple files (e.g. a 4K and a 1080p version). Defaults to `0` (primary
    /// version) so existing call sites stay source-compatible.
    init(item: MediaItem,
         server: URL,
         token: String,
         identity: ClientIdentity,
         client: PlexClient,
         maxVideoBitrateKbps: Int? = nil,
         mediaIndex: Int = 0,
         machineIdentifier: String? = nil,
         onClose: (() -> Void)? = nil,
         onRequestPlay: ((MediaItem) -> Void)? = nil) {
        self.onClose = onClose
        self.onRequestPlay = onRequestPlay
        self.controllerFactory = { resumeMsOverride, recoveryClient in
            // Fall back to the persisted cap when the caller doesn't specify one.
            let cap = maxVideoBitrateKbps ?? UserDefaults.standard.object(forKey: "maxVideoBitrateKbps") as? Int ?? 8000
            return PlaybackController(item: item,
                                      server: server,
                                      token: token,
                                      identity: identity,
                                      client: recoveryClient ?? client,
                                      maxVideoBitrateKbps: cap,
                                      mediaIndex: mediaIndex,
                                      machineIdentifier: machineIdentifier,
                                      initialResumeMsOverride: resumeMsOverride)
        }
    }

    /// Local-file initializer (contract).
    ///
    /// The same `client`/`identity` plumbing isn't needed for a pure offline file, but
    /// the controller still wants an identity + client for type symmetry. The
    /// Downloads/UI layer that presents this owns an `AppModel`; to keep the contract
    /// signature minimal we synthesize a throwaway identity/client here. If the caller
    /// has an `AppModel` handy it can prefer the richer `init(localFile:item:identity:client:)`.
    init(localFile: URL, item: MediaItem, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onRequestPlay = nil
        let identity = ClientIdentity(clientIdentifier: "offline",
                                      product: "VisionPlex",
                                      version: "0.1.0",
                                      deviceName: "Apple Vision Pro")
        let client = PlexClient(identity: identity)
        self.controllerFactory = { _, _ in
            PlaybackController(localFile: localFile,
                               item: item,
                               identity: identity,
                               client: client)
        }
    }

    /// Richer local-file initializer for callers that already hold an identity+client.
    init(localFile: URL, item: MediaItem, identity: ClientIdentity, client: PlexClient,
         onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onRequestPlay = nil
        self.controllerFactory = { _, _ in
            PlaybackController(localFile: localFile,
                               item: item,
                               identity: identity,
                               client: client)
        }
    }

    var body: some View {
        // ZStack(.topLeading): the player fills the layer; the overlays below
        // (error / skip / up-next / buffering) float on top of it.
        //
        // The Close affordance is NOT floated here. A sibling SwiftUI button only
        // composites over the player in the INLINE/windowed state — in the expanded
        // cinema experience AVKit owns the whole window scene and our siblings vanish,
        // leaving no exit (the bug we hit). Instead Close is an AVKit-hosted
        // `contextualActions` pill (single-owned by `PlayerControlSurface`), which
        // AVKit renders over the video in BOTH the windowed and expanded states and
        // keeps tappable. In expanded the system shows/hides it with its own chrome;
        // in windowed it appears on a tap (chrome heuristic) or while paused/failed —
        // not during hands-off playback. See docs/DEVELOPMENT.md for why the
        // alternatives lost.
        ZStack(alignment: .topLeading) {
            PlayerRepresentable(controllerFactory: controllerFactory,
                                resumeMsOverride: rebuildResumeMs,
                                recoveryClientOverride: rebuildClientOverride,
                                onBitratePicked: { maxVideoBitrateKbps = $0 },
                                onClose: onClose,
                                onRetry: { rebuildPlayer(from: $0) },
                                onControllerReady: {
                                    // Wire the autoplay-advance hook before publishing the
                                    // controller (#15): the controller calls this when the
                                    // Up Next countdown elapses / play-to-end / "Play Now".
                                    $0.onAdvanceToNext = onRequestPlay
                                    // Dismiss the "Reconnecting…" overlay once the rebuilt
                                    // stream genuinely plays (GH #33).
                                    $0.onPlaybackActive = { isReconnecting = false }
                                    controller = $0
                                    rebuildClientOverride = nil
                                })
                // A new id tears down the wedged AVPlayerViewController and builds a fresh one
                // on rebuild (failure recovery), giving un-wedged controls + a reset experience.
                .id(playerGeneration)
                .ignoresSafeArea()

            // Failure overlay (#8 / P3+P4): when the controller surfaces a playback error
            // (after its one silent auto-retry is spent), cover the black AVKit canvas with
            // a legible message + a Retry that re-runs the streaming start from the last
            // playhead, plus a way out. Observes the @Observable `playbackError` directly.
            if let controller {
                PlaybackErrorOverlay(error: controller.playbackError,
                                     onRetry: { rebuildPlayer(from: controller) },
                                     onClose: onClose)
            }

            // Skip Intro / Skip Credits overlay (#14): when the controller marks an
            // intro/credits range active, float a bottom-trailing Skip button. Bottom-
            // trailing keeps it clear of the top-leading Close button, the top-trailing
            // AVKit "…" info menu, the top-area error overlay, and AVKit's bottom-CENTER
            // transport bar. Observes the @Observable `skipMarker` directly.
            if let controller {
                SkipMarkerOverlay(state: controller.skipMarker,
                                  onSkip: { controller.skipCurrentMarker() })
            }

            // Up Next card (#15): when the controller has resolved a next episode and the
            // playhead reaches the near-end window, float a bottom-LEADING card with the
            // next title, a countdown, "Play Now" and "Cancel". Bottom-leading is chosen to
            // avoid every other affordance: the top-leading Close, the top-trailing AVKit
            // "…" menu, the top-area error overlay, the bottom-TRAILING SkipMarker button,
            // and AVKit's bottom-CENTER transport bar. Observes the @Observable `upNext`.
            if let controller {
                UpNextOverlay(state: controller.upNext,
                              onPlayNow: { controller.playNextNow() },
                              onCancel: { controller.cancelUpNext() })
            }

            // Rebuffer/loading spinner (#21): when the controller reports a stall
            // (timeControlStatus == .waitingToPlayAtSpecifiedRate), float a centered spinner.
            // Centered is standard for a stall indicator (AVKit's transport is bottom-center
            // and only visible on tap). The overlay is non-hit-testing so it never blocks the
            // transport or any other affordance. Observes the @Observable `buffering` directly.
            //
            // Suppressed while a failure is surfaced: the stall that triggered the watchdog
            // leaves `isBuffering` true, so without this gate the spinner floats on top of the
            // error/Retry dialog (which occupies the same center region). Once we've given up
            // and shown Retry — and paused the player (see `surfaceFailure`) — the spinner has
            // no role.
            if let controller, !controller.playbackError.isFailed {
                BufferingOverlay(state: controller.buffering)
            }

            // Reconnecting overlay (GH #33): during a failure-recovery rebuild `controller` is
            // nil and the fresh cold load may hang without ever entering the buffering state, so
            // no other overlay renders. Show a spinner + Close so the rebuild is never a bare,
            // inescapable black canvas. Suppressed once a failure surfaces (the error overlay,
            // with its own Retry/Close, takes over) and cleared when playback resumes.
            if isReconnecting, controller?.playbackError.isFailed != true {
                ReconnectingOverlay(onClose: onClose)
            }

            // Stats for Nerds (#6) lives INSIDE the ⓘ info panel (a system-chrome "Stats"
            // tab, see PlayerControlSurface) — the only stats surface that renders in the
            // expanded cinema experience. Floating it here was the previous approach and
            // only ever worked windowed: `contentOverlayView` exists on visionOS but is
            // never composited (verified live), `customOverlayViewController` is tvOS-only,
            // and the expanded scene renders no in-process overlay at all.
        }
        // Reconnect watchdog (GH #33): a recovery rebuild whose cold `start.m3u8` hangs on a
        // poisoned pooled connection produces no AVPlayer error and never enters
        // `.waitingToPlayAtSpecifiedRate`, so neither `handlePlaybackFailure` nor the stall
        // watchdog (which needs that state) ever fires — the "Reconnecting…" spinner would
        // otherwise hang forever with only Close as an exit. Bound it: keyed on
        // `playerGeneration` so every rebuild re-arms it; on a successful reconnect
        // `onPlaybackActive` clears `isReconnecting` long before the deadline, making this a
        // no-op. If the deadline passes still reconnecting, surface the failure so the
        // Retry/Close overlay replaces the dead spinner.
        .task(id: playerGeneration) {
            guard isReconnecting else { return }
            try? await Task.sleep(for: .seconds(reconnectTimeoutSeconds))
            guard !Task.isCancelled, isReconnecting, let controller else { return }
            isReconnecting = false
            controller.surfaceReconnectTimeout()
        }
    }

    /// Recover from a surfaced playback failure by rebuilding the player from scratch. AVKit
    /// wedges its control + cinema-experience state after a failure, and an in-place item swap
    /// inherits that wedge (controls won't reveal, the environment stays dimmed). Capturing the
    /// live playhead, dropping the controller, and bumping `playerGeneration` makes SwiftUI tear
    /// down the wedged `AVPlayerViewController` and build a fresh one that resumes where we left
    /// off — no app relaunch needed.
    @MainActor
    private func rebuildPlayer(from current: PlaybackController) {
        rebuildResumeMs = current.currentResumeMs
        // Show the "Reconnecting…" overlay across the rebuild + cold-load window (GH #33);
        // cleared when the fresh controller reports playback via `onPlaybackActive`.
        isReconnecting = true
        // Also hand the rebuilt controller a fresh short-timeout URLSession for control-plane
        // requests, so retry setup/timeline/stop don't inherit a poisoned pooled connection.
        rebuildClientOverride = current.recoveryControlClient()
        // Drop the stale reference so the error overlay (and other `if let controller` overlays)
        // clear immediately; the rebuilt controller republishes via `onControllerReady`.
        controller = nil
        playerGeneration += 1
    }
}

/// Centered rebuffer/loading spinner shown over the player while playback is stalled (#21).
/// Reads the controller's `@Observable` `BufferingState`, so it appears/disappears as the
/// player enters/leaves `.waitingToPlayAtSpecifiedRate`, with no manual refresh. A manual
/// pause maps to `.paused` (not waiting), so the spinner correctly stays hidden then.
private struct BufferingOverlay: View {
    let state: BufferingState

    var body: some View {
        if state.isBuffering {
            ZStack {
                ProgressView()
                    .controlSize(.large)
                    .padding(DS.Space.xl)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
            // Center over the whole player surface.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Never intercept touches: the AVKit transport and every other affordance must
            // stay tappable while the spinner is up.
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// "Reconnecting…" overlay shown over the player during a failure-recovery rebuild and the
/// fresh player's cold load (GH #33). Unlike `BufferingOverlay` it does NOT read the controller
/// (which is nil for part of that window) and it IS hit-testable, because it owns the only exit
/// the viewer has while the rebuild hangs — a Close button. The centered card is the only
/// interactive region; the surrounding frame has no background, so it never traps touches.
/// INLINE-state only: SwiftUI overlays don't composite in the expanded cinema experience, where
/// AVKit's own loading indicator and the Close `contextualAction` cover this instead.
private struct ReconnectingOverlay: View {
    let onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            ProgressView()
                .controlSize(.large)
            Text("Reconnecting…")
                .font(.headline)
            if let onClose {
                Button(role: .cancel, action: onClose) {
                    Text("Close").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DS.Space.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

/// Bottom-leading "Up Next" card shown over the player as the current episode nears its end
/// (#15). Reads the controller's `@Observable` `UpNextState`, so it appears once a next
/// episode is resolved and the playhead crosses the trigger point, ticks its countdown, and
/// disappears on advance / cancel — with no manual refresh.
private struct UpNextOverlay: View {
    let state: UpNextState
    let onPlayNow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if state.isShown, let next = state.nextItem {
            VStack {
                Spacer()
                HStack {
                    card(for: next)
                    Spacer()
                }
            }
            .padding(DS.Space.xxxl)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func card(for next: MediaItem) -> some View {
        HStack(spacing: DS.Space.md) {
            PosterImage(path: next.thumb,
                        width: 120,
                        height: 68,
                        cornerRadius: DS.Radius.card)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Up Next")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(next.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("Playing in \(state.countdown)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: DS.Space.sm) {
                    Button(action: onPlayNow) {
                        Label("Play Now", systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                }
                .padding(.top, DS.Space.xs)
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(DS.Space.lg)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

/// Bottom-trailing Skip Intro / Skip Credits button shown over the player while a marker is
/// active (#14). Reads the controller's `@Observable` `SkipMarkerState`, so it appears and
/// disappears as the playhead enters/leaves an intro/credits range, with no manual refresh.
private struct SkipMarkerOverlay: View {
    let state: SkipMarkerState
    let onSkip: () -> Void

    var body: some View {
        if let active = state.active {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: onSkip) {
                        Label(active.kind.label, systemImage: active.kind.systemImage)
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, DS.Space.lg)
                            .padding(.vertical, DS.Space.sm)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(active.kind.label)
                }
            }
            .padding(DS.Space.xxxl)
            .transition(.opacity)
        }
    }
}

/// Full-bleed error state shown over the player when playback fails. Reads the controller's
/// `@Observable` `PlaybackError`, so it appears/disappears as the failure is set/cleared
/// (e.g. cleared by `retry()`), with no manual refresh.
private struct PlaybackErrorOverlay: View {
    let error: PlaybackError
    let onRetry: () -> Void
    /// Optional dismissal (same hook the close button uses) so a fatal stream isn't a dead end.
    let onClose: (() -> Void)?

    var body: some View {
        if error.isFailed {
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: DS.Space.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.yellow)
                    Text("Playback failed")
                        .font(.title2.weight(.semibold))
                    Text(error.message ?? "The video couldn't be played. This is often a transient server or network issue.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    HStack(spacing: DS.Space.md) {
                        Button(action: onRetry) {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        if let onClose {
                            Button("Close", action: onClose)
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(DS.Space.xl)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
            .transition(.opacity)
        }
    }
}

/// `UIViewControllerRepresentable` bridge to `AVPlayerViewController`.
///
/// The coordinator also builds the in-player control surface (Quality / Chapters /
/// Stats menus) once the view controller exists, so the custom transport-bar items and
/// the stats overlay are wired to the same `PlaybackController`.
private struct PlayerRepresentable: UIViewControllerRepresentable {
    let controllerFactory: @MainActor (Int?, PlexClient?) -> PlaybackController
    /// Resume override (ms) forwarded to the factory on a failure-recovery rebuild; `nil` on
    /// the normal first build (the controller then uses the item's saved offset).
    let resumeMsOverride: Int?
    /// Fresh recovery client for #33 Retry rebuilds. Nil during normal playback startup.
    let recoveryClientOverride: PlexClient?
    /// Persists the user's Quality choice up into `@AppStorage`.
    let onBitratePicked: (Int) -> Void
    /// Dismiss hook for the presenting `.fullScreenCover`. Surfaced by the control surface as a
    /// native `contextualActions` "Close" (renders over the video in BOTH inline and expanded
    /// cinema states, unlike a floated SwiftUI sibling, which vanishes when expanded).
    let onClose: (() -> Void)?
    /// Failure-recovery hook (#23): rebuilds the player from the live playhead. Threaded to the
    /// control surface so the expanded-mode "Retry" contextual action triggers the same `.id()`
    /// rebuild as the inline error overlay (an in-place `controller.retry()` inherits the wedge).
    let onRetry: (PlaybackController) -> Void
    /// Publishes the main-actor-created controller back up to `PlayerView` so it can observe
    /// `playbackError` for the failure overlay. Called once, asynchronously, after creation
    /// to avoid mutating `@State` during the view-update pass.
    let onControllerReady: (PlaybackController) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controllerFactory(resumeMsOverride, recoveryClientOverride),
                    onBitratePicked: onBitratePicked,
                    onClose: onClose,
                    onRetry: onRetry)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = context.coordinator.controller.player
        CinemaEnvironment.configure(vc)

        // `contextualActions` (the visionOS-native slot for controls "displayed during playback",
        // rendered by the system player so they persist into the expanded cinema experience) is
        // owned entirely by the control surface now (#23): it shows "Close" when the user is
        // interacting (expanded: system-managed; windowed: tap heuristic / paused / failed) AND
        // prepends a state-driven Retry / Skip / Play Next when applicable. Setting it
        // here too would clobber that, so the control surface is the single owner.
        context.coordinator.attachControlSurface(to: vc)
        // Open straight into the Expanded experience — the embedded windowed state
        // is configuration-dead (no info tabs) so we don't start there. Also runs
        // on a failure-recovery rebuild, restoring the pre-failure experience.
        CinemaEnvironment.autoExpand(vc)
        context.coordinator.controller.start()
        // Hand the controller up to the SwiftUI layer after this update pass completes.
        let controller = context.coordinator.controller
        let publish = onControllerReady
        Task { @MainActor in publish(controller) }
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Player binding is stable; nothing to refresh per update.
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.controller.stop()
        uiViewController.player = nil
    }

    @MainActor
    final class Coordinator {
        let controller: PlaybackController
        private let onBitratePicked: (Int) -> Void
        private let onClose: (() -> Void)?
        private let onRetry: (PlaybackController) -> Void
        private var controlSurface: PlayerControlSurface?

        init(controller: PlaybackController,
             onBitratePicked: @escaping (Int) -> Void,
             onClose: (() -> Void)?,
             onRetry: @escaping (PlaybackController) -> Void) {
            self.controller = controller
            self.onBitratePicked = onBitratePicked
            self.onClose = onClose
            self.onRetry = onRetry
        }

        func attachControlSurface(to vc: AVPlayerViewController) {
            controlSurface = PlayerControlSurface(playerVC: vc,
                                                  controller: controller,
                                                  onBitratePicked: onBitratePicked,
                                                  onClose: onClose,
                                                  onRetry: onRetry)
        }
    }
}
