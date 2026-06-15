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
    /// This deliberately starts as a minimal video plane + tiny exit/play control. The previous
    /// iterations failed because they presented a second SwiftUI/window-like video surface or
    /// tried to reuse the full chrome before the video renderer itself was proven clean.
    static let isUserVisible = true

    static let controlsAttachmentID = "custom-cinema-minimal-controls"
    static let emergencyExitAttachmentID = "custom-cinema-emergency-exit"
    static let screenWidthMeters: Float = 9.4
    static let screenDistanceMeters: Float = 6.25
    static let verticalOffsetMeters: Float = 2.25
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
/// the active `AVPlayer` as a RealityKit `VideoMaterial` plane and exposes only tiny exit/play
/// controls until the video surface is proven stable on-device.
struct CustomCinemaScaffoldView: View {
    @Environment(CustomCinemaSessionStore.self) private var session
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RealityView { content, attachments in
            content.add(Self.makeRoot(player: session.player))
            if let controls = attachments.entity(for: CustomCinemaMode.controlsAttachmentID) {
                placeControls(controls)
                content.add(controls)
            }
            if let exit = attachments.entity(for: CustomCinemaMode.emergencyExitAttachmentID) {
                placeEmergencyExit(exit)
                content.add(exit)
            }
        } update: { content, attachments in
            content.entities.removeAll(where: { $0.name == "custom-cinema-root" })
            content.add(Self.makeRoot(player: session.player))
            if let controls = attachments.entity(for: CustomCinemaMode.controlsAttachmentID) {
                placeControls(controls)
                if controls.parent == nil {
                    content.add(controls)
                }
            }
            if let exit = attachments.entity(for: CustomCinemaMode.emergencyExitAttachmentID) {
                placeEmergencyExit(exit)
                if exit.parent == nil {
                    content.add(exit)
                }
            }
        } attachments: {
            Attachment(id: CustomCinemaMode.controlsAttachmentID) {
                if let controller = session.controller {
                    minimalControls(controller: controller)
                } else {
                    inactiveState
                }
            }
            Attachment(id: CustomCinemaMode.emergencyExitAttachmentID) {
                emergencyExitButton
            }
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

    private func placeControls(_ entity: Entity) {
        entity.name = "custom-cinema-controls"
        // Attach controls to the visible video surface instead of floating below the user's gaze.
        // Put this one near top-center and make it large/high-contrast; earlier small attachments
        // were not visible enough on device.
        entity.position = CustomCinemaMode.screenPosition + SIMD3<Float>(0,
                                                                         (CustomCinemaMode.screenHeightMeters / 2.0) - 0.72,
                                                                         0.55)
        entity.scale = SIMD3<Float>(repeating: 0.0052)
    }

    private func placeEmergencyExit(_ entity: Entity) {
        entity.name = "custom-cinema-emergency-exit"
        // A second large exit sits on the lower center of the screen plane, not down near the user.
        entity.position = CustomCinemaMode.screenPosition + SIMD3<Float>(0,
                                                                         -(CustomCinemaMode.screenHeightMeters / 2.0) + 0.82,
                                                                         0.58)
        entity.scale = SIMD3<Float>(repeating: 0.0060)
    }

    private func minimalControls(controller: PlaybackController) -> some View {
        HStack(spacing: 22) {
            Button {
                if controller.transport.isPaused {
                    controller.player.play()
                } else {
                    controller.player.pause()
                }
            } label: {
                Label(controller.transport.isPaused ? "Play" : "Pause",
                      systemImage: controller.transport.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderedProminent)

            exitCinemaButton(label: "EXIT CINEMA", prominent: true)
        }
        .font(.largeTitle.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 42)
        .padding(.vertical, 28)
        .background(.red.opacity(0.72), in: Capsule())
    }

    private var emergencyExitButton: some View {
        exitCinemaButton(label: "EXIT CINEMA", prominent: true)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 42)
            .padding(.vertical, 28)
            .background(.red.opacity(0.92), in: Capsule())
    }

    @ViewBuilder
    private func exitCinemaButton(label: String, prominent: Bool) -> some View {
        if prominent {
            Button {
                Task { @MainActor in
                    session.presentationState = .inTransition
                    reopenMainWindowIfNeeded()
                    session.controller?.stop()
                    await dismissImmersiveSpace()
                    session.clear()
                }
            } label: {
                Label(label, systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                Task { @MainActor in
                    session.presentationState = .inTransition
                    reopenMainWindowIfNeeded()
                    session.controller?.stop()
                    await dismissImmersiveSpace()
                    session.clear()
                }
            } label: {
                Label(label, systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.bordered)
        }
    }


    private func reopenMainWindowIfNeeded() {
        guard session.shouldRestoreMainWindowOnDismiss else { return }
        session.shouldRestoreMainWindowOnDismiss = false
        openWindow(id: CustomCinemaMode.mainWindowID)
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
                    reopenMainWindowIfNeeded()
                    await dismissImmersiveSpace()
                    session.clear()
                }
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
        }
        .frame(width: 760, height: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
