import Foundation

/// Deterministic three-column geometry for compact mobile library grids.
public enum MobileLibraryGridLayout {
    public struct Metrics: Equatable, Sendable {
        public let columnCount: Int
        public let posterWidth: Double
        public let gutter: Double
        public let rowSpacing: Double
        public let horizontalPadding: Double
        public let trailingReservation: Double

        public var requiredWidth: Double {
            (posterWidth * Double(columnCount))
                + (gutter * Double(max(columnCount - 1, 0)))
                + (horizontalPadding * 2)
                + trailingReservation
        }
    }

    public static func metrics(availableWidth: Double, trailingReservation: Double = 0) -> Metrics {
        let width = availableWidth.isFinite ? max(availableWidth, 0) : 0
        let reservation = trailingReservation.isFinite ? max(trailingReservation, 0) : 0
        let columnCount = 3
        let gutter = 8.0
        let horizontalPadding = 12.0
        let fixedWidth = horizontalPadding * 2 + gutter * Double(columnCount - 1) + reservation
        let computed = max((width - fixedWidth) / Double(columnCount), 0)
        let posterWidth = min(max(computed, 88), 112)
        let fittingPosterWidth = posterWidth * Double(columnCount) + fixedWidth <= width
            ? posterWidth
            : computed

        return Metrics(columnCount: columnCount,
                       posterWidth: fittingPosterWidth,
                       gutter: gutter,
                       rowSpacing: 12,
                       horizontalPadding: horizontalPadding,
                       trailingReservation: reservation)
    }
}
