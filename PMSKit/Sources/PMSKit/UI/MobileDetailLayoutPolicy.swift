import Foundation

/// Chooses the iPhone/iPad detail-page composition from the space the page actually has.
///
/// The decision used to combine the device idiom with the horizontal size class, which treats
/// every iPhone viewport alike and every iPad viewport alike. A foldable iPhone breaks that: its
/// folded outer display is phone-sized, while its inner display (about 669×951 pt) reports
/// regular width but is far too narrow for the side-by-side poster + metadata layout authored
/// for a full iPad. Measured viewport geometry answers the real question for every device.
public enum MobileDetailLayoutPolicy {
    public enum Mode: Equatable, Sendable {
        /// Narrow, vertically scrolling hierarchy with full-width 16:9 key art.
        case phone
        /// Regular poster stacked above the metadata column.
        case stacked
        /// Poster beside a readable-measure metadata column.
        case sideBySide
    }

    /// Below this short side a viewport is phone-class: iPhone portrait and landscape, the
    /// folded iPhone Duo, and narrow iPad Slide Over/Split View panes.
    public static let phoneShortSideLimit: Double = 500
    /// Below this width a regular poster plus a readable metadata column do not fit side by side.
    public static let sideBySideMinimumWidth: Double = 700
    /// Largest share of the viewport height the compact key art may occupy, so the title and
    /// actions stay above the fold on short (landscape) viewports.
    public static let artworkMaximumHeightFraction: Double = 0.4

    /// - Parameters:
    ///   - viewportWidth: Measured width of the detail scroll container, in points.
    ///   - viewportHeight: Measured height of the detail scroll container, in points.
    ///   - horizontallyCompact: Whether the environment reports a compact horizontal size class.
    ///     Used before the first measurement arrives and to keep regular-width iPhone landscape
    ///     (which has room for the side-by-side layout) out of the phone composition.
    public static func mode(viewportWidth: Double,
                            viewportHeight: Double,
                            horizontallyCompact: Bool) -> Mode {
        let width = sanitized(viewportWidth)
        let height = sanitized(viewportHeight)
        guard width > 0, height > 0 else {
            return horizontallyCompact ? .phone : .sideBySide
        }
        if width < phoneShortSideLimit { return .phone }
        if horizontallyCompact, min(width, height) < phoneShortSideLimit { return .phone }
        if width < sideBySideMinimumWidth { return .stacked }
        return .sideBySide
    }

    /// Smallest share of the viewport width the capped compact key art keeps. Without this floor
    /// the height cap shrinks the art to a thumbnail on wide-and-short phone viewports (a slab
    /// iPhone in landscape, ~874x300 pt of scroll viewport, would get ~215 pt of art).
    public static let artworkMinimumWidthFraction: Double = 0.5

    /// Width bound for the compact 16:9 key art: the width that honors the height cap, but never
    /// less than `artworkMinimumWidthFraction` of the viewport width. `nil` when unmeasured.
    public static func artworkMaximumWidth(viewportWidth: Double, viewportHeight: Double,
                                           aspectRatio: Double = 16.0 / 9.0) -> Double? {
        let width = sanitized(viewportWidth)
        guard width > 0, let height = artworkMaximumHeight(viewportHeight: viewportHeight) else { return nil }
        return max(height * aspectRatio, width * artworkMinimumWidthFraction)
    }

    /// Height cap for the compact 16:9 key art; `nil` when the viewport is not yet measured.
    public static func artworkMaximumHeight(viewportHeight: Double) -> Double? {
        let height = sanitized(viewportHeight)
        guard height > 0 else { return nil }
        return height * artworkMaximumHeightFraction
    }

    /// Side length for a square or poster-width hero that must fit the measured viewport.
    /// Returns `preferred` unchanged when the viewport is unmeasured or already large enough,
    /// so authored iPhone/iPad sizes stay as they are and only cramped viewports shrink.
    public static func heroSide(preferred: Double,
                                viewportWidth: Double,
                                viewportHeight: Double,
                                horizontalPadding: Double,
                                maximumHeightFraction: Double = 0.45,
                                minimum: Double = 120) -> Double {
        let preferred = max(sanitized(preferred), 0)
        let width = sanitized(viewportWidth)
        let height = sanitized(viewportHeight)
        guard width > 0, height > 0 else { return preferred }
        let widthBound = width - 2 * max(sanitized(horizontalPadding), 0)
        let heightBound = height * min(max(sanitized(maximumHeightFraction), 0), 1)
        let bounded = min(preferred, widthBound, heightBound)
        return max(min(bounded, preferred), min(minimum, preferred))
    }

    private static func sanitized(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
