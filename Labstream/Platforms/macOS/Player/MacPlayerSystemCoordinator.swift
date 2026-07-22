import Foundation
import PMSKit

/// macOS system integration for the app-owned custom video player.
///
/// The player surface stays custom (`AVPlayerLayer` + Labstream chrome), but the Mac app still
/// needs to participate in the system Now Playing/remote-command stack so keyboard media keys,
/// Control Center, headphones, and external transport surfaces control the active video instead
/// of stale music or another app. All of that machinery lives in the shared
/// `VideoNowPlayingCore`; the Mac has no extra platform surfaces (no PiP/AirPlay), so this
/// coordinator is a thin platform-named facade.
@MainActor
final class MacPlayerSystemCoordinator {
    private let core: VideoNowPlayingCore

    init(mediaSession: SystemMediaSessionCoordinator) {
        core = VideoNowPlayingCore(commandProfile: .processWide(fallbackSeconds: 30),
                                   mediaSession: mediaSession)
    }

    func configure(controller: PlaybackController,
                   item: MediaItem,
                   artworkDescriptor: ArtworkRequestDescriptor? = nil,
                   artworkPipeline: ArtworkPipeline? = nil) {
        core.configure(controller: controller,
                       item: item,
                       artworkDescriptor: artworkDescriptor,
                       artworkPipeline: artworkPipeline)
    }

    func teardown() {
        core.teardown()
    }
}
