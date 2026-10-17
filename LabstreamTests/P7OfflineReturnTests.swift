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
        withKnownIssue("P7 red pin: 10") {
            #expect(binding.wrappedValue == "fixture-a")
            #expect(router.offlinePending == nil)
        }
        // No global Reconnect clear may destroy a newer return.
        router.openOffline(ratingKey: "fixture-b")
        #expect(router.offlinePending?.ratingKey == "fixture-b")
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
        withKnownIssue("P7 red pin: 10-identity") {
            #expect(router.offlinePending?.id == current.id)
        }
    }
}
#endif
