#if os(iOS)
import UIKit

/// Applies a player-only landscape policy on iPhone without constraining iPad or the
/// rest of the mobile app. The previous scene orientation is restored when playback
/// closes, then UIKit returns to the app's ordinary portrait/landscape policy.
@MainActor
final class MobilePlayerOrientationCoordinator {
    private var previousOrientation: UIInterfaceOrientation?
    private var activeScene: UIWindowScene?
    private var isActive = false

    func enterLandscapeIfNeeded() {
        guard UIDevice.current.userInterfaceIdiom == .phone, !isActive else { return }
        guard let scene = foregroundWindowScene else { return }

        isActive = true
        activeScene = scene
        previousOrientation = scene.effectiveGeometry.interfaceOrientation
        AppDelegate.supportedInterfaceOrientations = .landscape
        request(.landscape, in: scene, context: "enter")
    }

    func restoreIfNeeded() {
        guard isActive else { return }
        isActive = false

        AppDelegate.supportedInterfaceOrientations = .allButUpsideDown
        let scene = activeScene ?? foregroundWindowScene
        let previousMask = orientationMask(for: previousOrientation)
        activeScene = nil
        previousOrientation = nil

        guard let scene, let previousMask else { return }
        request(previousMask, in: scene, context: "restore")
    }

    private var foregroundWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private func orientationMask(for orientation: UIInterfaceOrientation?) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .unknown, nil: nil
        @unknown default: nil
        }
    }

    private func request(_ mask: UIInterfaceOrientationMask,
                         in scene: UIWindowScene,
                         context: String) {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            AppDiagnostics.record(.playback, "player.orientation_request_failed", fields: [
                "context": .label(context),
                "error": .text(error.localizedDescription),
            ])
        }
    }
}
#endif
