#if !os(tvOS)
import PMSKit
import Testing
@testable import Labstream

@Suite(.serialized)
@MainActor
struct P7OfflineReturnTests {
    @Test func restrictedSurfaceFocusesAndAcknowledgesCinemaReturn() {
        let router = SystemEntryRouter()
        router.openOffline(ratingKey: "fixture-a")
        let binding = OfflineLaunchView.offlineFocusBinding(router: router)
        #expect(binding.wrappedValue == "fixture-a")
        #expect(router.offlinePending == nil)
        // No global Reconnect clear may destroy a newer return.
        router.openOffline(ratingKey: "fixture-b")
        #expect(router.offlinePending?.ratingKey == "fixture-b")
    }
    @Test func mountedFocusConsumesEachReturnOnce() {
        let router = SystemEntryRouter()
        let focus = OfflineReturnFocus()
        router.openOffline(ratingKey: "fixture-a")
        focus.consume(router: router)
        #expect(focus.ratingKey == "fixture-a")
        #expect(router.offlinePending == nil)
        router.openOffline(ratingKey: "fixture-b")
        focus.consume(router: router)
        #expect(focus.ratingKey == "fixture-b")
        #expect(router.offlinePending == nil)
        focus.consume(router: router)
        #expect(focus.ratingKey == "fixture-b")
    }

    @Test func acknowledgingOldReturnCannotEraseNewerReturn() throws {
        let router = SystemEntryRouter.shared
        let saved = router.offlinePending
        defer { router.offlinePending = saved }
        router.openOffline(ratingKey: "fixture-a")
        let old = try #require(router.offlinePending)
        router.openOffline(ratingKey: "fixture-b")
        let current = try #require(router.offlinePending)
        let navigation = RootNavigationCoordinator()
        navigation.consumeOfflineReturn(old)
        #expect(router.offlinePending?.id == current.id)
    }
}
#endif
