import Foundation
import Testing
@testable import PMSKit

struct MobileLibraryGridLayoutTests {
    @Test(arguments: [320.0, 375.0, 390.0, 430.0], [0.0, 30.0])
    func compactWidthsFit(width: Double, reservation: Double) {
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: width,
                                                      trailingReservation: reservation)
        #expect(metrics.columnCount == 3)
        #expect(metrics.posterWidth <= 150)
        #expect(metrics.posterWidth >= 0)
        #expect(metrics.requiredWidth <= width + 0.001)
        if width >= 334 || reservation == 0 {
            #expect(metrics.posterWidth >= 88)
        }
    }

    @Test(arguments: [0.0, -20.0, Double.nan, Double.infinity])
    func degenerateWidthsStayFinite(width: Double) {
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: width,
                                                      trailingReservation: 30)
        #expect(metrics.posterWidth.isFinite)
        #expect(metrics.posterWidth >= 0)
        #expect(metrics.requiredWidth.isFinite)
    }

    /// Approximate content-region widths: the vertical bar's inset is already removed.
    @Test(arguments: [
        (382.0, MobileLibraryGridLayout.Style.compact, 30.0, 3),   // folded portrait
        (594.0, MobileLibraryGridLayout.Style.compact, 30.0, 4),   // folded landscape
        (669.0, MobileLibraryGridLayout.Style.regular, 18.0, 3),   // unfolded upright
        (867.0, MobileLibraryGridLayout.Style.regular, 18.0, 4),   // unfolded sideways
    ])
    func duoPosesUseTheDesignColumnCounts(width: Double, style: MobileLibraryGridLayout.Style,
                                          reservation: Double, columns: Int) {
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: width,
                                                      trailingReservation: reservation,
                                                      style: style)
        #expect(metrics.columnCount == columns)
        #expect(metrics.posterWidth >= style.minimumPosterWidth)
        #expect(abs(metrics.requiredWidth - width) < 0.001)
        #expect(metrics.hingeGutter == nil)
    }

    /// Folded landscape is 4 columns whether or not the A–Z rail is reserved yet (it is hidden
    /// while loading and for libraries with one bucket), so the grid never jumps 5 → 4.
    @Test(arguments: [594.0, 598.0], [0.0, 30.0])
    func foldedLandscapeStaysFourWithOrWithoutTheRail(width: Double, reservation: Double) {
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: width,
                                                      trailingReservation: reservation,
                                                      style: .compact)
        #expect(metrics.columnCount == 4)
        #expect(metrics.posterWidth >= 104)
        #expect(metrics.posterWidth <= 150)
        #expect(abs(metrics.requiredWidth - width) < 0.001)
    }

    @Test func compactOddCountsAboveThreeRoundDownToEven() {
        // 7 would fit at the minimum; 6 is used.
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: 800, style: .compact)
        #expect(metrics.columnCount == 6)
    }

    @Test func evenRoundingNeverExceedsTheFamilyMaximum() {
        // 643 pt (a slab phone in landscape): 5 fit; 4 would make 154.75 pt posters (> 150).
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: 667, style: .compact)
        #expect(metrics.columnCount == 5)
        #expect(metrics.posterWidth <= 150)
    }

    @Test func regularGridsKeepTheirFittedCount() {
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: 1100, style: .regular)
        #expect(metrics.columnCount == 5)
    }

    @Test func bookSplitsTwoPlusTwoAndKeepsBothOuterMargins() {
        // Sideways inner display with a trailing bar: content 0..867, hinge at 465.5...485.5.
        let width = 867.0
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: width,
                                                      trailingReservation: 18,
                                                      style: .regular,
                                                      bookHinge: .init(minX: 465.5, maxX: 485.5))
        #expect(metrics.columnCount == 4)
        #expect(metrics.hingeAfterColumn == 1)
        let hingeGutter = try! #require(metrics.hingeGutter)
        // The trailing half is narrower (bar reserve), so it sets the width and the hinge gutter
        // is wider than an ordinary gutter.
        #expect(hingeGutter > metrics.gutter)
        #expect(abs(metrics.requiredWidth - width) < 0.001)
        // Second-half columns start at or after the hinge plus half a gutter.
        let secondStart = metrics.horizontalPadding + metrics.posterWidth * 2 + metrics.gutter + hingeGutter
        #expect(secondStart >= 485.5 + metrics.gutter / 2 - 0.001)
        let firstEnd = metrics.horizontalPadding + metrics.posterWidth * 2 + metrics.gutter
        #expect(firstEnd <= 465.5 - metrics.gutter / 2 + 0.001)
    }

    @Test func bookRoundsAnOddCountDownToEven() {
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: 1100,
                                                      style: .regular,
                                                      bookHinge: .init(minX: 540, maxX: 560))
        #expect(metrics.columnCount % 2 == 0)
    }

    @Test func aHingeOutsideTheGridIsIgnored() {
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: 669, style: .regular,
                                                      bookHinge: .init(minX: 700, maxX: 720))
        #expect(metrics.hingeGutter == nil)
        #expect(metrics.columnCount == 3)
    }
}
