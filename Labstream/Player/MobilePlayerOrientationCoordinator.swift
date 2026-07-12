#if os(iOS)
import UIKit
import PMSKit

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
        guard let restoration = beginRestoration() else { return }
        request(restoration.mask, in: restoration.scene, context: "restore_on_disappear")
    }

    /// Explicit-close path for #241. Keep the full-screen player covering the browse UI until
    /// UIKit has had a chance to apply the restored geometry, rather than revealing Detail in
    /// landscape and hoping `.onDisappear` wins the race afterward.
    func restoreBeforeDismissal() async {
        guard let restoration = beginRestoration() else { return }
        request(restoration.mask, in: restoration.scene, context: "restore_before_dismissal")

        // `requestGeometryUpdate` has only an error callback, not a success completion. Poll the
        // scene briefly and yield even on timeout; the request remains active after dismissal.
        for _ in 0..<20 {
            if matches(restoration.mask,
                       orientation: restoration.scene.effectiveGeometry.interfaceOrientation) {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private var foregroundWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private func beginRestoration() -> (scene: UIWindowScene, mask: UIInterfaceOrientationMask)? {
        guard isActive else { return nil }
        isActive = false

        AppDelegate.supportedInterfaceOrientations = .allButUpsideDown
        let scene = activeScene ?? foregroundWindowScene
        let target = MobilePlayerOrientationRestorePolicy.target(after: policyOrientation(previousOrientation))
        activeScene = nil
        previousOrientation = nil

        guard let scene else { return nil }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        return (scene, orientationMask(for: target))
    }

    private func policyOrientation(_ orientation: UIInterfaceOrientation?) -> MobilePlayerOrientationRestorePolicy.Orientation {
        switch orientation {
        case .portrait, .portraitUpsideDown: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .unknown, nil: .unknown
        @unknown default: .unknown
        }
    }

    private func orientationMask(for orientation: MobilePlayerOrientationRestorePolicy.Orientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait, .unknown: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }

    private func matches(_ mask: UIInterfaceOrientationMask,
                         orientation: UIInterfaceOrientation) -> Bool {
        switch orientation {
        case .portrait: mask == .portrait
        case .landscapeLeft: mask == .landscapeLeft
        case .landscapeRight: mask == .landscapeRight
        case .portraitUpsideDown, .unknown: false
        @unknown default: false
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
