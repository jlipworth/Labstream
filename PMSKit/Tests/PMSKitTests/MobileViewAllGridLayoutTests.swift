import Testing
@testable import PMSKit

struct MobileViewAllGridLayoutTests {
    @Test(arguments: [320.0, 375.0, 390.0, 430.0])
    func threeColumnsConsumeTheAvailableWidth(width: Double) {
        let metrics = MobileViewAllGridLayout.metrics(availableWidth: width)
        #expect(metrics.columnCount == 3)
        #expect(metrics.requiredWidth == width)
        #expect(metrics.gutter == 8)
        #expect(metrics.horizontalPadding == 12)
    }

    @Test func widerPhonesGrowArtworkPastTheLibraryGridCap() {
        #expect(MobileViewAllGridLayout.metrics(availableWidth: 390).posterWidth > 112)
        #expect(MobileViewAllGridLayout.metrics(availableWidth: 430).posterWidth == 130)
    }

    @Test(arguments: [0.0, -20.0, Double.nan, Double.infinity])
    func degenerateWidthsRemainFiniteAndNonnegative(width: Double) {
        let metrics = MobileViewAllGridLayout.metrics(availableWidth: width)
        #expect(metrics.posterWidth.isFinite)
        #expect(metrics.posterWidth >= 0)
    }
}
