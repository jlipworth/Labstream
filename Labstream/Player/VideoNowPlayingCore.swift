#if os(iOS) || os(macOS)
import AVFoundation
import Foundation
import MediaPlayer
import PMSKit
#if os(iOS)
import UIKit
#endif

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
    private var artworkImage: UIImage?
    private var artworkTask: Task<Void, Never>?
    private let defaultSkipIntervalSeconds: Double

    init(defaultSkipIntervalSeconds: Double, mediaSession: SystemMediaSessionCoordinator) {
        self.defaultSkipIntervalSeconds = defaultSkipIntervalSeconds
        self.mediaSession = mediaSession
    }

    func configure(controller: PlaybackController, item: MediaItem, artworkRequest: URLRequest?) {
        teardown()
        self.controller = controller
        self.item = item
        mediaLease = mediaSession.acquire(owner: .video, commands: commandConfiguration())
        updateNowPlayingInfo()
        loadArtwork(from: artworkRequest)
    }

    func updateNowPlayingInfo() {
        guard let controller, let item, let mediaLease else { return }
        let elapsedSeconds = max(0, Double(controller.currentResumeMs) / 1000.0)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyMediaType: MPMediaType.movie.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: controller.transport.showsPausedControl ? 0.0 : Double(controller.player.rate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(controller.player.defaultRate),
        ]
        if let durationSeconds = durationSeconds(for: controller) {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        if let subtitle = subtitle(for: item) {
            info[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        if let artworkImage {
            info[MPMediaItemPropertyArtwork] = NowPlayingArtwork.make(artworkImage)
        }
        mediaLease.publish(nowPlayingInfo: info,
                           playbackState: controller.transport.showsPausedControl ? .paused : .playing)
    }

    func teardown() {
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
        let skipIntervals: [NSNumber] = [10, 30]
        return .init(handlers: [
            .play: { [weak self] _ in
                guard let self, let controller = self.controller else { return .noActionableItem }
                controller.requestPlay()
                self.updateNowPlayingInfo()
                return .success
            },
            .pause: { [weak self] _ in
                guard let self, let controller = self.controller else { return .noActionableItem }
                controller.requestPause()
                self.updateNowPlayingInfo()
                return .success
            },
            .togglePlayPause: { [weak self] _ in
                guard let self, let controller = self.controller else { return .noActionableItem }
                controller.togglePlayback()
                self.updateNowPlayingInfo()
                return .success
            },
            .changePlaybackPosition: { [weak self] event in
                guard let self else { return .noActionableItem }
                return self.performRemoteCommand(
                    VideoNowPlayingCommandPolicy.seekIntent(
                        positionTime: event.positionTime,
                        durationMilliseconds: self.controller?.videoNowPlayingDurationMilliseconds))
            },
            .skipForward: { [weak self, defaultSkipIntervalSeconds] event in
                guard let self else { return .noActionableItem }
                return self.performRemoteCommand(
                    VideoNowPlayingCommandPolicy.skipIntent(
                        interval: event.skipInterval,
                        fallbackSeconds: defaultSkipIntervalSeconds,
                        direction: .forward))
            },
            .skipBackward: { [weak self, defaultSkipIntervalSeconds] event in
                guard let self else { return .noActionableItem }
                return self.performRemoteCommand(
                    VideoNowPlayingCommandPolicy.skipIntent(
                        interval: event.skipInterval,
                        fallbackSeconds: defaultSkipIntervalSeconds,
                        direction: .backward))
            },
        ], skipForwardIntervals: skipIntervals, skipBackwardIntervals: skipIntervals,
           didBecomeCurrent: { [weak self] _ in
               Task { @MainActor [weak self] in self?.updateNowPlayingInfo() }
           })
    }

    private func loadArtwork(from request: URLRequest?) {
        artworkTask?.cancel()
        artworkImage = nil
        guard let request else { return }
        let lease = mediaLease
        artworkTask = Task { [weak self] in
            guard let data = await Self.fetchArtworkData(request: request),
                  let image = UIImage(data: data), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.mediaLease === lease else { return }
                self.artworkImage = image
                // Keep the result while another owner is momentarily current. The lease's
                // didBecomeCurrent hook republishes it when video regains ownership.
                if lease?.isCurrent == true {
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    private nonisolated static func fetchArtworkData(request: URLRequest) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) { return nil }
            return data.isEmpty ? nil : data
        } catch { return nil }
    }

    private func durationSeconds(for controller: PlaybackController) -> Double? {
        if let duration = controller.player.currentItem?.duration.seconds,
           duration.isFinite, duration > 0 { return duration }
        if let durationMs = item?.duration, durationMs > 0 { return Double(durationMs) / 1000.0 }
        return nil
    }

    private func subtitle(for item: MediaItem) -> String? {
        if item.kind == .episode {
            let parts = [item.grandparentTitle, item.seasonEpisodeCode].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        return item.year.map(String.init)
    }

    private func performRemoteCommand(_ intent: VideoNowPlayingCommandPolicy.Intent?)
        -> SystemMediaSessionCoordinator.CommandStatus {
        guard let controller else { return .noActionableItem }
        guard let intent else { return .failed }
        controller.performVideoNowPlayingCommand(intent)
        updateNowPlayingInfo()
        return .success
    }
}
#endif
