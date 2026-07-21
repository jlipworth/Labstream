#if os(macOS)
import Testing
@testable import Labstream

@Suite("Mac player Escape policy")
struct MacPlayerEscapePolicyTests {
    @Test func menuGetsFirstEscape() {
        #expect(macPlayerEscapeAction(isMenuPresented: true,
                                      hasCloseAction: true) == .closeMenu)
    }

    @Test func playerClosesWhenNoMenuIsOpen() {
        #expect(macPlayerEscapeAction(isMenuPresented: false,
                                      hasCloseAction: true) == .closePlayer)
    }

    @Test func escapePassesThroughWithoutAPlayerCloseAction() {
        #expect(macPlayerEscapeAction(isMenuPresented: false,
                                      hasCloseAction: false) == .passThrough)
    }
}
#endif
