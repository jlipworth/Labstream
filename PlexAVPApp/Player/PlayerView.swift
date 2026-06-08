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

    /// Streaming initializer (contract).
    init(item: MediaItem,
         server: URL,
         token: String,
         identity: ClientIdentity,
         client: PlexClient) {
        self.controllerFactory = {
            PlaybackController(item: item,
                               server: server,
                               token: token,
                               identity: identity,
                               client: client)
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
        PlayerRepresentable(controllerFactory: controllerFactory)
            .ignoresSafeArea()
    }
}

/// `UIViewControllerRepresentable` bridge to `AVPlayerViewController`.
private struct PlayerRepresentable: UIViewControllerRepresentable {
    let controllerFactory: @MainActor () -> PlaybackController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controllerFactory())
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = context.coordinator.controller.player
        CinemaEnvironment.configure(vc)
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
        init(controller: PlaybackController) {
            self.controller = controller
        }
    }
}
