import Foundation

/// Pure derivation of the LazyVGrid track math behind the Libraries section grid (#124).
///
/// The Libraries menu lays rigid `LibrarySectionCard`s (a fixed 300pt frame) into a single
/// `GridItem(.adaptive(minimum:maximum:spacing:))` column. SwiftUI's `.adaptive` strategy
/// computes how many tracks of width in `[minTrack, maxTrack]` fit the container (accounting
/// for `spacing`), then shares the width across them. When the cell is a fixed width but the
/// computed track lands narrower than the cell — which happens on a transiently-narrow first
/// layout pass — the cards overflow their tracks and render edge-to-edge, the "bunched with no
/// spacing" symptom reported on device. Pinning the adaptive minimum to the card width removes
/// that degenerate case: the grid can never compute a track narrower than the card.
///
/// This mirrors `.adaptive`'s integer track math so the spacing-collapse condition is a pure,
/// unit-testable invariant (no SwiftUI needed), guarding the fix the way `DownloadProgressDisplay`
/// guards the download-fraction logic. The view continues to build its `GridItem` directly; this
/// type documents and asserts the relationship between the card width and the track minimum.
public enum LibraryGridLayout {

    /// The resolved track layout for a given container width.
    public struct Layout: Sendable, Equatable {
        /// Number of adaptive tracks (columns) the grid forms — at least 1.
        public let columnCount: Int
        /// Width of each resolved track, in points.
        public let trackWidth: Double
        /// `true` when a track would be narrower than the card, i.e. the fixed-width cards
        /// would overflow their tracks and bunch with no gap. The fix makes this impossible
        /// by setting `minTrack == cardWidth`.
        public let collapsesSpacing: Bool

        public init(columnCount: Int, trackWidth: Double, collapsesSpacing: Bool) {
            self.columnCount = columnCount
            self.trackWidth = trackWidth
            self.collapsesSpacing = collapsesSpacing
        }
    }

    /// Resolve the adaptive track layout the same way SwiftUI's `.adaptive` column does.
    ///
    /// `.adaptive` fits as many `minTrack`-wide tracks (separated by `spacing`) as the width
    /// allows, then grows each track up to `maxTrack` to share the leftover. The number of
    /// tracks `n` is the largest integer with `n * minTrack + (n - 1) * spacing <= width`
    /// (always at least 1). Each resolved track is then
    /// `min(maxTrack, (width - (n - 1) * spacing) / n)`.
    ///
    /// - Parameters:
    ///   - width: the container (ScrollView) width available to the grid.
    ///   - cardWidth: the fixed cell width (`LibrarySectionCard` is 300pt).
    ///   - minTrack: the adaptive column's `minimum`.
    ///   - maxTrack: the adaptive column's `maximum`.
    ///   - spacing: the inter-track spacing passed to the `GridItem`.
    /// - Returns: the resolved `Layout`, including whether any track is narrower than the card.
    public static func resolve(width: Double,
                               cardWidth: Double,
                               minTrack: Double,
                               maxTrack: Double,
                               spacing: Double) -> Layout {
        let safeMin = max(minTrack, 1)
        // Largest n with n*min + (n-1)*spacing <= width  →  n <= (width + spacing) / (min + spacing)
        var count = Int((width + spacing) / (safeMin + spacing))
        count = max(count, 1)
        let totalSpacing = spacing * Double(count - 1)
        let rawTrack = (width - totalSpacing) / Double(count)
        let trackWidth = min(maxTrack, rawTrack)
        return Layout(columnCount: count,
                      trackWidth: trackWidth,
                      collapsesSpacing: trackWidth < cardWidth)
    }
}
