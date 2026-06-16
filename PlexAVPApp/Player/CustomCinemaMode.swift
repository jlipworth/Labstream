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
    /// This branch starts from the proven video plane and adds only a hidden, intentional
    /// in-immersive control rail for issue #12 headset testing.
    static let isUserVisible = true

    static let screenWidthMeters: Float = 9.4
    static let screenDistanceMeters: Float = 7.0
    static let verticalOffsetMeters: Float = 0.65
    static let aspectRatio: Float = 16.0 / 9.0

    static var screenHeightMeters: Float { screenWidthMeters / aspectRatio }
    static var screenPosition: SIMD3<Float> {
        SIMD3<Float>(0, verticalOffsetMeters, -screenDistanceMeters)
    }

    static let videoPlaneName = "custom-cinema-video-plane"
    static let emptyPlaneName = "custom-cinema-empty-plane"
    static let controlsRootName = "custom-cinema-native-controls"
    static let playPauseButtonName = "custom-cinema-play-pause-button"
    static let exitButtonName = "custom-cinema-exit-button"

    static var controlsPosition: SIMD3<Float> {
        SIMD3<Float>(0, verticalOffsetMeters - (screenHeightMeters / 2.0) - 0.38, -screenDistanceMeters + 0.18)
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

    var player: AVPlayer? { controller?.player }
    var hasActivePlayer: Bool { controller != nil }

    func activate(title: String, controller: PlaybackController) {
        self.title = title
        self.controller = controller
    }

    /// Called by the in-immersive Exit Cinema control.
    ///
    /// This deliberately tears down the active playback session before the immersive space is
    /// dismissed, and it does not call `openWindow`, `dismissWindow`, or the player `onClose`
    /// restore path. Earlier experiments used window dismissal/reopen as a preserve-and-restore
    /// hack and produced Home-screen restore bugs plus duplicate audio on device. The control rail
    /// owns a clean stop/clear boundary instead: one AVPlayer session enters Cinema, and that same
    /// session is stopped before leaving Cinema.
    func stopAndClearForImmersiveExit() {
        let activeController = controller
        title = nil
        controller = nil
        presentationState = .inTransition
        activeController?.stop()
    }

    func clear() {
        title = nil
        controller = nil
        presentationState = .closed
    }
}

/// Minimal black immersive theater surface for the custom player.
///
/// This intentionally does NOT host `PlayerLayerView` or the full `CustomPlayerChrome`. It renders
/// the active `AVPlayer` as a RealityKit `VideoMaterial` plane and uses native RealityKit button
/// entities for controls. SwiftUI `RealityView` attachments were tried on device and did not appear
/// reliably in this black immersive scene; native entities are less pretty, but they avoid both the
/// attachment visibility failure and the earlier window-reopen duplicate-audio failure.
struct CustomCinemaScaffoldView: View {
    @Environment(CustomCinemaSessionStore.self) private var session
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var controlsVisible = true
    @State private var controlsHideTask: Task<Void, Never>?

    var body: some View {
        RealityView { content in
            content.add(Self.makeRoot(player: session.player,
                                      controlsVisible: controlsVisible,
                                      isPaused: session.controller?.transport.isPaused ?? true))
        } update: { content in
            content.entities.removeAll(where: { $0.name == "custom-cinema-root" })
            content.add(Self.makeRoot(player: session.player,
                                      controlsVisible: controlsVisible,
                                      isPaused: session.controller?.transport.isPaused ?? true))
        }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
            Task { @MainActor in
                handleTap(on: value.entity.name)
            }
        })
        .preferredSurroundingsEffect(.ultraDark)
        .onAppear {
            print("[Custom Cinema] black immersive opened: width \(CustomCinemaMode.screenWidthMeters)m · distance \(CustomCinemaMode.screenDistanceMeters)m · vertical \(CustomCinemaMode.verticalOffsetMeters)m; title=\(session.title ?? "none"); hasPlayer=\(session.hasActivePlayer)")
            session.presentationState = .open
            controlsVisible = session.hasActivePlayer
        }
        .onDisappear {
            print("[Custom Cinema] black immersive closed: title=\(session.title ?? "none"); hasPlayer=\(session.hasActivePlayer)")
            controlsHideTask?.cancel()
            controlsVisible = false
            if session.presentationState != .closed {
                session.presentationState = .closed
            }
        }
    }

    @MainActor
    private func handleTap(on entityName: String) {
        switch entityName {
        case CustomCinemaMode.videoPlaneName, CustomCinemaMode.emptyPlaneName:
            print("[Custom Cinema] video plane tapped; revealing native controls")
            revealControls()
        case CustomCinemaMode.playPauseButtonName:
            print("[Custom Cinema] native play/pause tapped")
            togglePlayback()
        case CustomCinemaMode.exitButtonName:
            print("[Custom Cinema] native exit tapped")
            exitCinema()
        default:
            break
        }
    }

    @MainActor
    private func revealControls() {
        guard session.hasActivePlayer else { return }
        controlsVisible = true
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            // Diagnostic branch: keep controls visible so headset testing can separate native
            // RealityKit control rendering from the currently unreliable video-plane reveal tap.
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            controlsVisible = session.hasActivePlayer
        }
    }

    @MainActor
    private func togglePlayback() {
        guard let controller = session.controller else { return }
        if controller.transport.isPaused {
            controller.player.play()
        } else {
            controller.player.pause()
        }
        revealControls()
    }

    @MainActor
    private func exitCinema() {
        controlsHideTask?.cancel()
        controlsVisible = false
        session.stopAndClearForImmersiveExit()
        Task { @MainActor in
            await dismissImmersiveSpace()
            session.clear()
        }
    }

    @MainActor
    private static func makeRoot(player: AVPlayer?, controlsVisible: Bool, isPaused: Bool) -> Entity {
        let root = Entity()
        root.name = "custom-cinema-root"

        let screen: ModelEntity
        if let player {
            let material = VideoMaterial(avPlayer: player)
            screen = ModelEntity(mesh: .generatePlane(width: CustomCinemaMode.screenWidthMeters,
                                                      height: CustomCinemaMode.screenHeightMeters),
                                 materials: [material])
            screen.name = CustomCinemaMode.videoPlaneName
        } else {
            screen = ModelEntity(mesh: .generatePlane(width: CustomCinemaMode.screenWidthMeters,
                                                      height: CustomCinemaMode.screenHeightMeters),
                                 materials: [SimpleMaterial(color: .black,
                                                            roughness: 1.0,
                                                            isMetallic: false)])
            screen.name = CustomCinemaMode.emptyPlaneName
        }
        screen.position = CustomCinemaMode.screenPosition
        // The visible screen is also the reveal target. Collision is intentionally attached to
        // this rendered plane instead of a separate transparent rectangle so taps cannot be
        // intercepted by an invisible occluder in front of the movie.
        screen.components.set(InputTargetComponent())
        screen.components.set(CollisionComponent(shapes: [
            .generateBox(width: CustomCinemaMode.screenWidthMeters,
                         height: CustomCinemaMode.screenHeightMeters,
                         depth: 0.04)
        ]))
        root.addChild(screen)

        if controlsVisible {
            root.addChild(makeControlsRail(isPaused: isPaused))
        }

        return root
    }

    private static func makeControlsRail(isPaused: Bool) -> Entity {
        let root = Entity()
        root.name = CustomCinemaMode.controlsRootName
        root.position = CustomCinemaMode.controlsPosition

        let back = ModelEntity(mesh: .generateBox(width: 1.62,
                                                  height: 0.28,
                                                  depth: 0.025,
                                                  cornerRadius: 0.12),
                               materials: [UnlitMaterial(color: UIColor(white: 0.03, alpha: 0.55))])
        back.name = "custom-cinema-controls-background"
        root.addChild(back)

        let play = makeButton(name: CustomCinemaMode.playPauseButtonName,
                              label: isPaused ? "Play" : "Pause",
                              x: -0.37,
                              width: 0.54,
                              color: UIColor(white: 0.16, alpha: 0.72))
        root.addChild(play)

        let exit = makeButton(name: CustomCinemaMode.exitButtonName,
                              label: "Exit",
                              x: 0.42,
                              width: 0.50,
                              color: UIColor(red: 0.46, green: 0.08, blue: 0.08, alpha: 0.76))
        root.addChild(exit)

        return root
    }

    private static func makeButton(name: String, label: String, x: Float, width: Float, color: UIColor) -> Entity {
        let root = Entity()
        root.name = "\(name)-root"
        root.position = SIMD3<Float>(x, 0, 0.035)

        let height: Float = 0.18
        let depth: Float = 0.035
        let button = ModelEntity(mesh: .generateBox(width: width,
                                                    height: height,
                                                    depth: depth,
                                                    cornerRadius: height / 2),
                                 materials: [UnlitMaterial(color: color)])
        button.name = name
        button.components.set(InputTargetComponent())
        button.components.set(CollisionComponent(shapes: [.generateBox(width: width, height: height, depth: depth)]))
        root.addChild(button)

        let textMesh = MeshResource.generateText(label,
                                                 extrusionDepth: 0.002,
                                                 font: .systemFont(ofSize: 0.060, weight: .semibold),
                                                 containerFrame: CGRect(x: -CGFloat(width) / 2,
                                                                        y: -0.028,
                                                                        width: CGFloat(width),
                                                                        height: 0.08),
                                                 alignment: .center,
                                                 lineBreakMode: .byClipping)
        let text = ModelEntity(mesh: textMesh, materials: [UnlitMaterial(color: UIColor(white: 1, alpha: 0.92))])
        text.name = "\(name)-label"
        text.position = SIMD3<Float>(0, -0.022, 0.025)
        root.addChild(text)

        return root
    }
}
