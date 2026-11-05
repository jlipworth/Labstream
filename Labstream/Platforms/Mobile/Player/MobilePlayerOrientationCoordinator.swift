import UIKit
import PMSKit

/// Applies a player-only landscape lock while the hosting scene is phone-class, without
/// constraining larger displays or the rest of the mobile app.
///
/// The lock is decided from measured scene geometry (`MobilePlayerOrientationLockPolicy`), never
/// from the device idiom, and is re-evaluated whenever the player's scene geometry changes. That
/// is what lets one session cross an iPhone Duo fold: unfolding releases the lock (the mask widens,
/// no rotation is forced), folding back re-applies it. The scene orientation captured at entry is
/// restored when playback closes, unless the display class changed in between, in which case only
/// the mask is widened.
@MainActor
final class MobilePlayerOrientationCoordinator {
    private struct Session {
        weak var scene: UIWindowScene?
        let previousOrientation: UIInterfaceOrientation
        let entryClass: MobilePlayerDisplayClass?
        var isLocked = false
        var didLock = false
        var declinedClass: MobilePlayerDisplayClass?
    }

    private var session: Session?

    /// Begin a player session. Called by the presenter before presentation (preflight) and by the
    /// player on appear; the second call is a no-op.
    func enterLandscapeIfNeeded() {
        guard session == nil, let scene = foregroundWindowScene else { return }
        session = Session(scene: scene,
                          previousOrientation: scene.effectiveGeometry.interfaceOrientation,
                          entryClass: displayClass(of: scene))
        apply(context: "enter")
    }

    /// Preflight used by the presenting detail view. Rotate the scene while Detail is still the
    /// visible surface so the full-screen player is introduced once, already in landscape,
    /// instead of presenting a portrait player and rotating it a frame later. Returns at once
    /// when no rotation is pending (large displays, or a scene that is already landscape).
    func enterLandscapeBeforePresentationIfNeeded() async {
        enterLandscapeIfNeeded()
        guard let session, session.isLocked, let scene = session.scene else { return }
        for _ in 0..<20 {
            guard self.session?.isLocked == true else { return }
            if scene.effectiveGeometry.interfaceOrientation.isLandscape { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The player's own window reported its scene or a geometry change (size, size class, or
    /// display). Rebinds the session to that scene and re-evaluates the lock. Returns the decision
    /// for diagnostics, or nil when no session is active.
    @discardableResult
    func playerSceneGeometryDidChange(_ scene: UIWindowScene) -> MobilePlayerOrientationLockPolicy.Decision? {
        guard session != nil else { return nil }
        if session?.scene !== scene {
            session?.scene = scene
        }
        return apply(context: "geometry")
    }

    /// Current display class of a scene, for diagnostics.
    func displayClass(of scene: UIWindowScene) -> MobilePlayerDisplayClass? {
        let size = scene.effectiveGeometry.coordinateSpace.bounds.size
        return MobilePlayerOrientationLockPolicy.displayClass(sceneWidth: Double(size.width),
                                                              sceneHeight: Double(size.height))
    }

    func restoreIfNeeded() {
        guard let restoration = beginRestoration() else { return }
        request(restoration.mask, in: restoration.scene, context: "restore_on_disappear")
    }

    /// Explicit-close path for #241. Keep the full-screen player covering the browse UI until
    /// UIKit has had a chance to apply the restored geometry, rather than revealing Detail in
    /// landscape and hoping `.onDisappear` wins the race afterward. Returns at once when no
    /// rotation is requested.
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

    // MARK: - Lock evaluation

    @discardableResult
    private func apply(context: String) -> MobilePlayerOrientationLockPolicy.Decision {
        guard var current = session, let scene = current.scene else { return .none }
        let sceneSize = scene.effectiveGeometry.coordinateSpace.bounds.size
        let screenSize = scene.screen.bounds.size
        let displayClass = MobilePlayerOrientationLockPolicy.displayClass(sceneWidth: Double(sceneSize.width),
                                                                          sceneHeight: Double(sceneSize.height))
        let fillsScreen = MobilePlayerOrientationLockPolicy.fillsScreen(sceneWidth: Double(sceneSize.width),
                                                                        sceneHeight: Double(sceneSize.height),
                                                                        screenWidth: Double(screenSize.width),
                                                                        screenHeight: Double(screenSize.height))
        // A decline only holds for the class that refused; a fold/unfold asks again.
        current.declinedClass = MobilePlayerOrientationLockPolicy.retainedDeclinedClass(current.declinedClass,
                                                                                        displayClass: displayClass)
        session = current
        let decision = MobilePlayerOrientationLockPolicy.decision(displayClass: displayClass,
                                                                  fillsScreen: fillsScreen,
                                                                  isLocked: current.isLocked,
                                                                  declinedClass: current.declinedClass)
        switch decision {
        case .lockLandscape:
            current.isLocked = true
            current.didLock = true
            session = current
            AppDelegate.supportedInterfaceOrientations = .landscape
            updateSupportedOrientations(in: scene)
            request(.landscape, in: scene, context: context, declinedClass: displayClass)
        case .release:
            current.isLocked = false
            session = current
            AppDelegate.supportedInterfaceOrientations = .allButUpsideDown
            updateSupportedOrientations(in: scene)
        case .none:
            break
        }
        if decision != .none {
            AppDiagnostics.record(.playback, "player.orientation_lock", fields: [
                "context": .label(context),
                "decision": .label(decision.rawValue),
                "display_class": .label(displayClass?.rawValue ?? "unmeasured"),
                "fills_screen": .bool(fillsScreen),
            ])
        }
        return decision
    }

    private func lockRequestDeclined(for displayClass: MobilePlayerDisplayClass?) {
        guard var current = session, current.isLocked else { return }
        // A spurious or transient error while the scene is already landscape is not a decline:
        // keep the lock rather than leaving the rest of the session unlocked.
        if current.scene?.effectiveGeometry.interfaceOrientation.isLandscape == true { return }
        // The scene will not rotate for this display class. Do not keep a landscape-only mask
        // on a portrait scene; the policy will not ask again until the class changes.
        current.isLocked = false
        current.declinedClass = displayClass
        session = current
        AppDelegate.supportedInterfaceOrientations = .allButUpsideDown
        if let scene = current.scene { updateSupportedOrientations(in: scene) }
    }

    private var foregroundWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private func beginRestoration() -> (scene: UIWindowScene, mask: UIInterfaceOrientationMask)? {
        guard let ended = session else { return nil }
        session = nil

        let scene = ended.scene ?? foregroundWindowScene
        let action = MobilePlayerOrientationRestorePolicy.action(
            previous: policyOrientation(ended.previousOrientation),
            didLock: ended.didLock,
            entryClass: ended.entryClass,
            currentClass: scene.flatMap(displayClass(of:)))
        guard action != .none else { return nil }

        AppDelegate.supportedInterfaceOrientations = .allButUpsideDown
        guard let scene else { return nil }
        updateSupportedOrientations(in: scene)
        guard case .request(let target) = action else {
            AppDiagnostics.record(.playback, "player.orientation_lock", fields: [
                "context": .label("restore"),
                "decision": .label("widen_mask_only"),
                "display_class": .label(displayClass(of: scene)?.rawValue ?? "unmeasured"),
            ])
            return nil
        }
        return (scene, orientationMask(for: target))
    }

    private func updateSupportedOrientations(in scene: UIWindowScene) {
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
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
                         context: String,
                         declinedClass: MobilePlayerDisplayClass? = nil) {
        let isLockRequest = mask == .landscape
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            let summary = error.localizedDescription
            Task { @MainActor [weak self] in
                AppDiagnostics.record(.playback, "player.orientation_request_failed", fields: [
                    "context": .label(context),
                    "error": .text(summary),
                ])
                if isLockRequest {
                    self?.lockRequestDeclined(for: declinedClass)
                }
            }
        }
    }
}
