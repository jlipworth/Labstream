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

    static let controlsAttachmentID = "custom-cinema-controls-rail"
    static let controlsWidthPoints: CGFloat = 520
    static let controlsPhysicalWidthMeters: Float = 1.85
    static var controlsScale: Float { controlsPhysicalWidthMeters / Float(controlsWidthPoints) }
    static var controlsPosition: SIMD3<Float> {
        SIMD3<Float>(0, verticalOffsetMeters - (screenHeightMeters / 2.0) - 0.38, -screenDistanceMeters + 0.08)
    }
}

/// Marker component for the visible video plane so a targeted spatial tap can reveal controls.
///
/// The gesture target is the VideoMaterial plane itself, not a transparent overlay in front of
/// playback. That keeps the reveal affordance from reintroducing the black-screen/occlusion risk
/// seen during earlier invisible-plane experiments.
private struct CustomCinemaRevealTargetComponent: Component {}

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
/// the active `AVPlayer` as a RealityKit `VideoMaterial` plane, then reveals a small SwiftUI
/// attachment rail only after a targeted tap on that visible plane. The rail is not a window
/// lifecycle restore hack; it stays inside the immersive space and owns deliberate playback exit.
struct CustomCinemaScaffoldView: View {
    @Environment(CustomCinemaSessionStore.self) private var session
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var controlsVisible = false
    @State private var controlsHideTask: Task<Void, Never>?

    var body: some View {
        RealityView { content, attachments in
            content.add(Self.makeRoot(player: session.player))
            updateControlsAttachment(in: content, attachments: attachments)
        } update: { content, attachments in
            content.entities.removeAll(where: { $0.name == "custom-cinema-root" })
            content.add(Self.makeRoot(player: session.player))
            updateControlsAttachment(in: content, attachments: attachments)
        } attachments: {
            Attachment(id: CustomCinemaMode.controlsAttachmentID) {
                CustomCinemaControlsRail(title: session.title ?? "Cinema",
                                         controller: session.controller,
                                         onTogglePlayback: togglePlayback,
                                         onExit: exitCinema)
            }
        }
        .gesture(SpatialTapGesture()
            .targetedToEntity(where: .has(CustomCinemaRevealTargetComponent.self))
            .onEnded { _ in revealControls() })
        .preferredSurroundingsEffect(.ultraDark)
        .onAppear {
            print("[Custom Cinema] black immersive opened: width \(CustomCinemaMode.screenWidthMeters)m · distance \(CustomCinemaMode.screenDistanceMeters)m · vertical \(CustomCinemaMode.verticalOffsetMeters)m; title=\(session.title ?? "none"); hasPlayer=\(session.hasActivePlayer)")
            session.presentationState = .open
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

    private func revealControls() {
        guard session.hasActivePlayer else { return }
        controlsVisible = true
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func togglePlayback() {
        guard let controller = session.controller else { return }
        if controller.transport.isPaused {
            controller.player.play()
        } else {
            controller.player.pause()
        }
        revealControls()
    }

    private func exitCinema() {
        controlsHideTask?.cancel()
        controlsVisible = false
        session.stopAndClearForImmersiveExit()
        Task { @MainActor in
            await dismissImmersiveSpace()
            session.clear()
        }
    }

    private func updateControlsAttachment(in content: RealityViewContent,
                                          attachments: RealityViewAttachments) {
        guard let controls = attachments.entity(for: CustomCinemaMode.controlsAttachmentID) else { return }
        guard controlsVisible, session.hasActivePlayer else {
            controls.removeFromParent()
            return
        }
        controls.name = CustomCinemaMode.controlsAttachmentID
        controls.position = CustomCinemaMode.controlsPosition
        controls.scale = SIMD3<Float>(repeating: CustomCinemaMode.controlsScale)
        if controls.parent == nil {
            content.add(controls)
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
        // The visible screen is also the reveal target. Collision is intentionally attached to
        // this rendered plane instead of a separate transparent rectangle so taps cannot be
        // intercepted by an invisible occluder in front of the movie.
        screen.components.set(InputTargetComponent())
        screen.components.set(CollisionComponent(shapes: [
            .generateBox(width: CustomCinemaMode.screenWidthMeters,
                         height: CustomCinemaMode.screenHeightMeters,
                         depth: 0.04)
        ]))
        screen.components.set(CustomCinemaRevealTargetComponent())
        root.addChild(screen)
        return root
    }
}

private struct CustomCinemaControlsRail: View {
    let title: String
    let controller: PlaybackController?
    let onTogglePlayback: () -> Void
    let onExit: () -> Void

    private var isPaused: Bool { controller?.transport.isPaused ?? true }

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)

            Button(action: onTogglePlayback) {
                Label(isPaused ? "Play" : "Pause",
                      systemImage: isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 92)
            }
            .buttonStyle(.bordered)
            .disabled(controller == nil)

            Button(role: .destructive, action: onExit) {
                Label("Exit Cinema", systemImage: "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 132)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller == nil)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: CustomCinemaMode.controlsWidthPoints)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(radius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cinema controls")
    }
}
