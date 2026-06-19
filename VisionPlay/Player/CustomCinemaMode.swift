import AVFoundation
import PMSKit
import RealityKit
import SwiftUI

/// Meter-based layout snapshot for the custom-player Cinema scene.
struct CustomCinemaGeometry: Equatable, Sendable {
    static let `default` = CustomCinemaGeometry(aspectRatio: 16.0 / 9.0)

    /// The active picture aspect ratio, clamped to sane flat-video bounds. The old Cinema
    /// scene hard-coded a 16:9 plane, which made 16:9 content feel too close while narrower
    /// 4:3-ish content happened to feel better. This snapshot lets the immersive plane and its
    /// hit target match the actual content instead of one fixed wall.
    var aspectRatio: Float
    var screenWidthMeters: Float
    var screenDistanceMeters: Float
    var verticalOffsetMeters: Float

    init(aspectRatio rawAspectRatio: Float,
         screenWidthMeters: Float? = nil,
         screenDistanceMeters: Float? = nil,
         verticalOffsetMeters: Float? = nil) {
        let aspect = rawAspectRatio.isFinite ? rawAspectRatio.clamped(to: 1.0...2.76) : 16.0 / 9.0
        self.aspectRatio = aspect

        // Preserve the good 4:3-ish feel, but make 16:9 and scope content a little less
        // face-filling. Values are deliberately conservative because this must be headset-tuned.
        let defaultHeight: Float
        let defaultDistance: Float
        let defaultVertical: Float
        switch aspect {
        case ..<1.55:        // 4:3 / Academy-ish
            defaultHeight = 5.10
            defaultDistance = 6.80
            defaultVertical = 0.55
        case 1.55..<2.05:    // 16:9 / 1.85
            defaultHeight = 4.75
            defaultDistance = 7.75
            defaultVertical = 0.55
        default:             // 2.20 / 2.35 / scope
            defaultHeight = 4.05
            defaultDistance = 7.75
            defaultVertical = 0.48
        }

        let computedWidth = defaultHeight * aspect
        self.screenWidthMeters = (screenWidthMeters ?? computedWidth).clamped(to: 4.2...9.8)
        self.screenDistanceMeters = (screenDistanceMeters ?? defaultDistance).clamped(to: 4.8...9.0)
        self.verticalOffsetMeters = (verticalOffsetMeters ?? defaultVertical).clamped(to: (-0.2)...1.1)
    }

    init(item: MediaItem, mediaIndex: Int) {
        let aspect: Float? = item.media.flatMap { media in
            let selected = media.indices.contains(mediaIndex) ? media[mediaIndex] : media.first
            guard let width = selected?.width, let height = selected?.height,
                  width > 0, height > 0 else { return nil }
            return Float(width) / Float(height)
        }
        self.init(aspectRatio: aspect ?? 16.0 / 9.0)
    }

    var screenHeightMeters: Float { screenWidthMeters / aspectRatio }
    var screenPosition: SIMD3<Float> { SIMD3<Float>(0, verticalOffsetMeters, -screenDistanceMeters) }

    /// Detached near-user controls, inspired by the native AVP player transport. These are not
    /// below/on the movie plane; they sit close enough to be comfortable to tap, while the movie
    /// can remain far enough away to feel cinematic.
    var controlsPosition: SIMD3<Float> { SIMD3<Float>(0, -0.58, -1.22) }

    var debugSummary: String {
        String(format: "aspect %.2f · width %.1fm · distance %.1fm · vertical %.2fm",
               aspectRatio, screenWidthMeters, screenDistanceMeters, verticalOffsetMeters)
    }
}

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

    static let videoPlaneName = "custom-cinema-video-plane"
    static let emptyPlaneName = "custom-cinema-empty-plane"
    static let controlsRootName = "custom-cinema-native-controls"
    static let rewindButtonName = "custom-cinema-rewind-30-button"
    static let playPauseButtonName = "custom-cinema-play-pause-button"
    static let forwardButtonName = "custom-cinema-forward-30-button"
    static let exitButtonName = "custom-cinema-exit-button"
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
    var geometry: CustomCinemaGeometry = .default
    var presentationState: PresentationState = .closed
    var shouldReopenMainWindowOnDismiss = false

    var player: AVPlayer? { controller?.player }
    var hasActivePlayer: Bool { controller != nil }

    func activate(title: String, controller: PlaybackController, geometry: CustomCinemaGeometry = .default) {
        self.title = title
        self.controller = controller
        self.geometry = geometry
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
        geometry = .default
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
                                      geometry: session.geometry,
                                      controlsVisible: controlsVisible,
                                      isPaused: session.controller?.transport.isPaused ?? true))
        } update: { content in
            content.entities.removeAll(where: { $0.name == "custom-cinema-root" })
            content.add(Self.makeRoot(player: session.player,
                                      geometry: session.geometry,
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
            print("[Custom Cinema] black immersive opened: \(session.geometry.debugSummary); title=\(session.title ?? "none"); hasPlayer=\(session.hasActivePlayer)")
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
        controller.togglePlayback()
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
    private static func makeRoot(player: AVPlayer?, geometry: CustomCinemaGeometry, controlsVisible: Bool, isPaused: Bool) -> Entity {
        let root = Entity()
        root.name = "custom-cinema-root"

        let screen: ModelEntity
        if let player {
            let material = VideoMaterial(avPlayer: player)
            screen = ModelEntity(mesh: .generatePlane(width: geometry.screenWidthMeters,
                                                      height: geometry.screenHeightMeters),
                                 materials: [material])
            screen.name = CustomCinemaMode.videoPlaneName
        } else {
            screen = ModelEntity(mesh: .generatePlane(width: geometry.screenWidthMeters,
                                                      height: geometry.screenHeightMeters),
                                 materials: [SimpleMaterial(color: .black,
                                                            roughness: 1.0,
                                                            isMetallic: false)])
            screen.name = CustomCinemaMode.emptyPlaneName
        }
        screen.position = geometry.screenPosition
        // The visible screen is also the reveal target. Collision is intentionally attached to
        // this rendered plane instead of a separate transparent rectangle so taps cannot be
        // intercepted by an invisible occluder in front of the movie.
        screen.components.set(InputTargetComponent())
        screen.components.set(CollisionComponent(shapes: [
            .generateBox(width: geometry.screenWidthMeters,
                         height: geometry.screenHeightMeters,
                         depth: 0.04)
        ]))
        root.addChild(screen)

        if controlsVisible {
            root.addChild(makeControlsRail(isPaused: isPaused, geometry: geometry))
        }

        return root
    }

    private static func makeControlsRail(isPaused: Bool, geometry: CustomCinemaGeometry) -> Entity {
        let root = Entity()
        root.name = CustomCinemaMode.controlsRootName
        root.position = geometry.controlsPosition

        let back = ModelEntity(mesh: .generateBox(width: 1.72,
                                                  height: 0.30,
                                                  depth: 0.030,
                                                  cornerRadius: 0.15),
                               materials: [UnlitMaterial(color: UIColor(white: 0.04, alpha: 0.72))])
        back.name = "custom-cinema-controls-background"
        root.addChild(back)

        let rewind = makeButton(name: CustomCinemaMode.rewindButtonName,
                                label: "−30",
                                x: -0.54,
                                width: 0.30,
                                color: UIColor(white: 0.16, alpha: 0.88))
        root.addChild(rewind)

        let play = makeButton(name: CustomCinemaMode.playPauseButtonName,
                              label: isPaused ? "▶" : "Ⅱ",
                              x: -0.18,
                              width: 0.34,
                              color: UIColor(white: 0.22, alpha: 0.92),
                              fontSize: 0.070)
        root.addChild(play)

        let forward = makeButton(name: CustomCinemaMode.forwardButtonName,
                                 label: "+30",
                                 x: 0.18,
                                 width: 0.30,
                                 color: UIColor(white: 0.16, alpha: 0.88))
        root.addChild(forward)

        let exit = makeButton(name: CustomCinemaMode.exitButtonName,
                              label: "Exit",
                              x: 0.62,
                              width: 0.38,
                              color: UIColor(red: 0.38, green: 0.07, blue: 0.07, alpha: 0.84),
                              fontSize: 0.048)
        root.addChild(exit)

        return root
    }

    private static func makeButton(name: String, label: String, x: Float, width: Float, color: UIColor, fontSize: CGFloat = 0.056) -> Entity {
        let root = Entity()
        root.name = "\(name)-root"
        root.position = SIMD3<Float>(x, 0, 0.035)

        let height: Float = 0.20
        let depth: Float = 0.045
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
                                                 font: .systemFont(ofSize: fontSize, weight: .semibold),
                                                 containerFrame: CGRect(x: -CGFloat(width) / 2,
                                                                        y: -0.030,
                                                                        width: CGFloat(width),
                                                                        height: 0.08),
                                                 alignment: .center,
                                                 lineBreakMode: .byClipping)
        let text = ModelEntity(mesh: textMesh, materials: [UnlitMaterial(color: UIColor(white: 1, alpha: 0.92))])
        text.name = "\(name)-label"
        text.position = SIMD3<Float>(0, -0.024, 0.032)
        root.addChild(text)

        return root
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
