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
        core = VideoNowPlayingCore(defaultSkipIntervalSeconds: 10, mediaSession: mediaSession)
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

    func configure(controller: PlaybackController, item: MediaItem, artworkRequest: URLRequest? = nil) {
        self.controller = controller

        controller.player.allowsExternalPlayback = true
        controller.shouldContinueOnBackground = { [weak self] in
            self?.canContinueOnBackground ?? false
        }

        core.configure(controller: controller, item: item, artworkRequest: artworkRequest)
    }

    func attach(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        guard pictureInPictureController == nil,
              AVPictureInPictureController.isPictureInPictureSupported() else {
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

    func updateNowPlayingInfo() {
        core.updateNowPlayingInfo()
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
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = false
        core.updateNowPlayingInfo()
    }
}
