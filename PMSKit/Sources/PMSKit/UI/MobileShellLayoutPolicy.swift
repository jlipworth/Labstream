import Foundation

/// iPhone/iPad shell placement rules that depend on where the system puts its bars
/// (iPhone Duo design spec, "App shell and tab navigation" and global rule 10).
public enum MobileShellLayoutPolicy {
    /// Where the system places the vertical bar, as reported by the `verticalBarEdge` trait.
    /// `none` covers every context without a vertical bar: horizontal bars (an unfolded-upright
    /// iPhone Duo, every slab iPhone and iPad) and SDKs older than iOS 27.1.
    public enum VerticalBarEdge: String, Equatable, Sendable {
        case none, leading, trailing
    }

    /// How the mini player is hosted.
    public enum MiniPlayerPlacement: Equatable, Sendable {
        /// `tabViewBottomAccessory`: the system places it above the bottom tab capsule.
        case tabBottomAccessory
        /// `safeAreaInset(edge: .bottom)` inside each tab, so it is centred in the content region
        /// (never under the vertical column) and scroll viewports end above it.
        case bottomSafeAreaInset
    }

    /// With a vertical bar the app hosts the mini player itself, because whether the system places
    /// a bottom accessory beside the column has never been observed. With horizontal bars the
    /// system accessory is kept. Either way the bar is a bottom inset (Resolved decision 4).
    public static func miniPlayerPlacement(verticalBarEdge: VerticalBarEdge) -> MiniPlayerPlacement {
        verticalBarEdge == .none ? .tabBottomAccessory : .bottomSafeAreaInset
    }

    /// `tabBarMinimizeBehavior(.onScrollDown)` applies only to a bottom tab bar.
    public static func minimizesTabBarOnScroll(verticalBarEdge: VerticalBarEdge) -> Bool {
        verticalBarEdge == .none
    }

    /// The login content column cap.
    public static let loginColumnMaximumWidth: Double = 420

    /// The extra horizontal margin on each side that caps a text column at `maximumWidth` and
    /// centres it in a container of `containerWidth` (the content region, which already excludes
    /// the horizontal safe area). Zero when the container is no wider than the cap or unmeasured.
    public static func readableColumnMargin(containerWidth: Double, maximumWidth: Double) -> Double {
        guard containerWidth.isFinite, maximumWidth.isFinite, maximumWidth > 0,
              containerWidth > maximumWidth else { return 0 }
        return ((containerWidth - maximumWidth) / 2).rounded(.down)
    }
}
