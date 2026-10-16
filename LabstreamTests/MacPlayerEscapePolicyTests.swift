#if os(macOS)
import Testing
@testable import Labstream

@Suite("Mac player Escape policy")
struct MacPlayerEscapePolicyTests {
    struct EscapeCase: Sendable, CustomTestStringConvertible {
        let name: String
        let isMenuPresented: Bool
        let isFullScreen: Bool
        let hasCloseAction: Bool
        let expected: MacPlayerEscapeAction

        var testDescription: String { name }
    }

    @Test(arguments: [
        EscapeCase(name: "menuGetsFirstEscape",
                   isMenuPresented: true, isFullScreen: true, hasCloseAction: true,
                   expected: .closeMenu),
        EscapeCase(name: "fullscreenExitsBeforeThePlayerCloses",
                   isMenuPresented: false, isFullScreen: true, hasCloseAction: true,
                   expected: .exitFullScreen),
        EscapeCase(name: "playerClosesWhenNoMenuOrFullscreenIsActive",
                   isMenuPresented: false, isFullScreen: false, hasCloseAction: true,
                   expected: .closePlayer),
        EscapeCase(name: "escapePassesThroughWhenThePlayerHasNothingToDismiss",
                   isMenuPresented: false, isFullScreen: false, hasCloseAction: false,
                   expected: .passThrough),
    ])
    func escapeResolvesInPriorityOrder(_ escapeCase: EscapeCase) {
        #expect(macPlayerEscapeAction(isMenuPresented: escapeCase.isMenuPresented,
                                      isFullScreen: escapeCase.isFullScreen,
                                      hasCloseAction: escapeCase.hasCloseAction) == escapeCase.expected)
    }
}
#endif
