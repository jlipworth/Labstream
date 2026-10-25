import Testing
@testable import PMSKit

struct MobilePlayerChromeLayoutPolicyTests {
    private func policy(_ width: Double, _ height: Double,
                        h: MobilePlayerChromeLayoutPolicy.SizeClass?,
                        v: MobilePlayerChromeLayoutPolicy.SizeClass?,
                        phone: Bool = true) -> MobilePlayerChromeLayoutPolicy {
        MobilePlayerChromeLayoutPolicy(horizontalSizeClass: h, verticalSizeClass: v, isPhoneIdiom: phone,
                                       viewportWidth: width, viewportHeight: height)
    }

    @Test func iPhoneLandscapeIsPhoneLandscape() {
        #expect(policy(874, 402, h: .regular, v: .compact).branch == .phoneLandscape)
        #expect(policy(874, 402, h: .compact, v: .compact).branch == .phoneLandscape)
    }

    @Test func iPhonePortraitIsCompact() {
        #expect(policy(402, 874, h: .compact, v: .regular).branch == .compact)
    }

    @Test func foldedDuoUsesPhoneChromeInBothOrientations() {
        #expect(policy(466, 678, h: .compact, v: .regular).branch == .compact)
        #expect(policy(678, 466, h: .compact, v: .compact).branch == .phoneLandscape)
        // Even if UIKit reported regular classes, the 466 pt short side keeps compact chrome.
        #expect(policy(678, 466, h: .regular, v: .regular).branch == .phoneLandscape)
        #expect(policy(466, 678, h: .regular, v: .regular).usesCompactChrome)
    }

    @Test func unfoldedDuoUsesRegularChromeDespiteThePhoneIdiom() {
        #expect(policy(669, 951, h: .regular, v: .regular).branch == .regular)
        #expect(policy(951, 669, h: .regular, v: .regular).branch == .regular)
    }

    @Test func iPadFollowsGeometry() {
        #expect(policy(1032, 1376, h: .regular, v: .regular, phone: false).branch == .regular)
        #expect(policy(420, 1376, h: .compact, v: .regular, phone: false).branch == .compact)
        // A short iPad window is compact but never the phone-landscape composition.
        #expect(policy(800, 450, h: .regular, v: .regular, phone: false).branch == .compact)
    }

    @Test func unmeasuredViewportFallsBackToSizeClasses() {
        #expect(policy(0, 0, h: .compact, v: .regular).branch == .compact)
        #expect(policy(0, 0, h: .regular, v: .regular).branch == .regular)
        #expect(policy(0, 0, h: .regular, v: .compact).branch == .phoneLandscape)
    }
}

struct PlayerTopSafeInsetLatchTests {
    @Test func holdsTheLargestInsetForOneViewport() {
        var latch = PlayerTopSafeInsetLatch()
        #expect(latch.observe(viewportWidth: 669, viewportHeight: 951, topInset: 24) == 24)
        // Status bar hidden with the chrome: the inset drops to zero but the latch holds.
        #expect(latch.observe(viewportWidth: 669, viewportHeight: 951, topInset: 0) == 24)
        #expect(latch.observe(viewportWidth: 669, viewportHeight: 951, topInset: 30) == 30)
    }

    @Test func statusBarToggleDoesNotRestartTheSafeAreaKeyedLatch() {
        // Real call-site shape: the measured view sits inside the safe area, so hiding the status
        // bar grows the layout height by the inset it removes. The full-bounds key stays put.
        var latch = PlayerTopSafeInsetLatch()
        #expect(latch.observe(safeAreaWidth: 669, safeAreaHeight: 927,
                              top: 24, bottom: 0, leading: 0, trailing: 0) == 24)
        #expect(latch.observe(safeAreaWidth: 669, safeAreaHeight: 951,
                              top: 0, bottom: 0, leading: 0, trailing: 0) == 24)
        #expect(latch.observe(safeAreaWidth: 669, safeAreaHeight: 927,
                              top: 24, bottom: 0, leading: 0, trailing: 0) == 24)
        // A real resize (fold/rotation/window) still starts a fresh measurement.
        #expect(latch.observe(safeAreaWidth: 951, safeAreaHeight: 669,
                              top: 0, bottom: 0, leading: 0, trailing: 0) == 0)
    }

    @Test func aNewViewportStartsAFreshMeasurement() {
        var latch = PlayerTopSafeInsetLatch()
        latch.observe(viewportWidth: 466, viewportHeight: 678, topInset: 40)
        #expect(latch.observe(viewportWidth: 678, viewportHeight: 466, topInset: 0) == 0)
    }

    @Test func paddingKeepsTheAuthoredInsetUnlessTheSafeAreaIsDeeper() {
        #expect(PlayerTopSafeInsetLatch.topChromePadding(authored: 6, latchedTopInset: 0) == 6)
        #expect(PlayerTopSafeInsetLatch.topChromePadding(authored: 28, latchedTopInset: 24) == 28)
        #expect(PlayerTopSafeInsetLatch.topChromePadding(authored: 12, latchedTopInset: 59) == 63)
    }
}
