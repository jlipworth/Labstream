import AVFoundation
import AVKit
import MediaPlayer
import PMSKit
import UIKit
/// iPhone/iPad system-video integration for the app-owned custom player.
///
/// The visionOS player path deliberately owns all chrome itself. On iOS/iPadOS the custom
/// player still owns transport chrome, but it must also participate in system surfaces that
/// users expect from a full-screen video app: AirPlay route picking, PiP, Now Playing, and
/// remote commands. Now Playing/remote-command machinery lives in the shared
/// `VideoNowPlayingCore`; this coordinator adds the iOS-only surfaces (PiP, external playback).
@MainActor
final class MobilePlayerSystemCoordinator: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    private let core: VideoNowPlayingCore

    init(mediaSession: SystemMediaSessionCoordinator) {
        core = VideoNowPlayingCore(commandProfile: .processWide(fallbackSeconds: 10),
                                   mediaSession: mediaSession)
    }
    private weak var controller: PlaybackController?
    private weak var playerLayer: AVPlayerLayer?
    private var pictureInPictureController: AVPictureInPictureController?

    private(set) var isPictureInPictureActive = false

    var isPictureInPicturePossible: Bool {
        pictureInPictureController?.isPictureInPicturePossible ?? false
    }

    var canContinueOnBackground: Bool {
        isPictureInPictureActive || controller?.player.isExternalPlaybackActive == true
    }

    func configure(controller: PlaybackController,
                   item: MediaItem,
                   artworkDescriptor: ArtworkRequestDescriptor? = nil,
                   artworkPipeline: ArtworkPipeline? = nil) {
        self.controller = controller

        controller.player.allowsExternalPlayback = true
        controller.shouldContinueOnBackground = { [weak self] in
            self?.canContinueOnBackground ?? false
        }

        core.configure(controller: controller,
                       item: item,
                       artworkDescriptor: artworkDescriptor,
                       artworkPipeline: artworkPipeline)
    }

    /// Bind PiP to the presenter's live layer. Called on every presenter update, so it must be
    /// idempotent. Geometry changes (rotation, resize, iPhone Duo fold) keep the same layer; if a
    /// presenter ever attaches a different layer, PiP follows it while inactive, so the content
    /// source never points at a layer that left the hierarchy.
    func attach(playerLayer: AVPlayerLayer) {
        let previousLayer = self.playerLayer
        self.playerLayer = playerLayer
        if let pictureInPictureController {
            guard previousLayer !== playerLayer,
                  !pictureInPictureController.isPictureInPictureActive else { return }
            pictureInPictureController.contentSource = .init(playerLayer: playerLayer)
            AppDiagnostics.record(.playback, "player.pip_rebind", fields: [:])
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        pictureInPictureController = controller
    }

    func togglePictureInPicture() {
        guard let pictureInPictureController else { return }
        if pictureInPictureController.isPictureInPictureActive {
            pictureInPictureController.stopPictureInPicture()
        } else if pictureInPictureController.isPictureInPicturePossible {
            pictureInPictureController.startPictureInPicture()
        }
    }

    func teardown() {
        controller?.shouldContinueOnBackground = { false }
        if pictureInPictureController?.isPictureInPictureActive == true {
            pictureInPictureController?.stopPictureInPicture()
        }
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        playerLayer = nil
        controller = nil
        core.teardown()
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = true
        core.updateNowPlayingInfo()
        AppDiagnostics.record(.playback, "player.pip_state", fields: ["state": .label("will_start")])
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = false
        core.updateNowPlayingInfo()
        AppDiagnostics.record(.playback, "player.pip_state", fields: ["state": .label("did_stop")])
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: any Error) {
        isPictureInPictureActive = false
        AppDiagnostics.record(.playback, "player.pip_state", fields: [
            "state": .label("failed_to_start"),
            "error": .error(error),
        ])
    }

    /// The full-screen cover stays presented while PiP runs (this coordinator is torn down, and
    /// PiP stopped, when the player view disappears), so the player UI is always there to
    /// restore into, on whichever display the scene is on after a fold.
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(controller != nil)
    }
}
