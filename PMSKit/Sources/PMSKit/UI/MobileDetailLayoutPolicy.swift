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

    /// The composition once the viewport is measured, or `nil` before the first measurement.
    /// iPhone/iPad draw nothing until this resolves so the page never flashes a size-class
    /// fallback composition for a frame (iPhone Duo design spec, Movie detail, "First frame").
    public static func resolvedMode(viewportWidth: Double,
                                    viewportHeight: Double,
                                    horizontallyCompact: Bool) -> Mode? {
        guard sanitized(viewportWidth) > 0, sanitized(viewportHeight) > 0 else { return nil }
        return mode(viewportWidth: viewportWidth, viewportHeight: viewportHeight,
                    horizontallyCompact: horizontallyCompact)
    }

    /// Height of the phone composition's full-width 16:9 key art: the 16:9 height of the
    /// content region, capped at `artworkMaximumHeightFraction` of the viewport height so the
    /// title and the action row stay on the first screen in folded landscape. The art is a
    /// background layer that spans the full width and crops to this height, so it never needs
    /// a width floor. `nil` when unmeasured.
    public static func artworkHeight(viewportWidth: Double, viewportHeight: Double,
                                     aspectRatio: Double = 16.0 / 9.0) -> Double? {
        let width = sanitized(viewportWidth)
        guard width > 0, aspectRatio > 0,
              let cap = artworkMaximumHeight(viewportHeight: viewportHeight) else { return nil }
        return min(width / aspectRatio, cap)
    }

    /// Height of the stacked composition's key-art hero band (unfolded upright).
    public static let stackedHeroHeight: Double = 220

    /// Horizontal placement of the side-by-side poster and metadata column, in the content
    /// region's horizontal space (0 = its leading edge).
    public struct SideBySidePlacement: Equatable, Sendable {
        /// Leading edge of the poster.
        public let posterLeading: Double
        /// Leading edge of the metadata column; the column runs to one margin before the
        /// region's trailing edge.
        public let metadataLeading: Double
        /// The poster sits centred in the leading half of a book hinge.
        public let followsHinge: Bool
    }

    /// Flat: the poster at the leading margin and the metadata after it. Book: the poster
    /// centres in the half before the hinge and the metadata starts one margin after it, so the
    /// gap sits on the fold. A hinge that leaves no room for the poster is ignored.
    ///
    /// - Parameters:
    ///   - hinge: a book hinge as (minX, maxX) in the content region's horizontal space.
    public static func sideBySidePlacement(contentWidth: Double,
                                           posterWidth: Double,
                                           margin: Double,
                                           gap: Double,
                                           hinge: (minX: Double, maxX: Double)? = nil) -> SideBySidePlacement {
        let width = max(sanitized(contentWidth), 0)
        let poster = max(sanitized(posterWidth), 0)
        let m = max(sanitized(margin), 0)
        let g = max(sanitized(gap), 0)
        if let hinge {
            let lo = min(sanitized(hinge.minX), sanitized(hinge.maxX))
            let hi = max(sanitized(hinge.minX), sanitized(hinge.maxX))
            let roomBeforeHinge = lo - m
            if lo > 0, hi < width, roomBeforeHinge >= poster + m {
                let leading = m + (roomBeforeHinge - poster) / 2
                return SideBySidePlacement(posterLeading: leading, metadataLeading: hi + m,
                                           followsHinge: true)
            }
        }
        return SideBySidePlacement(posterLeading: m, metadataLeading: m + poster + g,
                                   followsHinge: false)
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
