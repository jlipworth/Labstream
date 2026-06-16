import AVFoundation
import PMSKit
import RealityKit
import SwiftUI

/// Shared identifiers and active-session state for the custom-player Cinema scaffold.
///
/// Apple's cinema environment is only available through `AVPlayerViewController`, which the
/// custom `AVPlayerLayer` player cannot reuse — so Cinema Mode is an app-owned visionOS scene
/// that still leans on Apple primitives: `ImmersiveSpace`, SwiftUI scene content, and the same
/// `AVPlayer` the custom player already owns.
///
/// Do not use this as the issue #12 implementation path. The RealityKit theater work now lives
/// behind `RealityTheaterFeature` / `RealityTheaterSessionStore` and stays separately hidden until
/// real-device behavior is proven.
enum CustomCinemaMode {
    static let immersiveSpaceID = "custom-player-cinema"
    static let mainWindowID = "main-window"

    /// The custom-player "Cinema" scene is visible while we iterate on a black true-immersive
    /// theater route.
    ///
    /// This deliberately stays as only the proven video plane. Immersive controls are being
    /// explored on a separate branch so this branch remains safe for headset testing.
    static let isUserVisible = true

    static let screenWidthMeters: Float = 9.4
    static let screenDistanceMeters: Float = 7.0
    static let verticalOffsetMeters: Float = 0.65
    static let aspectRatio: Float = 16.0 / 9.0

    static var screenHeightMeters: Float { screenWidthMeters / aspectRatio }
    static var screenPosition: SIMD3<Float> {
        SIMD3<Float>(0, verticalOffsetMeters, -screenDistanceMeters)
    }
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
    var shouldRestoreMainWindowOnDismiss = false

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
        shouldRestoreMainWindowOnDismiss = false
    }
}

/// Minimal black immersive theater surface for the custom player.
///
/// This intentionally does NOT host `PlayerLayerView` or the full `CustomPlayerChrome`. It renders
/// the active `AVPlayer` as a RealityKit `VideoMaterial` plane and nothing else. Controls are being
/// designed on a separate branch because the temporary button/window-restore experiments created
/// unsafe duplicate-playback states on device.
struct CustomCinemaScaffoldView: View {
    @Environment(CustomCinemaSessionStore.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RealityView { content in
            content.add(Self.makeRoot(player: session.player))
        } update: { content in
            content.entities.removeAll(where: { $0.name == "custom-cinema-root" })
            content.add(Self.makeRoot(player: session.player))
        }
        .preferredSurroundingsEffect(.ultraDark)
        .onAppear {
            print("[Custom Cinema] black immersive opened: width \(CustomCinemaMode.screenWidthMeters)m · distance \(CustomCinemaMode.screenDistanceMeters)m · vertical \(CustomCinemaMode.verticalOffsetMeters)m; title=\(session.title ?? "none"); hasPlayer=\(session.hasActivePlayer)")
            session.presentationState = .open
        }
        .onDisappear {
            print("[Custom Cinema] black immersive closed: title=\(session.title ?? "none"); hasPlayer=\(session.hasActivePlayer)")
            reopenMainWindowIfNeeded()
            if session.presentationState != .closed {
                session.presentationState = .closed
            }
        }
    }

    @MainActor
    private static func makeRoot(player: AVPlayer?) -> Entity {
        let root = Entity()
        root.name = "custom-cinema-root"

        let screen: ModelEntity
        if let player {
            let material = VideoMaterial(avPlayer: player)
            screen = ModelEntity(mesh: .generatePlane(width: CustomCinemaMode.screenWidthMeters,
                                                      height: CustomCinemaMode.screenHeightMeters),
                                 materials: [material])
            screen.name = "custom-cinema-video-plane"
        } else {
            screen = ModelEntity(mesh: .generatePlane(width: CustomCinemaMode.screenWidthMeters,
                                                      height: CustomCinemaMode.screenHeightMeters),
                                 materials: [SimpleMaterial(color: .black,
                                                            roughness: 1.0,
                                                            isMetallic: false)])
            screen.name = "custom-cinema-empty-plane"
        }
        screen.position = CustomCinemaMode.screenPosition
        root.addChild(screen)
        return root
    }

    private func reopenMainWindowIfNeeded() {
        guard session.shouldRestoreMainWindowOnDismiss else { return }
        session.shouldRestoreMainWindowOnDismiss = false
        openWindow(id: CustomCinemaMode.mainWindowID)
    }
}
