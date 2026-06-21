import Testing
@testable import PMSKit

/// Pins the top-level browse/splash/login gate (#90 finding 2) so a backend switch from an
/// already-ready UI never bounces to the splash, while a genuinely signed-out user still
/// sees the restore splash / login.
@Suite("Browse UI gate")
struct BrowseUIGateTests {

    @Test("browse when the active lane is ready")
    func browseWhenReady() {
        #expect(BrowseUIGate.state(isBrowseReady: true, isRestoring: false,
                                   isSwitchingBackend: false, hasEverBeenBrowseReady: true) == .browse)
        // Ready wins even mid-switch.
        #expect(BrowseUIGate.state(isBrowseReady: true, isRestoring: true,
                                   isSwitchingBackend: true, hasEverBeenBrowseReady: false) == .browse)
    }

    @Test("a switch from an already-ready UI stays mounted (no bounce)")
    func switchFromReadyStaysMounted() {
        #expect(BrowseUIGate.state(isBrowseReady: false, isRestoring: false,
                                   isSwitchingBackend: true, hasEverBeenBrowseReady: true) == .browse)
    }

    @Test("a first-ever switch with no prior browse UI shows the splash")
    func firstEverSwitchShowsSplash() {
        #expect(BrowseUIGate.state(isBrowseReady: false, isRestoring: false,
                                   isSwitchingBackend: true, hasEverBeenBrowseReady: false) == .restoringSplash)
    }

    @Test("launch restore shows the splash")
    func restoringShowsSplash() {
        #expect(BrowseUIGate.state(isBrowseReady: false, isRestoring: true,
                                   isSwitchingBackend: false, hasEverBeenBrowseReady: false) == .restoringSplash)
    }

    @Test("a genuinely signed-out user sees login")
    func signedOutShowsLogin() {
        #expect(BrowseUIGate.state(isBrowseReady: false, isRestoring: false,
                                   isSwitchingBackend: false, hasEverBeenBrowseReady: false) == .login)
        // Even after a previous session ended (signed out): not ready, not switching → login.
        #expect(BrowseUIGate.state(isBrowseReady: false, isRestoring: false,
                                   isSwitchingBackend: false, hasEverBeenBrowseReady: true) == .login)
    }
}
