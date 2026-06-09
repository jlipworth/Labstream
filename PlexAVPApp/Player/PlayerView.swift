import SwiftUI
import AVKit
import PlexKit

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
    private let controllerFactory: @MainActor () -> PlaybackController

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
        self.controllerFactory = {
            // Fall back to the persisted cap when the caller doesn't specify one.
            let cap = maxVideoBitrateKbps ?? UserDefaults.standard.object(forKey: "maxVideoBitrateKbps") as? Int ?? 8000
            return PlaybackController(item: item,
                                      server: server,
                                      token: token,
                                      identity: identity,
                                      client: client,
                                      maxVideoBitrateKbps: cap,
                                      mediaIndex: mediaIndex,
                                      machineIdentifier: machineIdentifier)
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
                                      product: "plex-avp-app",
                                      version: "0.1.0",
                                      deviceName: "Apple Vision Pro")
        let client = PlexClient(identity: identity)
        self.controllerFactory = {
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
        self.controllerFactory = {
            PlaybackController(localFile: localFile,
                               item: item,
                               identity: identity,
                               client: client)
        }
    }

    var body: some View {
        // ZStack(.topLeading): AVPlayerViewController on visionOS gives us NO system Close,
        // so we float our own dismiss control. Top-leading keeps it clear of AVKit's
        // transport bar (bottom) and the custom "…" Quality/Chapters/Stats menu
        // (top-trailing) — the prior overlay was removed for stacking "buttons behind
        // buttons", so we deliberately stay in the empty top-left corner.
        ZStack(alignment: .topLeading) {
            PlayerRepresentable(controllerFactory: controllerFactory,
                                onBitratePicked: { maxVideoBitrateKbps = $0 },
                                onControllerReady: {
                                    // Wire the autoplay-advance hook before publishing the
                                    // controller (#15): the controller calls this when the
                                    // Up Next countdown elapses / play-to-end / "Play Now".
                                    $0.onAdvanceToNext = onRequestPlay
                                    controller = $0
                                })
                .ignoresSafeArea()

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .padding(DS.Space.sm)
                }
                .buttonStyle(.borderless)
                .background(.ultraThinMaterial, in: Circle())
                .padding(DS.Space.lg)
                .accessibilityLabel("Close player")
            }

            // Failure overlay (#8 / P3+P4): when the controller surfaces a playback error
            // (after its one silent auto-retry is spent), cover the black AVKit canvas with
            // a legible message + a Retry that re-runs the streaming start from the last
            // playhead, plus a way out. Observes the @Observable `playbackError` directly.
            if let controller {
                PlaybackErrorOverlay(error: controller.playbackError,
                                     onRetry: { controller.retry() },
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
            if let controller {
                BufferingOverlay(state: controller.buffering)
            }
        }
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
    let controllerFactory: @MainActor () -> PlaybackController
    /// Persists the user's Quality choice up into `@AppStorage`.
    let onBitratePicked: (Int) -> Void
    /// Publishes the main-actor-created controller back up to `PlayerView` so it can observe
    /// `playbackError` for the failure overlay. Called once, asynchronously, after creation
    /// to avoid mutating `@State` during the view-update pass.
    let onControllerReady: (PlaybackController) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controllerFactory(), onBitratePicked: onBitratePicked)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = context.coordinator.controller.player
        CinemaEnvironment.configure(vc)
        context.coordinator.attachControlSurface(to: vc)
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
        private var controlSurface: PlayerControlSurface?

        init(controller: PlaybackController, onBitratePicked: @escaping (Int) -> Void) {
            self.controller = controller
            self.onBitratePicked = onBitratePicked
        }

        func attachControlSurface(to vc: AVPlayerViewController) {
            controlSurface = PlayerControlSurface(playerVC: vc,
                                                  controller: controller,
                                                  onBitratePicked: onBitratePicked)
        }
    }
}
