import Foundation

/// Deterministic poster-grid geometry for iPhone/iPad library grids (iPhone Duo design spec,
/// "Library grid and A–Z rail" and global rule 8).
///
/// The column count is the largest count whose posters stay at or above the family minimum
/// once the page padding, gutters and A–Z rail reservation are removed from the measured width;
/// posters then fill the row. That yields 3 columns folded portrait, 4 folded landscape, 3
/// unfolded upright and 4 unfolded sideways on iPhone Duo without reading the pose or idiom.
/// Compact grids never drop below three columns.
///
/// Compact grids wider than the three-column minimum round the fitted count down to an even
/// number (rule 8: folded landscape is 4, never 5). The rounding happens on the fitted count, so
/// the A–Z rail appearing after load (30 pt reservation) cannot flip a folded-landscape grid
/// between 5 and 4 columns. An even count whose posters would exceed the family maximum keeps
/// the odd count instead, so the rule never stretches posters past `gridMax`.
///
/// Book: the count is rounded down to an even number and split around the hinge. Both outer
/// margins stay put, the narrower half sets the poster width, and only the gutter at the hinge
/// widens (T-POSE's Fitness example; Resolved decision 2).
public enum MobileLibraryGridLayout {
    public struct Metrics: Equatable, Sendable {
        public let columnCount: Int
        public let posterWidth: Double
        public let gutter: Double
        public let rowSpacing: Double
        public let horizontalPadding: Double
        public let trailingReservation: Double
        /// Book only: the column after which the hinge gutter sits (0-based), and its width.
        public let hingeAfterColumn: Int?
        public let hingeGutter: Double?

        /// Spacing after each column, in order (the last is 0).
        public var columnSpacings: [Double] {
            (0..<columnCount).map { index in
                if index == columnCount - 1 { return 0 }
                if index == hingeAfterColumn, let hingeGutter { return hingeGutter }
                return gutter
            }
        }

        public var requiredWidth: Double {
            (posterWidth * Double(columnCount))
                + columnSpacings.reduce(0, +)
                + (horizontalPadding * 2)
                + trailingReservation
        }
    }

    public struct Style: Equatable, Sendable {
        public let minimumPosterWidth: Double
        public let gutter: Double
        public let rowSpacing: Double
        public let horizontalPadding: Double
        public let minimumColumns: Int
        /// The family maximum (`gridMax`); the even rounding never pushes posters past it.
        public let maximumPosterWidth: Double?
        /// Round counts above `minimumColumns` down to an even number (rule 8).
        public let prefersEvenColumnsAboveMinimum: Bool

        public init(minimumPosterWidth: Double, gutter: Double, rowSpacing: Double,
                    horizontalPadding: Double, minimumColumns: Int,
                    maximumPosterWidth: Double? = nil,
                    prefersEvenColumnsAboveMinimum: Bool = false) {
            self.minimumPosterWidth = minimumPosterWidth
            self.gutter = gutter
            self.rowSpacing = rowSpacing
            self.horizontalPadding = horizontalPadding
            self.minimumColumns = max(minimumColumns, 1)
            self.maximumPosterWidth = maximumPosterWidth
            self.prefersEvenColumnsAboveMinimum = prefersEvenColumnsAboveMinimum
        }

        /// Phone-class grids: 104 pt minimum (`DS.Poster.Compact.gridMin`), 8 pt gutters,
        /// 12 pt edges, never fewer than three columns, 150 pt maximum (`gridMax`), even counts
        /// above three.
        public static let compact = Style(minimumPosterWidth: 104, gutter: 8, rowSpacing: 12,
                                          horizontalPadding: 12, minimumColumns: 3,
                                          maximumPosterWidth: 150,
                                          prefersEvenColumnsAboveMinimum: true)
        /// Regular-width grids: 168 pt minimum (`DS.Poster.gridMin`), 24 pt gutters and edges.
        public static let regular = Style(minimumPosterWidth: 168, gutter: 24, rowSpacing: 32,
                                          horizontalPadding: 24, minimumColumns: 1)
    }

    /// A book hinge in the grid's own horizontal coordinate space (0 = the grid's leading edge).
    public struct Hinge: Equatable, Sendable {
        public let minX: Double
        public let maxX: Double

        public init(minX: Double, maxX: Double) {
            self.minX = min(minX, maxX)
            self.maxX = max(minX, maxX)
        }
    }

    /// Compact phone grid (kept for callers that predate the measured style).
    public static func metrics(availableWidth: Double, trailingReservation: Double = 0) -> Metrics {
        metrics(availableWidth: availableWidth, trailingReservation: trailingReservation, style: .compact)
    }

    public static func metrics(availableWidth: Double,
                               trailingReservation: Double = 0,
                               style: Style,
                               bookHinge: Hinge? = nil) -> Metrics {
        let width = availableWidth.isFinite ? max(availableWidth, 0) : 0
        let reservation = trailingReservation.isFinite ? max(trailingReservation, 0) : 0
        let padding = style.horizontalPadding
        let gutter = style.gutter
        let usable = max(width - padding * 2 - reservation, 0)

        let fitting = Int(((usable + gutter) / (style.minimumPosterWidth + gutter)).rounded(.down))
        var columns = max(fitting, style.minimumColumns)
        if style.prefersEvenColumnsAboveMinimum, columns > style.minimumColumns, columns % 2 == 1 {
            let even = columns - 1
            let evenWidth = (usable - gutter * Double(even - 1)) / Double(even)
            if even >= style.minimumColumns,
               evenWidth <= (style.maximumPosterWidth ?? .infinity) {
                columns = even
            }
        }

        if let bookHinge, let book = bookMetrics(width: width, reservation: reservation,
                                                 style: style, columns: columns, hinge: bookHinge) {
            return book
        }

        let posterWidth = max((usable - gutter * Double(columns - 1)) / Double(columns), 0)
        return Metrics(columnCount: columns,
                       posterWidth: posterWidth,
                       gutter: gutter,
                       rowSpacing: style.rowSpacing,
                       horizontalPadding: padding,
                       trailingReservation: reservation,
                       hingeAfterColumn: nil,
                       hingeGutter: nil)
    }

    private static func bookMetrics(width: Double, reservation: Double, style: Style,
                                    columns: Int, hinge: Hinge) -> Metrics? {
        let padding = style.horizontalPadding
        let gutter = style.gutter
        let leadingEdge = padding
        let trailingEdge = width - padding - reservation
        // The hinge must cross the grid's content, with room on both sides.
        guard hinge.minX > leadingEdge, hinge.maxX < trailingEdge else { return nil }
        let even = max(columns - columns % 2, 2)
        let perHalf = even / 2
        let firstSpan = hinge.minX - gutter / 2 - leadingEdge
        let secondSpan = trailingEdge - (hinge.maxX + gutter / 2)
        let fixedGutters = gutter * Double(perHalf - 1)
        let posterWidth = min((firstSpan - fixedGutters) / Double(perHalf),
                              (secondSpan - fixedGutters) / Double(perHalf))
        guard posterWidth > 0 else { return nil }
        let blocks = posterWidth * Double(even) + fixedGutters * 2
        let hingeGutter = (trailingEdge - leadingEdge) - blocks
        return Metrics(columnCount: even,
                       posterWidth: posterWidth,
                       gutter: gutter,
                       rowSpacing: style.rowSpacing,
                       horizontalPadding: padding,
                       trailingReservation: reservation,
                       hingeAfterColumn: perHalf - 1,
                       hingeGutter: hingeGutter)
    }
}
