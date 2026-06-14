import RealityKit
import SwiftUI

/// Shared identifiers and first-pass scene shell for the custom-player Cinema Mode work.
///
/// The AVKit path gets Apple's cinema environment via `AVPlayerViewController`. The custom
/// AVPlayerLayer path cannot reuse that controller chrome, so its Cinema Mode needs to be an
/// app-owned scene that still leans on visionOS primitives: `ImmersiveSpace`, `RealityView`,
/// and later a shared playback session that supplies the same `AVPlayer` to a RealityKit video
/// surface.
enum CustomCinemaMode {
    static let immersiveSpaceID = "custom-player-cinema"
}

/// Placeholder RealityKit scene registered by the app so the custom player can grow a real
/// Cinema Mode without reintroducing AVKit's three-mode expanded/embedded workaround.
///
/// Next step: move the active `PlaybackController` into a small shared playback-session object
/// so this scene can render the controller's `AVPlayer` on a RealityKit-backed theater surface
/// while `CustomPlayerView` keeps owning chrome and scrubber state.
struct CustomCinemaScaffoldView: View {
    var body: some View {
        RealityView { _ in
            // Real video content lands here once the custom player exposes a shared playback
            // session. Keeping the scene registered now lets us validate the Apple scene
            // primitives independently from backend-specific Plex/Jellyfin playback behavior.
        } placeholder: {
            VStack(spacing: 14) {
                Image(systemName: "theatermasks")
                    .font(.largeTitle.weight(.semibold))
                Text("Cinema Mode")
                    .font(.title2.weight(.semibold))
                Text("Custom player theater scene wiring in progress")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .realityViewLayoutBehavior(.centered)
    }
}
