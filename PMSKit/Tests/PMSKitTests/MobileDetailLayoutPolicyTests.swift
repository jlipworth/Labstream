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

    @Test func resolvedModeWaitsForTheFirstMeasurement() {
        #expect(MobileDetailLayoutPolicy.resolvedMode(viewportWidth: 0, viewportHeight: 800,
                                                      horizontallyCompact: false) == nil)
        #expect(MobileDetailLayoutPolicy.resolvedMode(viewportWidth: 669, viewportHeight: .nan,
                                                      horizontallyCompact: false) == nil)
        #expect(MobileDetailLayoutPolicy.resolvedMode(viewportWidth: 669, viewportHeight: 951,
                                                      horizontallyCompact: false) == .stacked)
    }

    @Test func artworkIsFullWidthSixteenByNineCappedAtFortyPercentHeight() {
        // Folded portrait: 16:9 of the width fits under the cap.
        #expect(MobileDetailLayoutPolicy.artworkHeight(viewportWidth: 466, viewportHeight: 678)
                == 466.0 * 9 / 16)
        // Folded landscape and slab landscape: the height cap wins; the art still spans the width.
        #expect(MobileDetailLayoutPolicy.artworkHeight(viewportWidth: 678, viewportHeight: 466)
                == 466 * 0.4)
        #expect(MobileDetailLayoutPolicy.artworkHeight(viewportWidth: 874, viewportHeight: 300) == 120)
        #expect(MobileDetailLayoutPolicy.artworkHeight(viewportWidth: 0, viewportHeight: 300) == nil)
        #expect(MobileDetailLayoutPolicy.artworkHeight(viewportWidth: 874, viewportHeight: 0) == nil)
    }

    @Test func sideBySideFlatPutsMetadataAfterThePoster() {
        let placement = MobileDetailLayoutPolicy.sideBySidePlacement(contentWidth: 850, posterWidth: 220,
                                                                     margin: 24, gap: 32)
        #expect(placement == .init(posterLeading: 24, metadataLeading: 276, followsHinge: false))
    }

    @Test func sideBySideBookCentresThePosterBeforeTheHinge() {
        // 867-pt content region with the hinge strip at 465.5...485.5.
        let placement = MobileDetailLayoutPolicy.sideBySidePlacement(contentWidth: 867, posterWidth: 220,
                                                                     margin: 24, gap: 32,
                                                                     hinge: (465.5, 485.5))
        #expect(placement.followsHinge)
        #expect(placement.posterLeading == 24 + (441.5 - 220) / 2)
        #expect(placement.metadataLeading == 509.5)
        // A hinge that leaves no room for the poster is ignored.
        let cramped = MobileDetailLayoutPolicy.sideBySidePlacement(contentWidth: 867, posterWidth: 220,
                                                                   margin: 24, gap: 32,
                                                                   hinge: (200, 220))
        #expect(!cramped.followsHinge)
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
