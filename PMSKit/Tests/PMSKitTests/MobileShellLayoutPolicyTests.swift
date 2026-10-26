import Foundation
import Testing
@testable import PMSKit

struct MobileShellLayoutPolicyTests {
    @Test func miniPlayerIsAnInsetBesideAVerticalBarAndAnAccessoryOtherwise() {
        #expect(MobileShellLayoutPolicy.miniPlayerPlacement(verticalBarEdge: .none) == .tabBottomAccessory)
        #expect(MobileShellLayoutPolicy.miniPlayerPlacement(verticalBarEdge: .leading) == .bottomSafeAreaInset)
        #expect(MobileShellLayoutPolicy.miniPlayerPlacement(verticalBarEdge: .trailing) == .bottomSafeAreaInset)
    }

    @Test func tabBarMinimizesOnlyAsABottomBar() {
        #expect(MobileShellLayoutPolicy.minimizesTabBarOnScroll(verticalBarEdge: .none))
        #expect(!MobileShellLayoutPolicy.minimizesTabBarOnScroll(verticalBarEdge: .trailing))
        #expect(!MobileShellLayoutPolicy.minimizesTabBarOnScroll(verticalBarEdge: .leading))
    }

    @Test(arguments: [
        // Folded portrait content region (~376 pt) and slab iPhone: no cap.
        (376.0, 0.0), (402.0, 0.0), (560.0, 0.0),
        // Unfolded upright (669 pt) and sideways content region (~855 pt).
        (669.0, 54.0), (855.0, 147.0),
        // iPad full screen.
        (1032.0, 236.0),
        // Unmeasured.
        (0.0, 0.0), (Double.nan, 0.0),
    ])
    func settingsFormIsCappedAndCentred(width: Double, margin: Double) {
        #expect(MobileShellLayoutPolicy.readableColumnMargin(
            containerWidth: width, maximumWidth: MobileShellLayoutPolicy.settingsFormMaximumWidth) == margin)
    }
}
