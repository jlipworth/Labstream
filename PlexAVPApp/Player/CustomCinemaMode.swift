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
    static let rewindButtonName = "custom-cinema-rewind-30-button"
    static let playPauseButtonName = "custom-cinema-play-pause-button"
    static let forwardButtonName = "custom-cinema-forward-30-button"
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
    var shouldReopenMainWindowOnDismiss = false

    var player: AVPlayer? { controller?.player }
    var hasActivePlayer: Bool { controller != nil }

    func activate(title: String, controller: PlaybackController) {
        self.title = title
        self.controller = controller
    }

    /// Called by the in-immersive Exit Cinema control.
    ///
    /// This deliberately tears down the active playback session before the immersive space is
    /// dismissed. It may reopen the normal app window after playback has stopped, but it does not
    /// try to preserve or rehydrate the same player window. Earlier restore hacks caused
    /// Home-screen bugs plus duplicate audio on device. The control rail owns a clean stop/clear
    /// boundary instead: one AVPlayer session enters Cinema, and that same session is stopped
    /// before leaving Cinema.
    func markMainWindowDetached() {
        shouldReopenMainWindowOnDismiss = true
    }

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
        shouldReopenMainWindowOnDismiss = false
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
    @Environment(\.openWindow) private var openWindow

    @State private var controlsVisible = false
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
            controlsVisible = false
        }
        .onDisappear {
            print("[Custom Cinema] black immersive closed: title=\(session.title ?? "none"); hasPlayer=\(session.hasActivePlayer); reopenMain=\(session.shouldReopenMainWindowOnDismiss)")
            controlsHideTask?.cancel()
            controlsVisible = false
            if session.shouldReopenMainWindowOnDismiss {
                // Covers system/Crown immersive dismissal after the player WindowGroup was
                // detached. Stop playback first so returning to Home never leaves hidden audio.
                session.stopAndClearForImmersiveExit()
                openWindow(id: CustomCinemaMode.mainWindowID)
                session.clear()
            } else if session.presentationState != .closed {
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
        case CustomCinemaMode.rewindButtonName:
            print("[Custom Cinema] native rewind 30 tapped")
            seekRelative(seconds: -30)
        case CustomCinemaMode.playPauseButtonName:
            print("[Custom Cinema] native play/pause tapped")
            togglePlayback()
        case CustomCinemaMode.forwardButtonName:
            print("[Custom Cinema] native forward 30 tapped")
            seekRelative(seconds: 30)
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
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            controlsVisible = false
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
    private func seekRelative(seconds: Int) {
        guard let controller = session.controller else { return }
        controller.performRelativeUserSeek(bySeconds: seconds)
        revealControls()
    }

    @MainActor
    private func exitCinema() {
        controlsHideTask?.cancel()
        controlsVisible = false
        session.stopAndClearForImmersiveExit()
        Task { @MainActor in
            await dismissImmersiveSpace()
            if session.shouldReopenMainWindowOnDismiss {
                openWindow(id: CustomCinemaMode.mainWindowID)
            }
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

        let back = ModelEntity(mesh: .generateBox(width: 2.25,
                                                  height: 0.28,
                                                  depth: 0.025,
                                                  cornerRadius: 0.12),
                               materials: [UnlitMaterial(color: UIColor(white: 0.03, alpha: 0.38))])
        back.name = "custom-cinema-controls-background"
        root.addChild(back)

        let rewind = makeButton(name: CustomCinemaMode.rewindButtonName,
                                label: "-30",
                                x: -0.72,
                                width: 0.42,
                                color: UIColor(white: 0.12, alpha: 0.58))
        root.addChild(rewind)

        let play = makeButton(name: CustomCinemaMode.playPauseButtonName,
                              label: isPaused ? "Play" : "Pause",
                              x: -0.20,
                              width: 0.54,
                              color: UIColor(white: 0.12, alpha: 0.58))
        root.addChild(play)

        let forward = makeButton(name: CustomCinemaMode.forwardButtonName,
                                 label: "+30",
                                 x: 0.36,
                                 width: 0.42,
                                 color: UIColor(white: 0.12, alpha: 0.58))
        root.addChild(forward)

        let exit = makeButton(name: CustomCinemaMode.exitButtonName,
                              label: "Exit",
                              x: 0.88,
                              width: 0.50,
                              color: UIColor(red: 0.34, green: 0.05, blue: 0.05, alpha: 0.62))
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
