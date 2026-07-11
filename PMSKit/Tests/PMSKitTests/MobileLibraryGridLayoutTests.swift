import Foundation
import Testing
@testable import PMSKit

struct MobileLibraryGridLayoutTests {
    @Test(arguments: [320.0, 375.0, 390.0, 430.0], [0.0, 30.0])
    func compactWidthsFit(width: Double, reservation: Double) {
        let metrics = MobileLibraryGridLayout.metrics(availableWidth: width,
                                                      trailingReservation: reservation)
        #expect(metrics.columnCount == 3)
        #expect(metrics.posterWidth <= 112)
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
}
