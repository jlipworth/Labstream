/// Pure policy for the iPhone orientation a landscape-only player restores on exit.
public enum MobilePlayerOrientationRestorePolicy {
    public enum Orientation: Equatable, Sendable {
        case portrait
        case landscapeLeft
        case landscapeRight
        case unknown
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
}
