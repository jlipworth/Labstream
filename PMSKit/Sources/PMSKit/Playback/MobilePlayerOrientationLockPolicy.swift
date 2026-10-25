import Foundation

/// Size class of the display the full-screen iOS player is hosted on, from measured scene
/// geometry rather than the device idiom.
///
/// A foldable iPhone moves one scene between a phone-sized outer display (466×678 pt) and a much
/// larger inner display (669×951 pt) in the middle of a session, so "is this an iPhone" no longer
/// answers "should the player force landscape". The short side of the hosting scene does.
public enum MobilePlayerDisplayClass: String, Equatable, Sendable {
    /// Short side below `MobilePlayerOrientationLockPolicy.phoneShortSideLimit`: every iPhone in
    /// either orientation and the folded iPhone Duo.
    case phone
    /// Anything larger: iPad and the unfolded iPhone Duo inner display.
    case large
}

/// Decides whether the iOS player locks its scene to landscape, from measured scene geometry.
///
/// The lock is a phone affordance: a 16:9 picture in a portrait phone viewport would use about a
/// third of the screen. It is only applied when the scene fills its screen, so a small resizable
/// iPad window (which is also phone-sized but cannot be rotated on its own) never asks for it, and
/// it is withdrawn whenever the scene stops being phone-class, for example when an iPhone Duo is
/// unfolded during playback. A scene that declined the request for the current display class is
/// not asked again until that class changes.
public enum MobilePlayerOrientationLockPolicy {
    /// Same cap the player chrome uses for phone-landscape geometry.
    public static let phoneShortSideLimit: Double = 500
    /// Tolerance when comparing the scene against its screen, in points.
    static let fillsScreenTolerance: Double = 1

    public enum Decision: String, Equatable, Sendable {
        /// Restrict the scene to landscape and request it.
        case lockLandscape
        /// Withdraw an active lock: widen the supported mask without forcing a rotation.
        case release
        /// Keep the current state.
        case none
    }

    /// The display class for a measured scene, or nil before UIKit has reported a size.
    public static func displayClass(sceneWidth: Double, sceneHeight: Double) -> MobilePlayerDisplayClass? {
        guard sceneWidth.isFinite, sceneHeight.isFinite, sceneWidth > 0, sceneHeight > 0 else { return nil }
        return min(sceneWidth, sceneHeight) < phoneShortSideLimit ? .phone : .large
    }

    /// Whether the scene occupies its whole screen, independent of orientation.
    public static func fillsScreen(sceneWidth: Double, sceneHeight: Double,
                                   screenWidth: Double, screenHeight: Double) -> Bool {
        guard sceneWidth > 0, sceneHeight > 0, screenWidth > 0, screenHeight > 0 else { return false }
        let scene = (min(sceneWidth, sceneHeight), max(sceneWidth, sceneHeight))
        let screen = (min(screenWidth, screenHeight), max(screenWidth, screenHeight))
        return abs(scene.0 - screen.0) <= fillsScreenTolerance
            && abs(scene.1 - screen.1) <= fillsScreenTolerance
    }

    /// - Parameters:
    ///   - displayClass: The current class of the hosting scene; nil while unmeasured.
    ///   - fillsScreen: Whether the hosting scene covers its whole screen.
    ///   - isLocked: Whether this player session currently holds the landscape lock.
    ///   - declinedClass: The display class for which the scene last refused a landscape request.
    public static func decision(displayClass: MobilePlayerDisplayClass?,
                                fillsScreen: Bool,
                                isLocked: Bool,
                                declinedClass: MobilePlayerDisplayClass?) -> Decision {
        guard let displayClass else { return .none }
        let wantsLock = displayClass == .phone && fillsScreen && declinedClass != displayClass
        switch (wantsLock, isLocked) {
        case (true, false): return .lockLandscape
        case (false, true): return .release
        default: return .none
        }
    }
}
