import PMSKit
import SwiftUI

extension EnvironmentValues {
    /// The foldable-iPhone pose every pose-aware layout reads (book and tabletop; every other
    /// state is `.flat`). The hinge rect is in the global (window) coordinate space: convert it
    /// with `DuoPoseLayout(input:contentRegion:)` using the consumer's own global frame.
    ///
    /// The iPhone/iPad shell installs the one live source (`providesDuoPose()`), fed from
    /// `reservedRegions(kind: .division)`, plus a DEBUG-only launch override. Surfaces never ask a
    /// hinge API themselves. visionOS, tvOS and macOS never install a source, so it stays `.flat`.
    @Entry var duoPose: DuoPoseInput = .flat

    /// Where the system places the vertical bar (iOS 27.1 `verticalBarEdge` trait), so shell
    /// chrome can tell a vertical column from horizontal bars without reading the idiom. `.none`
    /// on every platform and context without a vertical bar.
    @Entry var labstreamVerticalBarEdge: MobileShellLayoutPolicy.VerticalBarEdge = .none
}
