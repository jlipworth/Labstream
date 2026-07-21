#if os(visionOS)
import AVFoundation
import MediaPlayer
import PMSKit
import UIKit

/// Video-only Now Playing owner for the app's custom AVPlayer path.
///
/// Uses `MPNowPlayingSession(players:)` so video commands/info are scoped to the
/// active playback session instead of the process-global command center used by music.
/// Automatic publishing stays enabled; all metadata is attached to
/// `AVPlayerItem.nowPlayingInfo`, never to `session.nowPlayingInfoCenter`.
@MainActor
final class VideoNowPlayingCoordinator {
    private weak var controller: PlaybackController?
    private let player: AVPlayer
    private let session: MPNowPlayingSession
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []

    init(controller: PlaybackController) {
        self.controller = controller
        self.player = controller.player
        self.session = MPNowPlayingSession(players: [controller.player])
        self.session.automaticallyPublishesNowPlayingInfo = true
        registerCommands()
        session.becomeActiveIfPossible { _ in }
    }

    deinit {
        // `stop()` should have removed targets on the main actor; keep deinit side-effect-free
        // because MPRemoteCommandCenter objects are main-thread oriented.
    }

    func applyInitialMetadata(to playerItem: AVPlayerItem,
                              mediaItem: MediaItem,
                              durationMilliseconds: Int?,
                              elapsedMilliseconds: Int,
                              playbackRate: Double,
                              defaultPlaybackRate: Double,
                              artworkData: Data? = nil) {
        playerItem.nowPlayingInfo = Self.nowPlayingInfo(mediaItem: mediaItem,
                                                        durationMilliseconds: durationMilliseconds,
                                                        elapsedMilliseconds: elapsedMilliseconds,
                                                        playbackRate: playbackRate,
                                                        defaultPlaybackRate: defaultPlaybackRate,
                                                        artworkData: artworkData)
    }

    func refreshDynamicMetadata(mediaItem: MediaItem,
                                durationMilliseconds: Int?,
                                elapsedMilliseconds: Int,
                                playbackRate: Double,
                                defaultPlaybackRate: Double) {
        guard let playerItem = player.currentItem else { return }
        var info = playerItem.nowPlayingInfo
            ?? Self.nowPlayingInfo(mediaItem: mediaItem,
                                   durationMilliseconds: durationMilliseconds,
                                   elapsedMilliseconds: elapsedMilliseconds,
                                   playbackRate: playbackRate,
                                   defaultPlaybackRate: defaultPlaybackRate)
        if let durationMilliseconds, durationMilliseconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMilliseconds) / 1000.0
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(max(0, elapsedMilliseconds)) / 1000.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = defaultPlaybackRate
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        playerItem.nowPlayingInfo = info
    }

    func clearCurrentItemMetadata() {
        player.currentItem?.nowPlayingInfo = nil
    }

    func stop() {
        clearCurrentItemMetadata()
        removeCommandTargets()
        setCommandAvailability(enabled: false)
        // Deliberately no `session.removePlayer(player)`: MPNowPlayingSession documents a
        // non-empty players invariant, and releasing the coordinator (the session's only
        // owner) detaches it from the player anyway.
    }

    private func registerCommands() {
        let center = session.remoteCommandCenter

        setCommandAvailability(enabled: true)
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 10)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: 30)]

        store(center.playCommand) { [weak self] _ in
            self?.dispatchMainCommand { controller in
                controller.requestPlay()
            } ?? .commandFailed
        }
        store(center.pauseCommand) { [weak self] _ in
            self?.dispatchMainCommand { controller in
                controller.requestPause()
            } ?? .commandFailed
        }
        store(center.togglePlayPauseCommand) { [weak self] _ in
            self?.dispatchMainCommand { controller in
                controller.togglePlayback()
            } ?? .commandFailed
        }
        store(center.skipBackwardCommand) { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent,
                  let intent = VideoNowPlayingCommandPolicy.skipIntent(
                    interval: event.interval,
                    fallbackSeconds: 10,
                    direction: .backward) else { return .commandFailed }
            return self?.dispatchMainCommand { controller in
                controller.performVideoNowPlayingCommand(intent)
            } ?? .commandFailed
        }
        store(center.skipForwardCommand) { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent,
                  let intent = VideoNowPlayingCommandPolicy.skipIntent(
                    interval: event.interval,
                    fallbackSeconds: 30,
                    direction: .forward) else { return .commandFailed }
            return self?.dispatchMainCommand { controller in
                controller.performVideoNowPlayingCommand(intent)
            } ?? .commandFailed
        }
        store(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return self?.dispatchPlaybackPositionCommand(event.positionTime) ?? .commandFailed
        }
    }

    private func store(_ command: MPRemoteCommand,
                       handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        let target = command.addTarget(handler: handler)
        commandTargets.append((command: command, target: target))
    }

    private func dispatchMainCommand(_ action: @escaping @MainActor (PlaybackController) -> Void) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { () -> MPRemoteCommandHandlerStatus in
                guard let controller, controller.player.currentItem != nil else {
                    return .noActionableNowPlayingItem
                }
                action(controller)
                return .success
            }
        }
        Task { @MainActor [weak self] in
            guard let self,
                  let controller = self.controller,
                  controller.player.currentItem != nil,
                  !Task.isCancelled else { return }
            action(controller)
        }
        return .success
    }

    private func dispatchPlaybackPositionCommand(_ positionTime: Double)
        -> MPRemoteCommandHandlerStatus {
        // Validate before returning a synchronous status, without reading MainActor controller
        // state from a MediaPlayer callback that may arrive off-main.
        guard VideoNowPlayingCommandPolicy.seekIntent(positionTime: positionTime,
                                                      durationMilliseconds: nil) != nil else {
            return .commandFailed
        }
        return dispatchMainCommand { controller in
            // The first validation guarantees an intent; resolve the final duration clamp only
            // after dispatch has safely reached the controller's actor.
            guard let intent = VideoNowPlayingCommandPolicy.seekIntent(
                positionTime: positionTime,
                durationMilliseconds: controller.videoNowPlayingDurationMilliseconds) else { return }
            controller.performVideoNowPlayingCommand(intent)
        }
    }

    private func removeCommandTargets() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets.removeAll()
    }

    private func setCommandAvailability(enabled: Bool) {
        let center = session.remoteCommandCenter
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
        center.skipForwardCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled

        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.stopCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
        center.ratingCommand.isEnabled = false
        center.likeCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
        center.bookmarkCommand.isEnabled = false
        center.changeShuffleModeCommand.isEnabled = false
        center.changeRepeatModeCommand.isEnabled = false
    }

    private static func nowPlayingInfo(mediaItem item: MediaItem,
                                       durationMilliseconds: Int?,
                                       elapsedMilliseconds: Int,
                                       playbackRate: Double,
                                       defaultPlaybackRate: Double,
                                       artworkData: Data? = nil) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(max(0, elapsedMilliseconds)) / 1000.0,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: defaultPlaybackRate,
        ]
        if let durationMilliseconds, durationMilliseconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMilliseconds) / 1000.0
        }
        if let context = contextLabel(for: item) {
            info[MPMediaItemPropertyAlbumTitle] = context
        }
        if let year = item.year {
            info[MPMediaItemPropertyReleaseDate] = DateComponents(calendar: Calendar(identifier: .gregorian),
                                                                  year: year,
                                                                  month: 1,
                                                                  day: 1).date
        }
        if let artworkData,
           let image = UIImage(data: artworkData) {
            info[MPMediaItemPropertyArtwork] = NowPlayingArtwork.make(image)
        }
        return info
    }

    private static func contextLabel(for item: MediaItem) -> String? {
        if item.kind == .episode {
            var parts: [String] = []
            if let show = item.grandparentTitle, !show.isEmpty { parts.append(show) }
            if let code = item.seasonEpisodeCode {
                // Shared "S1E3" formatting — keeps the Now Playing card consistent with
                // every other episode label in the app.
                parts.append(code)
            } else if let seasonTitle = item.parentTitle, !seasonTitle.isEmpty {
                parts.append(seasonTitle)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        if let year = item.year { return String(year) }
        return nil
    }

}
#endif
