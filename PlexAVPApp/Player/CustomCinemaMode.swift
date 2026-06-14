import AVFoundation
import SwiftUI

/// Shared identifiers and active-session state for the custom-player Cinema Mode work.
///
/// The AVKit path gets Apple's cinema environment via `AVPlayerViewController`. The custom
/// AVPlayerLayer path cannot reuse that controller chrome, so its Cinema Mode is an app-owned
/// visionOS scene that still leans on Apple primitives: `ImmersiveSpace`, SwiftUI scene content,
/// and the same `AVPlayer` the custom player already owns.
enum CustomCinemaMode {
    static let immersiveSpaceID = "custom-player-cinema"
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
    var player: AVPlayer?
    var presentationState: PresentationState = .closed

    var hasActivePlayer: Bool { player != nil }

    func activate(title: String, player: AVPlayer) {
        self.title = title
        self.player = player
    }

    func clear() {
        title = nil
        player = nil
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

    var body: some View {
        ZStack {
            if let player = session.player {
                cinemaSurface(player: player)
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

    private func cinemaSurface(player: AVPlayer) -> some View {
        VStack(spacing: 18) {
            Text(session.title ?? "Cinema Mode")
                .font(.title2.weight(.semibold))
                .lineLimit(1)

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

            Button {
                Task { @MainActor in
                    session.presentationState = .inTransition
                    await dismissImmersiveSpace()
                }
            } label: {
                Label("Exit Cinema", systemImage: "rectangle.on.rectangle.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 46, style: .continuous))
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
