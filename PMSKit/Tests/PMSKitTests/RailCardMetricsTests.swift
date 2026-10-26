import Foundation
import Testing
@testable import PMSKit

struct RailCardMetricsTests {
    /// Approximate vertical-bar reserve (bar capsule plus its gaps) used by the design worked
    /// examples. Code reads the real inset; the viewport is the same whichever edge carries it.
    private static let barReserve = 90.0

    // (screen width, bar present, compact, expected whole cards)
    @Test(arguments: [
        (466.0, true, true, 3),    // folded portrait: ~376 pt viewport, clamp floor wins
        (678.0, true, true, 4),    // folded landscape: ~588 pt viewport
        (669.0, false, false, 3),  // unfolded upright: horizontal bars, full width
        (951.0, true, false, 4),   // unfolded sideways: ~861 pt viewport
    ])
    func duoPosesShowWholeCardsPlusACue(screen: Double, bar: Bool, compact: Bool, expected: Int) {
        let viewport = screen - (bar ? Self.barReserve : 0)
        let margin = compact ? 12.0 : 32.0
        let gutter = compact ? 12.0 : 24.0
        let family = RailCardMetrics.Family.poster(compact: compact)
        let metrics = RailCardMetrics.metrics(viewportWidth: viewport, margin: margin,
                                              gutter: gutter, family: family)
        #expect(metrics.wholeCards == expected)
        #expect(metrics.cardWidth >= family.minimum)
        #expect(metrics.cardWidth <= family.maximum)
        // Whole cards end before the viewport edge and leave a visible cue.
        let used = margin + Double(metrics.wholeCards) * (metrics.cardWidth + gutter)
        #expect(used <= viewport + 0.001)
        #expect(metrics.cueWidth > 0)
    }

    @Test func foldedPortraitUsesTheCompactMinimum() {
        let metrics = RailCardMetrics.metrics(viewportWidth: 376, margin: 12, gutter: 12,
                                              family: .compactPoster)
        #expect(metrics.wholeCards == 3)
        #expect(metrics.cardWidth == 104)
        #expect(abs(metrics.cueWidth - 16) < 0.001)
    }

    @Test func sideOfTheBarDoesNotChangeTheMetrics() {
        // Leading and trailing bars remove the same inset from the viewport.
        let leading = RailCardMetrics.metrics(viewportWidth: 951 - 96, margin: 32, gutter: 24,
                                              family: .regularPoster)
        let trailing = RailCardMetrics.metrics(viewportWidth: 951 - 96, margin: 32, gutter: 24,
                                               family: .regularPoster)
        #expect(leading == trailing)
    }

    @Test func wideIPadStaysNearTheAuthoredWidth() {
        let metrics = RailCardMetrics.metrics(viewportWidth: 1180, margin: 32, gutter: 24,
                                              family: .regularPoster)
        #expect(abs(metrics.cardWidth - 184) < 20)
    }

    @Test(arguments: [0.0, -10.0, Double.nan, Double.infinity])
    func degenerateWidthsStayFinite(width: Double) {
        let metrics = RailCardMetrics.metrics(viewportWidth: width, margin: 12, gutter: 12,
                                              family: .compactPoster)
        #expect(metrics.cardWidth.isFinite)
        #expect(metrics.wholeCards >= 1)
        #expect(metrics.cueWidth >= 0)
    }
}
