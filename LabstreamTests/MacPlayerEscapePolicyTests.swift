#if os(macOS)
import Testing
@testable import Labstream

@Suite("Mac player Escape policy")
struct MacPlayerEscapePolicyTests {
    @Test func menuGetsFirstEscape() {
        #expect(macPlayerEscapeAction(isMenuPresented: true,
                                      isFullScreen: true,
                                      hasCloseAction: true) == .closeMenu)
    }

    @Test func fullscreenExitsBeforeThePlayerCloses() {
        #expect(macPlayerEscapeAction(isMenuPresented: false,
                                      isFullScreen: true,
                                      hasCloseAction: true) == .exitFullScreen)
    }

    @Test func playerClosesWhenNoMenuOrFullscreenIsActive() {
        #expect(macPlayerEscapeAction(isMenuPresented: false,
                                      isFullScreen: false,
                                      hasCloseAction: true) == .closePlayer)
    }

    @Test func escapePassesThroughWhenThePlayerHasNothingToDismiss() {
        #expect(macPlayerEscapeAction(isMenuPresented: false,
                                      isFullScreen: false,
                                      hasCloseAction: false) == .passThrough)
    }
}
#endif
