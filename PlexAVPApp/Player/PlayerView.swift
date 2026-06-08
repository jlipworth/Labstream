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

    /// The active bitrate cap (kbps), persisted so the in-player Quality menu and the
    /// rest of the app share one source of truth. `0` means "Maximum / Original".
    @AppStorage("maxVideoBitrateKbps") private var maxVideoBitrateKbps: Int = 8000

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
         mediaIndex: Int = 0) {
        self.controllerFactory = {
            // Fall back to the persisted cap when the caller doesn't specify one.
            let cap = maxVideoBitrateKbps ?? UserDefaults.standard.object(forKey: "maxVideoBitrateKbps") as? Int ?? 8000
            return PlaybackController(item: item,
                                      server: server,
                                      token: token,
                                      identity: identity,
                                      client: client,
                                      maxVideoBitrateKbps: cap,
                                      mediaIndex: mediaIndex)
        }
    }

    /// Local-file initializer (contract).
    ///
    /// The same `client`/`identity` plumbing isn't needed for a pure offline file, but
    /// the controller still wants an identity + client for type symmetry. The
    /// Downloads/UI layer that presents this owns an `AppModel`; to keep the contract
    /// signature minimal we synthesize a throwaway identity/client here. If the caller
    /// has an `AppModel` handy it can prefer the richer `init(localFile:item:identity:client:)`.
    init(localFile: URL, item: MediaItem) {
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
    init(localFile: URL, item: MediaItem, identity: ClientIdentity, client: PlexClient) {
        self.controllerFactory = {
            PlaybackController(localFile: localFile,
                               item: item,
                               identity: identity,
                               client: client)
        }
    }

    var body: some View {
        PlayerRepresentable(controllerFactory: controllerFactory,
                            onBitratePicked: { maxVideoBitrateKbps = $0 })
            .ignoresSafeArea()
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

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controllerFactory(), onBitratePicked: onBitratePicked)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = context.coordinator.controller.player
        CinemaEnvironment.configure(vc)
        context.coordinator.attachControlSurface(to: vc)
        context.coordinator.controller.start()
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
