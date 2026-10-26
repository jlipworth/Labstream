import Foundation

/// Album and playlist detail composition on iPhone/iPad (iPhone Duo design spec, Music).
///
/// The page stacks (art, title block, actions, then tracks) until the content region is a wide,
/// regular-width landscape area such as the unfolded-sideways inner display, where it reflows
/// into two columns: art, title, actions and description leading; the track list trailing.
/// Columns split the content region about 50/50; in book the split follows the hinge so the
/// column gap sits on the fold (Mail's list/message split behaviour). Measured geometry only:
/// never the pose name, the idiom or the screen.
public enum MusicDetailLayoutPolicy {
    public enum Layout: Equatable, Sendable {
        case stacked
        /// `leadingWidth` is the leading column's width; `trailingStart` is where the trailing
        /// column begins, both in the content region's horizontal space (0 = its leading edge).
        case columns(leadingWidth: Double, trailingStart: Double)
    }

    /// Narrowest content region that reflows into columns.
    public static let minimumColumnsWidth = 700.0

    /// - Parameters:
    ///   - width, height: the content region (safe area already removed).
    ///   - regularWidth: the horizontal size class is regular.
    ///   - hinge: a book hinge as (minX, maxX) in the content region's horizontal space.
    public static func layout(width: Double, height: Double, regularWidth: Bool,
                              hinge: (minX: Double, maxX: Double)? = nil) -> Layout {
        guard width.isFinite, height.isFinite, regularWidth,
              width >= minimumColumnsWidth, width > height else { return .stacked }
        if let hinge {
            let lo = min(hinge.minX, hinge.maxX)
            let hi = max(hinge.minX, hinge.maxX)
            // Each column needs a usable share; otherwise ignore the hinge and split evenly.
            if lo >= width * 0.3, hi <= width * 0.7 {
                return .columns(leadingWidth: lo, trailingStart: hi)
            }
        }
        let half = width / 2
        return .columns(leadingWidth: half, trailingStart: half)
    }
}
