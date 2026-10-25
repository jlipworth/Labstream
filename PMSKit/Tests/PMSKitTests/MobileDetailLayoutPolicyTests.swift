import Foundation
import Testing
@testable import PMSKit

struct MobileDetailLayoutPolicyTests {
    typealias Mode = MobileDetailLayoutPolicy.Mode

    @Test(arguments: [
        // iPhone 18 Pro portrait / landscape (compact width in both).
        (402.0, 874.0, true, Mode.phone),
        (874.0, 402.0, true, Mode.phone),
        // Pro Max landscape reports regular width and has room for side by side.
        (956.0, 440.0, false, Mode.sideBySide),
        // iPhone Duo outer display, folded, both orientations.
        (466.0, 678.0, true, Mode.phone),
        (678.0, 466.0, true, Mode.phone),
        // iPhone Duo inner display: regular width but too narrow for side by side.
        (669.0, 951.0, false, Mode.stacked),
        (951.0, 669.0, false, Mode.sideBySide),
        // iPad full screen and Split View panes.
        (1032.0, 1376.0, false, Mode.sideBySide),
        (744.0, 1133.0, false, Mode.sideBySide),
        (507.0, 1366.0, true, Mode.stacked),
        (320.0, 1024.0, true, Mode.phone),
    ])
    func modeFollowsMeasuredViewport(width: Double, height: Double, compact: Bool, expected: Mode) {
        #expect(MobileDetailLayoutPolicy.mode(viewportWidth: width,
                                              viewportHeight: height,
                                              horizontallyCompact: compact) == expected)
    }

    @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity])
    func unmeasuredViewportFallsBackToSizeClass(width: Double) {
        #expect(MobileDetailLayoutPolicy.mode(viewportWidth: width, viewportHeight: 800,
                                              horizontallyCompact: true) == .phone)
        #expect(MobileDetailLayoutPolicy.mode(viewportWidth: width, viewportHeight: 800,
                                              horizontallyCompact: false) == .sideBySide)
    }

    @Test func artworkCapIsFortyPercentOfViewportHeight() {
        #expect(MobileDetailLayoutPolicy.artworkMaximumHeight(viewportHeight: 678) == 678 * 0.4)
        #expect(MobileDetailLayoutPolicy.artworkMaximumHeight(viewportHeight: 0) == nil)
        #expect(MobileDetailLayoutPolicy.artworkMaximumHeight(viewportHeight: .nan) == nil)
    }

    @Test func heroKeepsAuthoredSizeWhenThereIsRoom() {
        // iPhone portrait sheet and iPad keep the authored 220/300-pt heroes.
        #expect(MobileDetailLayoutPolicy.heroSide(preferred: 220, viewportWidth: 402,
                                                  viewportHeight: 820, horizontalPadding: 16) == 220)
        #expect(MobileDetailLayoutPolicy.heroSide(preferred: 300, viewportWidth: 1032,
                                                  viewportHeight: 1300, horizontalPadding: 32) == 300)
        #expect(MobileDetailLayoutPolicy.heroSide(preferred: 300, viewportWidth: 669,
                                                  viewportHeight: 900, horizontalPadding: 32) == 300)
    }

    @Test func heroShrinksOnShortViewportsButNotBelowMinimum() {
        // Folded Duo in landscape: 466 pt of height.
        let landscape = MobileDetailLayoutPolicy.heroSide(preferred: 220, viewportWidth: 678,
                                                          viewportHeight: 420, horizontalPadding: 16)
        #expect(landscape == 420 * 0.45)
        let tiny = MobileDetailLayoutPolicy.heroSide(preferred: 220, viewportWidth: 200,
                                                     viewportHeight: 100, horizontalPadding: 16)
        #expect(tiny == 120)
    }

    @Test func heroIsUnchangedBeforeMeasurement() {
        #expect(MobileDetailLayoutPolicy.heroSide(preferred: 220, viewportWidth: 0,
                                                  viewportHeight: 0, horizontalPadding: 16) == 220)
    }
}
