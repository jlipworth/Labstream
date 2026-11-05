import Foundation

/// Show → season composition on iPhone/iPad (iPhone Duo design spec, Show detail, seasons and
/// episodes).
///
/// The hierarchy is the same in every pose: show → season → episode. Where the content region is
/// a wide, regular-width landscape area (the unfolded-sideways inner display), the inner display
/// shows one extra level: the show page as the leading list column and the selected season's
/// episodes as the trailing detail column, split about 50/50 so that in book the divider lies on
/// the hinge (Mail). Everywhere else the season is pushed. This is the same split rule as the
/// Music album reflow, so both surfaces flip at the same width. Measured geometry only: never
/// the pose name, the idiom or the screen.
public enum ShowDetailLayoutPolicy {
    public enum Layout: Equatable, Sendable {
        /// The show page alone; selecting a season pushes it.
        case single
        /// `listWidth` is the show column's width; `detailStart` is where the season column
        /// begins (both from the content region's leading edge).
        case split(listWidth: Double, detailStart: Double)
    }

    /// - Parameters:
    ///   - width, height: the content region (safe area already removed).
    ///   - regularWidth: the horizontal size class is regular.
    ///   - hinge: a book hinge as (minX, maxX) in the content region's horizontal space.
    public static func layout(width: Double, height: Double, regularWidth: Bool,
                              hinge: (minX: Double, maxX: Double)? = nil) -> Layout {
        switch MusicDetailLayoutPolicy.layout(width: width, height: height,
                                              regularWidth: regularWidth, hinge: hinge) {
        case .stacked:
            return .single
        case .columns(let leadingWidth, let trailingStart):
            return .split(listWidth: leadingWidth, detailStart: trailingStart)
        }
    }
}
