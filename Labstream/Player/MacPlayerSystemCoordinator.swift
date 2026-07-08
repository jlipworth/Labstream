#if os(macOS)
import AVFoundation
import Foundation
import MediaPlayer
import PMSKit

/// macOS system integration for the app-owned custom video player.
///
/// The player surface stays custom (`AVPlayerLayer` + Labstream chrome), but the Mac app still
/// needs to participate in the system Now Playing/remote-command stack so keyboard media keys,
/// Control Center, headphones, and external transport surfaces control the active video instead
/// of stale music or another app.
@MainActor
final class MacPlayerSystemCoordinator {
    private weak var controller: PlaybackController?
    private var item: MediaItem?
    private var remoteCommandTargets: [Any] = []
    private var previousRemoteCommandState: RemoteCommandState?
    private var nowPlayingOwner = UUID()
    private var artworkImage: UIImage?
    private var artworkTask: Task<Void, Never>?

    private struct RemoteCommandState {
        let playEnabled: Bool
        let pauseEnabled: Bool
        let toggleEnabled: Bool
        let changePositionEnabled: Bool
        let skipForwardEnabled: Bool
        let skipBackwardEnabled: Bool
        let skipForwardIntervals: [NSNumber]
        let skipBackwardIntervals: [NSNumber]
    }

    func configure(controller: PlaybackController, item: MediaItem, artworkRequest: URLRequest? = nil) {
        self.controller = controller
        self.item = item
        nowPlayingOwner = UUID()

        registerRemoteCommands()
        updateNowPlayingInfo()
        loadArtwork(from: artworkRequest)
    }

    func updateNowPlayingInfo() {
        guard let controller, let item else { return }
        let durationSeconds = durationSeconds(for: controller)
        let elapsedSeconds = max(0, Double(controller.currentResumeMs) / 1000.0)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyMediaType: MPMediaType.movie.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: controller.transport.showsPausedControl ? 0.0 : Double(controller.player.rate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(controller.player.defaultRate),
            "LabstreamNowPlayingOwner": nowPlayingOwner.uuidString,
        ]
        if let durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        if let subtitle = subtitle(for: item) {
            info[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        if let artworkImage {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(artworkImage)
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = controller.transport.showsPausedControl ? .paused : .playing
    }

    func teardown() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkImage = nil
        removeRemoteCommands()
        controller = nil
        item = nil
        clearNowPlayingInfoIfOwned()
    }

    private func loadArtwork(from request: URLRequest?) {
        artworkTask?.cancel()
        artworkImage = nil
        guard let request else { return }
        artworkTask = Task { [weak self] in
            guard let data = await Self.fetchArtworkData(request: request),
                  let image = UIImage(data: data),
                  !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.artworkImage = image
                self.updateNowPlayingInfo()
            }
        }
    }

    private func durationSeconds(for controller: PlaybackController) -> Double? {
        if let duration = controller.player.currentItem?.duration.seconds,
           duration.isFinite,
           duration > 0 {
            return duration
        }
        if let durationMs = item?.duration, durationMs > 0 {
            return Double(durationMs) / 1000.0
        }
        return nil
    }

    private func subtitle(for item: MediaItem) -> String? {
        if item.kind == .episode {
            let parts = [item.grandparentTitle, item.seasonEpisodeCode].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        return item.year.map(String.init)
    }

    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private nonisolated static func fetchArtworkData(request: URLRequest) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) { return nil }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    private func registerRemoteCommands() {
        removeRemoteCommandTargets()
        let center = MPRemoteCommandCenter.shared()
        previousRemoteCommandState = captureRemoteCommandState(center)
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10, 30]
        center.skipBackwardCommand.preferredIntervals = [10, 30]

        remoteCommandTargets.append(center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let controller = self.controller else { return }
                controller.requestPlay()
                self.updateNowPlayingInfo()
            }
            return .success
        })
        remoteCommandTargets.append(center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let controller = self.controller else { return }
                controller.requestPause()
                self.updateNowPlayingInfo()
            }
            return .success
        })
        remoteCommandTargets.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, let controller = self.controller else { return }
                controller.togglePlayback()
                self.updateNowPlayingInfo()
            }
            return .success
        })
        remoteCommandTargets.append(center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .noActionableNowPlayingItem
            }
            let targetMs = Int((event.positionTime * 1000).rounded())
            Task { @MainActor in
                guard let self, let controller = self.controller else { return }
                controller.performUserSeek(toMs: targetMs)
                self.updateNowPlayingInfo()
            }
            return .success
        })
        remoteCommandTargets.append(center.skipForwardCommand.addTarget { [weak self] event in
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            Task { @MainActor in
                self?.performRemoteSkip(seconds: seconds, direction: 1)
            }
            return .success
        })
        remoteCommandTargets.append(center.skipBackwardCommand.addTarget { [weak self] event in
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
            Task { @MainActor in
                self?.performRemoteSkip(seconds: seconds, direction: -1)
            }
            return .success
        })
    }

    private func removeRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        removeRemoteCommandTargets(center)
        if let previousRemoteCommandState {
            restoreRemoteCommandState(previousRemoteCommandState, center: center)
            self.previousRemoteCommandState = nil
        }
    }

    private func removeRemoteCommandTargets(_ center: MPRemoteCommandCenter = .shared()) {
        let commands: [MPRemoteCommand] = [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.changePlaybackPositionCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
        ]
        for target in remoteCommandTargets {
            for command in commands {
                command.removeTarget(target)
            }
        }
        remoteCommandTargets.removeAll()
    }

    private func captureRemoteCommandState(_ center: MPRemoteCommandCenter) -> RemoteCommandState {
        RemoteCommandState(playEnabled: center.playCommand.isEnabled,
                           pauseEnabled: center.pauseCommand.isEnabled,
                           toggleEnabled: center.togglePlayPauseCommand.isEnabled,
                           changePositionEnabled: center.changePlaybackPositionCommand.isEnabled,
                           skipForwardEnabled: center.skipForwardCommand.isEnabled,
                           skipBackwardEnabled: center.skipBackwardCommand.isEnabled,
                           skipForwardIntervals: center.skipForwardCommand.preferredIntervals,
                           skipBackwardIntervals: center.skipBackwardCommand.preferredIntervals)
    }

    private func restoreRemoteCommandState(_ state: RemoteCommandState,
                                           center: MPRemoteCommandCenter) {
        center.playCommand.isEnabled = state.playEnabled
        center.pauseCommand.isEnabled = state.pauseEnabled
        center.togglePlayPauseCommand.isEnabled = state.toggleEnabled
        center.changePlaybackPositionCommand.isEnabled = state.changePositionEnabled
        center.skipForwardCommand.isEnabled = state.skipForwardEnabled
        center.skipBackwardCommand.isEnabled = state.skipBackwardEnabled
        center.skipForwardCommand.preferredIntervals = state.skipForwardIntervals
        center.skipBackwardCommand.preferredIntervals = state.skipBackwardIntervals
    }

    private func performRemoteSkip(seconds: Double, direction: Int) {
        guard let controller else { return }
        let currentMs = controller.currentResumeMs
        let targetMs = max(0, currentMs + Int((seconds * 1000).rounded()) * direction)
        controller.performUserSeek(toMs: targetMs)
        updateNowPlayingInfo()
    }

    private func clearNowPlayingInfoIfOwned() {
        let center = MPNowPlayingInfoCenter.default()
        guard (center.nowPlayingInfo?["LabstreamNowPlayingOwner"] as? String) == nowPlayingOwner.uuidString else {
            return
        }
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}
#endif
