import Testing
@testable import Labstream

struct NowPlayingPresentationStateTests {
    @Test func plainPresentationOpensAtTop() {
        var state = NowPlayingPresentationState()

        state.present()

        #expect(state.isPresented)
        #expect(!state.scrollToQueue)
    }

    @Test func queuePresentationResetsThroughSharedDismissalPath() {
        var state = NowPlayingPresentationState()
        state.present(scrollToQueue: true)

        state.dismiss()

        #expect(!state.isPresented)
        #expect(!state.scrollToQueue)
    }
}
