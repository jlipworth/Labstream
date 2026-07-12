import Testing
@testable import PMSKit

struct MobilePlayerOrientationRestorePolicyTests {
    @Test func portraitAndUnknownRestoreToPortrait() {
        #expect(MobilePlayerOrientationRestorePolicy.target(after: .portrait) == .portrait)
        #expect(MobilePlayerOrientationRestorePolicy.target(after: .unknown) == .portrait)
    }

    @Test func genuineLandscapeLaunchPreservesItsSide() {
        #expect(MobilePlayerOrientationRestorePolicy.target(after: .landscapeLeft) == .landscapeLeft)
        #expect(MobilePlayerOrientationRestorePolicy.target(after: .landscapeRight) == .landscapeRight)
    }
}
