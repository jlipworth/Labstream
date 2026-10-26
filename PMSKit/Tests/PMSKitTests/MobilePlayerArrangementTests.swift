#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import PMSKit

struct MobilePlayerArrangementTests {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Overlay

    @Test func foldedLandscapeOverlaysTheWholeSafeFrame() {
        // 678×466 with the 82 pt status strip on top (vertical bar disabled) and a home indicator.
        let bounds = rect(0, 0, 678, 466)
        let safe = rect(0, 82, 678, 364)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: safe, pose: .flat,
                                                          videoAspect: 16.0 / 9.0, fillsScreen: false)
        #expect(arrangement.mode == .overlay)
        #expect(arrangement.videoFrame == bounds)
        #expect(arrangement.chromeFrame == safe)
        #expect(arrangement.transportFrame == safe)
        #expect(arrangement.bottomGroupFrame == safe)
        #expect(arrangement.statusFrame == safe)
        #expect(!arrangement.pinsControls)
    }

    @Test func unfoldedSidewaysOverlaysTheWholeSafeFrame() {
        let bounds = rect(0, 0, 951, 669)
        let safe = rect(0, 24, 951, 625)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: safe, pose: .flat,
                                                          videoAspect: 2.39, fillsScreen: false)
        #expect(arrangement.mode == .overlay)
        #expect(arrangement.chromeFrame == safe)
    }

    @Test func unmeasuredSafeFrameFallsBackToTheBounds() {
        let bounds = rect(0, 0, 678, 466)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: .zero, pose: .flat,
                                                          videoAspect: nil, fillsScreen: false)
        #expect(arrangement.mode == .overlay)
        #expect(arrangement.chromeFrame == bounds)
    }

    // MARK: Upright: the chrome overlays the video rectangle

    @Test func uprightSixteenByNineOverlaysTheVideoRect() {
        let bounds = rect(0, 0, 669, 951)
        let safe = rect(0, 24, 669, 907)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: safe, pose: .flat,
                                                          videoAspect: 16.0 / 9.0, fillsScreen: false)
        #expect(arrangement.mode == .videoRect)
        #expect(arrangement.videoFrame == bounds)
        let videoHeight = 669 / (16.0 / 9.0)
        #expect(abs(arrangement.chromeFrame.height - videoHeight) < 0.01)
        #expect(abs(arrangement.chromeFrame.midY - 951 / 2) < 0.01)
        #expect(arrangement.statusFrame == arrangement.chromeFrame)
        #expect(arrangement.transportFrame == arrangement.chromeFrame)
    }

    @Test func uprightWidePictureKeepsTheMinimumChromeHeightAroundTheCentre() {
        let bounds = rect(0, 0, 669, 951)
        let safe = rect(0, 24, 669, 907)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: safe, pose: .flat,
                                                          videoAspect: 2.39, fillsScreen: false)
        #expect(arrangement.mode == .videoRect)
        #expect(arrangement.chromeFrame.height == MobilePlayerArrangement.minimumOverlayHeight)
        #expect(abs(arrangement.chromeFrame.midY - 951 / 2) < 0.01)
    }

    @Test func uprightUnknownAspectAssumesSixteenByNine() {
        let bounds = rect(0, 0, 669, 951)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: bounds, pose: .flat,
                                                          videoAspect: nil, fillsScreen: false)
        #expect(arrangement.mode == .videoRect)
        #expect(abs(arrangement.chromeFrame.height - 669 * 9 / 16) < 0.01)
    }

    @Test func uprightFillCoversTheScreenSoTheChromeUsesTheSafeFrame() {
        let bounds = rect(0, 0, 669, 951)
        let safe = rect(0, 24, 669, 907)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: safe, pose: .flat,
                                                          videoAspect: 16.0 / 9.0, fillsScreen: true)
        #expect(arrangement.mode == .overlay)
        #expect(arrangement.chromeFrame == safe)
    }

    @Test func portraitPictureTallerThanTheViewportUsesTheSafeFrame() {
        let bounds = rect(0, 0, 669, 951)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: bounds, pose: .flat,
                                                          videoAspect: 9.0 / 16.0, fillsScreen: false)
        #expect(arrangement.mode == .overlay)
    }

    @Test func uprightChromeStaysInsideTheSafeFrame() {
        // A short portrait iPad window with a tall safe-area top: the expanded band is clamped.
        let bounds = rect(0, 0, 400, 520)
        let safe = rect(0, 200, 400, 300)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: safe, pose: .flat,
                                                          videoAspect: 2.39, fillsScreen: false)
        #expect(arrangement.mode == .videoRect)
        #expect(safe.contains(arrangement.chromeFrame))
        #expect(arrangement.chromeFrame.height == 300)
    }

    // MARK: Book

    @Test func bookMovesTheControlGroupIntoTheTrailingHalf() {
        let bounds = rect(0, 0, 951, 669)
        let safe = rect(0, 24, 951, 625)
        let hinge = rect(465.5, 0, 20, 669)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: safe,
                                                          pose: .book(hinge: hinge),
                                                          videoAspect: 16.0 / 9.0, fillsScreen: false)
        #expect(arrangement.mode == .book)
        // The top row does not move; the picture stays full-bleed.
        #expect(arrangement.chromeFrame == safe)
        #expect(arrangement.videoFrame == bounds)
        // Transport, title, scrubber and circles move together, after the hinge.
        #expect(arrangement.transportFrame.minX == hinge.maxX)
        #expect(arrangement.transportFrame.maxX == safe.maxX)
        #expect(arrangement.bottomGroupFrame == arrangement.transportFrame)
        #expect(arrangement.statusFrame == arrangement.transportFrame)
        #expect(!arrangement.pinsControls)
    }

    @Test func bookWithATooNarrowTrailingHalfStaysOverlay() {
        let bounds = rect(0, 0, 951, 669)
        let hinge = rect(700, 0, 20, 669)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: bounds,
                                                          pose: .book(hinge: hinge),
                                                          videoAspect: nil, fillsScreen: false)
        #expect(arrangement.mode == .overlay)
    }

    // MARK: Tabletop

    @Test func tabletopPutsThePictureAboveTheHingeAndADeckBelow() {
        let bounds = rect(0, 0, 669, 951)
        let safe = rect(0, 24, 669, 907)
        let hinge = rect(0, 465.5, 669, 20)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: safe,
                                                          pose: .tabletop(hinge: hinge),
                                                          videoAspect: 16.0 / 9.0, fillsScreen: false)
        #expect(arrangement.mode == .tabletop)
        #expect(arrangement.videoFrame == rect(0, 0, 669, 465.5))
        #expect(arrangement.chromeFrame == rect(0, 485.5, 669, 931 - 485.5))
        #expect(arrangement.transportFrame == arrangement.chromeFrame)
        #expect(arrangement.bottomGroupFrame == arrangement.chromeFrame)
        // The transport status centres in the picture half, clear of the status bar.
        #expect(arrangement.statusFrame == rect(0, 24, 669, 465.5 - 24))
        #expect(arrangement.pinsControls)
    }

    @Test func tabletopOnASidewaysDisplayIsIgnored() {
        // A horizontal division that does not cross the bounds' height is not a tabletop split.
        let bounds = rect(0, 0, 951, 669)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: bounds,
                                                          pose: .tabletop(hinge: rect(0, 700, 951, 20)),
                                                          videoAspect: nil, fillsScreen: false)
        #expect(arrangement.mode == .overlay)
    }

    @Test func tabletopWithATooShortDeckStaysOverlay() {
        let bounds = rect(0, 0, 669, 951)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: bounds,
                                                          pose: .tabletop(hinge: rect(0, 800, 669, 20)),
                                                          videoAspect: nil, fillsScreen: true)
        #expect(arrangement.mode == .overlay)
    }

    // MARK: Camera island (tent)

    @Test func bottomGroupEndsBeforeATrailingCameraIsland() {
        let bounds = rect(0, 0, 678, 466)
        let safe = rect(0, 44, 678, 402)
        let camera = rect(618, 396, 50, 60)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: safe, pose: .flat,
                                                          videoAspect: 16.0 / 9.0, fillsScreen: false,
                                                          occlusions: [camera])
        #expect(arrangement.bottomGroupFrame.maxX == camera.minX)
        #expect(arrangement.bottomGroupFrame.minX == safe.minX)
        // The transport stays centred in the full frame.
        #expect(arrangement.transportFrame == safe)
    }

    @Test func bottomGroupStartsAfterALeadingCameraIsland() {
        let bounds = rect(0, 0, 678, 466)
        let camera = rect(10, 400, 50, 60)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: bounds, pose: .flat,
                                                          videoAspect: nil, fillsScreen: false,
                                                          occlusions: [camera])
        #expect(arrangement.bottomGroupFrame.minX == camera.maxX)
        #expect(arrangement.bottomGroupFrame.maxX == bounds.maxX)
    }

    @Test func anOcclusionInTheUpperHalfIsLeftToTheSafeArea() {
        let bounds = rect(0, 0, 678, 466)
        let camera = rect(10, 10, 50, 60)
        let arrangement = MobilePlayerArrangement.resolve(bounds: bounds, safeFrame: bounds, pose: .flat,
                                                          videoAspect: nil, fillsScreen: false,
                                                          occlusions: [camera])
        #expect(arrangement.bottomGroupFrame == bounds)
    }
}
