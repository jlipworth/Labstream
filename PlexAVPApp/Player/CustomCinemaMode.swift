import AVFoundation
import PMSKit
import SwiftUI

/// Shared identifiers and active-session state for the custom-player Cinema Mode work.
///
/// Apple's cinema environment is only available through `AVPlayerViewController`, which the
/// custom `AVPlayerLayer` player cannot reuse — so Cinema Mode is an app-owned visionOS scene
/// that still leans on Apple primitives: `ImmersiveSpace`, SwiftUI scene content, and the same
/// `AVPlayer` the custom player already owns.
enum CustomCinemaMode {
    static let immersiveSpaceID = "custom-player-cinema"

    /// The custom-player "Cinema" scene is intentionally hidden from the shipping chrome for now.
    ///
    /// On Apple Vision Pro hardware it does not behave like Apple's AVKit Cinema Environment:
    /// entering it from a fully immersed Environment can pull the viewer out of that environment,
    /// and it does not provide the expected system-managed screen placement/scale. Since the
    /// custom player no longer uses `AVPlayerViewController`, it cannot reuse the system Cinema
    /// Environment directly. Keep the scaffold in-tree for future RealityKit/immersive-player
    /// work, but do not expose a net-negative button in the player UI.
    static let isUserVisible = false
}

@Observable
@MainActor
final class CustomCinemaSessionStore {
    enum PresentationState: Equatable {
        case closed
        case inTransition
        case open
    }

    var title: String?
    var controller: PlaybackController?
    var presentationState: PresentationState = .closed

    var player: AVPlayer? { controller?.player }
    var hasActivePlayer: Bool { controller != nil }

    func activate(title: String, controller: PlaybackController) {
        self.title = title
        self.controller = controller
    }

    func clear() {
        title = nil
        controller = nil
        presentationState = .closed
    }
}

/// Apple-scene-backed theater surface for the experimental custom player.
///
/// This deliberately does not reintroduce the old AVKit three-state animation workaround. The
/// custom route has the normal custom-player presentation plus this explicit Cinema scene. The
/// scene reads the active backend-neutral session and renders the same `AVPlayer` through the
/// app-owned `AVPlayerLayer` presenter used by `CustomPlayerView`.
struct CustomCinemaScaffoldView: View {
    @Environment(CustomCinemaSessionStore.self) private var session
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// Cinema owns its own scrubber clock so the reused chrome has a live timeline; the
    /// windowed player keeps its own. Both read the same shared `controller`.
    @State private var scrubState = PlaybackScrubState(durationMs: 0, livePositionMs: 0)

    var body: some View {
        ZStack {
            if let controller = session.controller, let player = session.player {
                cinemaSurface(controller: controller, player: player)
            } else {
                inactiveState
            }
        }
        .onAppear { session.presentationState = .open }
        .onDisappear {
            if session.presentationState != .closed {
                session.presentationState = .closed
            }
        }
    }

    private func cinemaSurface(controller: PlaybackController, player: AVPlayer) -> some View {
        // Full normal-mode control parity: the Cinema scene hosts the SAME `CustomPlayerChrome`
        // as the windowed player (play/pause, scrubber, skip, and the Quality/Subtitles/Audio/
        // Chapters/Speed/Stats menu). The chrome's cinema button auto-flips to "Exit Cinema"
        // because `presentationState == .open`; `onClose` is nil so no redundant window-close
        // affordance appears inside the theater.
        PlayerLayerView(player: player)
            .frame(width: 1180, height: 664)
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .background {
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(.black.opacity(0.92))
                    .shadow(color: .black.opacity(0.45), radius: 38, y: 18)
            }
            .overlay {
                CustomPlayerChrome(controller: controller,
                                   title: session.title ?? "Cinema Mode",
                                   scrubState: $scrubState,
                                   isReconnecting: false,
                                   onRetry: { session.controller?.retry() },
                                   onClose: nil)
            }
            .padding(30)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 46, style: .continuous))
            .task(id: session.controller != nil) { await runCinemaClock(controller) }
    }

    private func runCinemaClock(_ controller: PlaybackController) async {
        await MainActor.run {
            tickCustomScrubberClock(&scrubState, from: controller, fallbackDurationMs: 0)
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                guard let controller = session.controller else { return }
                tickCustomScrubberClock(&scrubState, from: controller, fallbackDurationMs: 0)
            }
        }
    }

    private var inactiveState: some View {
        VStack(spacing: 14) {
            Image(systemName: "theatermasks")
                .font(.largeTitle.weight(.semibold))
            Text("Cinema Mode")
                .font(.title2.weight(.semibold))
            Text("Start playback from the custom player, then open Cinema.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task { @MainActor in
                    session.presentationState = .inTransition
                    await dismissImmersiveSpace()
                }
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
