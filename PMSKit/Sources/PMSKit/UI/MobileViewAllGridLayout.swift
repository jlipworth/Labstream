/// Three-column compact grid that spends all available width on artwork instead of capping
/// posters at the library A–Z grid's 112-point maximum. View All has no alphabet rail, so the
/// saved horizontal space should make cards larger rather than becoming empty track width.
public enum MobileViewAllGridLayout {
    public struct Metrics: Equatable, Sendable {
        public let columnCount: Int
        public let posterWidth: Double
        public let gutter: Double
        public let rowSpacing: Double
        public let horizontalPadding: Double

        public var requiredWidth: Double {
            posterWidth * Double(columnCount)
                + gutter * Double(max(columnCount - 1, 0))
                + horizontalPadding * 2
        }
    }

    public static func metrics(availableWidth: Double) -> Metrics {
        let width = availableWidth.isFinite ? max(availableWidth, 0) : 0
        let columnCount = 3
        let gutter = 8.0
        let horizontalPadding = 12.0
        let fixedWidth = horizontalPadding * 2 + gutter * Double(columnCount - 1)
        let posterWidth = max((width - fixedWidth) / Double(columnCount), 0)
        return Metrics(columnCount: columnCount,
                       posterWidth: posterWidth,
                       gutter: gutter,
                       rowSpacing: 12,
                       horizontalPadding: horizontalPadding)
    }
}
