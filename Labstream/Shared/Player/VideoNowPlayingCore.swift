#if os(iOS) || os(macOS)
import AVFoundation
import Foundation
import MediaPlayer
import PMSKit

///
/// iOS/iPadOS and macOS both participate in the system transport stack (media keys, Control
/// Center, lock screen, headphones, external transport surfaces) around the same
/// `PlaybackController`; only the platform surfaces differ (PiP/AirPlay on iOS). visionOS
/// instead uses a scoped `MPNowPlayingSession` via `VideoNowPlayingCoordinator` because it
/// has no platform coordinator around the player layer.
@MainActor
final class VideoNowPlayingCore {
    private weak var controller: PlaybackController?
    private var item: MediaItem?
    private let mediaSession: SystemMediaSessionCoordinator
    private var mediaLease: SystemMediaSessionCoordinator.Lease?
    private var artworkImage: DecodedImage?
    private var artworkTask: Task<Void, Never>?
    private var metadataObserverToken: VideoNowPlayingMetadataObserverRegistry.Token?
    private let commandProfile: VideoNowPlayingCommandProfile

    init(commandProfile: VideoNowPlayingCommandProfile,
         mediaSession: SystemMediaSessionCoordinator) {
        self.commandProfile = commandProfile
        self.mediaSession = mediaSession
    }

    func configure(controller: PlaybackController,
                   item: MediaItem,
                   artworkDescriptor: ArtworkRequestDescriptor?,
                   artworkPipeline: ArtworkPipeline?) {
        teardown()
        self.controller = controller
        self.item = item
        metadataObserverToken = controller.observeVideoNowPlayingMetadata { [weak self] update in
            self?.updateNowPlayingInfo(
                elapsedMillisecondsOverride: update.elapsedMillisecondsOverride,
                playbackRateOverride: update.playbackRateOverride)
        }
        mediaLease = mediaSession.acquire(owner: .video, commands: commandConfiguration())
        updateNowPlayingInfo()
        loadArtwork(from: artworkDescriptor, pipeline: artworkPipeline)
    }

    func updateNowPlayingInfo(elapsedMillisecondsOverride: Int? = nil,
                              playbackRateOverride: Double? = nil) {
        guard let controller, let item, let mediaLease else { return }
        let durationMilliseconds = durationMilliseconds(for: controller)
        let paused = playbackRateOverride == 0 || controller.transport.showsPausedControl
        let snapshot = VideoNowPlayingSnapshot(
            mediaItem: item,
            durationMilliseconds: durationMilliseconds,
            elapsedMilliseconds: elapsedMillisecondsOverride ?? controller.currentResumeMs,
            playbackRate: playbackRateOverride ?? (paused ? 0 : Double(controller.player.rate)),
            defaultPlaybackRate: Double(controller.player.defaultRate))
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyMediaType: MPMediaType.movie.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(snapshot.elapsedMilliseconds) / 1000.0,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.defaultPlaybackRate,
        ]
        if let durationMilliseconds = snapshot.durationMilliseconds {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMilliseconds) / 1000.0
        }
        if let context = snapshot.context {
            info[MPMediaItemPropertyAlbumTitle] = context
        }
        if let artworkImage {
            info[MPMediaItemPropertyArtwork] = NowPlayingArtwork.make(artworkImage)
        }
        mediaLease.publish(nowPlayingInfo: info,
                           playbackState: paused ? .paused : .playing)
    }

    func teardown() {
        if let controller, let metadataObserverToken {
            controller.removeVideoNowPlayingMetadataObserver(metadataObserverToken)
        }
        metadataObserverToken = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkImage = nil
        mediaLease?.clearNowPlaying()
        mediaLease?.release()
        mediaLease = nil
        controller = nil
        item = nil
    }

    private func commandConfiguration() -> SystemMediaSessionCoordinator.CommandConfiguration {
        return .init(handlers: [
            .play: { [weak self] _ in
                guard let controller = self?.controller else { return .noActionableItem }
                controller.requestPlay()
                return .success
            },
            .pause: { [weak self] _ in
                guard let controller = self?.controller else { return .noActionableItem }
                controller.requestPause()
                return .success
            },
            .togglePlayPause: { [weak self] _ in
                guard let controller = self?.controller else { return .noActionableItem }
                controller.togglePlayback()
                return .success
            },
            .changePlaybackPosition: { [weak self] event in
                guard let self else { return .noActionableItem }
                return self.performRemoteCommand(
                    VideoNowPlayingCommandPolicy.seekIntent(
                        positionTime: event.positionTime,
                        durationMilliseconds: self.controller?.videoNowPlayingDurationMilliseconds))
            },
            .skipForward: { [weak self, commandProfile] event in
                guard let self else { return .noActionableItem }
                return self.performRemoteCommand(
                    VideoNowPlayingCommandPolicy.skipIntent(
                        interval: event.skipInterval,
                        fallbackSeconds: commandProfile.forwardFallbackSeconds,
                        direction: .forward))
            },
            .skipBackward: { [weak self, commandProfile] event in
                guard let self else { return .noActionableItem }
                return self.performRemoteCommand(
                    VideoNowPlayingCommandPolicy.skipIntent(
                        interval: event.skipInterval,
                        fallbackSeconds: commandProfile.backwardFallbackSeconds,
                        direction: .backward))
            },
        ], skipForwardIntervals: commandProfile.advertisedForwardIntervals.map { NSNumber(value: $0) },
           skipBackwardIntervals: commandProfile.advertisedBackwardIntervals.map { NSNumber(value: $0) },
           didBecomeCurrent: { [weak self] _ in
               Task { @MainActor [weak self] in self?.updateNowPlayingInfo() }
           })
    }

    private func loadArtwork(from descriptor: ArtworkRequestDescriptor?,
                             pipeline: ArtworkPipeline?) {
        artworkTask?.cancel()
        artworkImage = nil
        guard let descriptor, let pipeline else { return }
        let lease = mediaLease
        artworkTask = Task { [weak self] in
            do {
                let response = try await pipeline.fetch(descriptor, priority: .visible)
                try Task.checkCancellation()
                guard let self, self.mediaLease === lease else { return }
                self.artworkImage = response.image
                // Keep the result while another owner is momentarily current. The lease's
                // didBecomeCurrent hook republishes it when video regains ownership.
                if lease?.isCurrent == true {
                    self.updateNowPlayingInfo()
                }
            } catch {
                // Text-only system metadata is the safe fallback for cancellation, missing art,
                // transport failure, or an invalid image.
            }
        }
    }

    private func durationMilliseconds(for controller: PlaybackController) -> Int? {
        if let duration = controller.player.currentItem?.duration.seconds,
           duration.isFinite, duration > 0,
           duration * 1000 < Double(Int.max) {
            return Int((duration * 1000).rounded())
        }
        return nil
    }

    private func performRemoteCommand(_ intent: VideoNowPlayingCommandPolicy.Intent?)
        -> SystemMediaSessionCoordinator.CommandStatus {
        guard let controller else { return .noActionableItem }
        guard let intent else { return .failed }
        controller.performVideoNowPlayingCommand(intent)
        return .success
    }
}
#endif
