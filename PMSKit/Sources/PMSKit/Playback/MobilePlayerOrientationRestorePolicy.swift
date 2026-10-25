/// Pure policy for the orientation a landscape-locked iOS player restores on exit.
public enum MobilePlayerOrientationRestorePolicy {
    public enum Orientation: Equatable, Sendable {
        case portrait
        case landscapeLeft
        case landscapeRight
        case unknown
    }

    public enum Action: Equatable, Sendable {
        /// The session never forced a rotation: nothing to restore.
        case none
        /// Widen the supported mask only. The display class changed since the player opened (an
        /// iPhone Duo folded or unfolded during playback), so the orientation captured at entry
        /// describes a different display and requesting it would force a needless rotation.
        case widenMaskOnly
        /// Widen the mask and request this orientation.
        case request(Orientation)
    }

    /// Portrait is the safe fallback when UIKit failed to report the presenting geometry.
    /// A player genuinely launched from landscape returns to that same landscape side.
    public static func target(after previous: Orientation) -> Orientation {
        switch previous {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portrait, .unknown: return .portrait
        }
    }

    /// - Parameters:
    ///   - previous: Scene orientation captured when the player session began.
    ///   - didLock: Whether the session ever applied the landscape lock.
    ///   - entryClass: Display class when the session began.
    ///   - currentClass: Display class at close.
    public static func action(previous: Orientation,
                              didLock: Bool,
                              entryClass: MobilePlayerDisplayClass?,
                              currentClass: MobilePlayerDisplayClass?) -> Action {
        guard didLock else { return .none }
        if let entryClass, let currentClass, entryClass != currentClass {
            return .widenMaskOnly
        }
        return .request(target(after: previous))
    }
}
