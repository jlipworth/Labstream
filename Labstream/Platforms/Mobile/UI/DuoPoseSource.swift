import PMSKit
import SwiftUI
import UIKit

extension View {
    /// Installs the shell's single foldable-pose source and vertical-bar-edge source into the
    /// environment (`\.duoPose`, `\.labstreamVerticalBarEdge`).
    ///
    /// - The pose comes from the supported geometry API only: the active
    ///   `reservedRegions(kind: .division)` region, classified by its strip shape. A read-only
    ///   `UIHingeInteraction` stays diagnostics-only in the player.
    /// - In DEBUG builds, `LABSTREAM_DEBUG_DUO_POSE=book|tabletop` (launch environment, or
    ///   `--labstream-debug-duo-pose <value>`) replaces the live pose with a hinge strip derived
    ///   from the current bounds, so book and tabletop layouts get headless screenshot evidence.
    ///   Release never compiles the override.
    func providesDuoPose() -> some View {
        modifier(DuoPoseSourceModifier())
    }
}

private struct DuoPoseSourceModifier: ViewModifier {
    @State private var pose: DuoPoseInput = .flat
    @State private var verticalBarEdge: MobileShellLayoutPolicy.VerticalBarEdge = .none

    func body(content: Content) -> some View {
        content
            .environment(\.duoPose, pose)
            .environment(\.labstreamVerticalBarEdge, verticalBarEdge)
            .background {
                ZStack {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: DuoPoseSourceModifier.pose(in: proxy), initial: true) { _, newPose in
                                guard newPose != pose else { return }
                                pose = newPose
                                DuoPoseSourceModifier.record(newPose)
                            }
                    }
                    VerticalBarEdgeReader(edge: $verticalBarEdge)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    private static func pose(in proxy: GeometryProxy) -> DuoPoseInput {
        let bounds = proxy.frame(in: .global)
        #if DEBUG
        if let override = DuoPoseDebugOverride.requested {
            return override.input(in: bounds)
        }
        #endif
        guard #available(iOS 27.1, *) else { return .flat }
        // Region frames are in the reader's local space; the reader fills the window, so offset
        // by its global origin to publish window coordinates.
        guard let division = proxy.reservedRegions(kind: .division).first(where: \.isActive) else {
            return .flat
        }
        return DuoPoseInput.classify(division: division.frame.offsetBy(dx: bounds.minX, dy: bounds.minY))
    }

    private static func record(_ pose: DuoPoseInput) {
        var fields: [String: DiagnosticFieldValue] = ["pose": .label(label(pose))]
        if let hinge = pose.hinge {
            fields["hinge_x"] = .int(Int(hinge.minX.rounded()))
            fields["hinge_y"] = .int(Int(hinge.minY.rounded()))
            fields["hinge_w"] = .int(Int(hinge.width.rounded()))
            fields["hinge_h"] = .int(Int(hinge.height.rounded()))
        }
        #if DEBUG
        if DuoPoseDebugOverride.requested != nil {
            AppDiagnostics.record(.settingsUI, "duo.pose_override", fields: fields)
            return
        }
        #endif
        AppDiagnostics.record(.settingsUI, "duo.pose_change", fields: fields)
    }

    private static func label(_ pose: DuoPoseInput) -> String {
        switch pose {
        case .flat: "flat"
        case .book: "book"
        case .tabletop: "tabletop"
        }
    }
}

#if DEBUG
private enum DuoPoseDebugOverride {
    static let requested: DuoPoseOverride? = DuoPoseOverride.parse(
        environment: ProcessInfo.processInfo.environment,
        arguments: ProcessInfo.processInfo.arguments)
}
#endif

/// Bridges the iOS 27.1 `verticalBarEdge` trait (no SwiftUI environment equivalent exists in the
/// 27.1 SDK). The trait reports the system's preferred edge for the vertical bar and is
/// unspecified wherever no vertical bar is used (horizontal bars, older SDKs).
private struct VerticalBarEdgeReader: UIViewRepresentable {
    @Binding var edge: MobileShellLayoutPolicy.VerticalBarEdge

    func makeUIView(context: Context) -> VerticalBarEdgeView {
        let view = VerticalBarEdgeView()
        view.onChange = { newEdge in
            if edge != newEdge { edge = newEdge }
        }
        return view
    }

    func updateUIView(_ uiView: VerticalBarEdgeView, context: Context) {
        uiView.onChange = { newEdge in
            if edge != newEdge { edge = newEdge }
        }
        uiView.report()
    }
}

private final class VerticalBarEdgeView: UIView {
    var onChange: ((MobileShellLayoutPolicy.VerticalBarEdge) -> Void)?
    private var lastReported: MobileShellLayoutPolicy.VerticalBarEdge?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        if #available(iOS 27.1, *) {
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
                (view: VerticalBarEdgeView, _: UITraitCollection) in
                view.report()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        report()
    }

    func report() {
        guard window != nil else { return }
        let edge = currentEdge
        guard edge != lastReported else { return }
        lastReported = edge
        // Never mutate SwiftUI state inside the update or layout pass that observed the change.
        DispatchQueue.main.async { [weak self] in self?.onChange?(edge) }
    }

    private var currentEdge: MobileShellLayoutPolicy.VerticalBarEdge {
        guard #available(iOS 27.1, *) else { return .none }
        switch traitCollection.verticalBarEdge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .unspecified: return .none
        @unknown default: return .none
        }
    }
}
