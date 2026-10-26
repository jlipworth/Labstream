import PMSKit
import SwiftUI
import UIKit

/// Invisible view in the full-screen player that reports the player's own window scene and every
/// scene-geometry change (size, size classes, display) to the orientation coordinator, and records
/// a bounded `player.geometry_change` diagnostic for each one.
///
/// This is what lets a playback session survive an iPhone Duo fold or unfold, an iPad window
/// resize, or a rotation as a layout-only event: the coordinator re-decides the landscape lock from
/// the new geometry, and the diagnostics let a fold run be judged without reading raw logs. The
/// view never touches playback state. On iOS 27.1 it also attaches a read-only
/// `UIHingeInteraction` whose status is recorded for diagnostics only (iPhone Duo design spec,
/// Player tabletop mechanism): the player's book / tabletop pose comes solely from the shell's
/// `\.duoPose` (the `reservedRegions` division region, or the DEBUG override). It never reaches
/// layout or playback.
struct MobilePlayerSceneGeometryReader: UIViewRepresentable {
    let coordinator: MobilePlayerOrientationCoordinator

    func makeUIView(context: Context) -> MobilePlayerSceneGeometryView {
        let view = MobilePlayerSceneGeometryView()
        view.coordinator = coordinator
        return view
    }

    func updateUIView(_ uiView: MobilePlayerSceneGeometryView, context: Context) {
        uiView.coordinator = coordinator
    }
}

final class MobilePlayerSceneGeometryView: UIView {
    weak var coordinator: MobilePlayerOrientationCoordinator?

    private struct Sample: Equatable {
        let sceneSize: CGSize
        let horizontal: UIUserInterfaceSizeClass
        let vertical: UIUserInterfaceSizeClass
        let screenSize: CGSize
    }

    private var lastSample: Sample?
    private var hingeStatus = "unavailable"
    private var changeCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
            (view: MobilePlayerSceneGeometryView, _: UITraitCollection) in
            view.reportIfChanged()
        }
        installHingeProbe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        lastSample = nil
        reportIfChanged()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportIfChanged()
    }

    private func installHingeProbe() {
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak self] _, update in
                guard let self else { return }
                let status = Self.label(update.hinge?.status)
                guard status != self.hingeStatus else { return }
                self.hingeStatus = status
                AppDiagnostics.record(.playback, "player.hinge_status", fields: [
                    "status": .label(status),
                ])
            }
            addInteraction(interaction)
        }
    }

    @available(iOS 27.1, *)
    private static func label(_ status: UIHinge.Status?) -> String {
        switch status {
        case .none: "unavailable"
        case .unknown?: "unknown"
        case .closed?: "closed"
        case .partiallyOpen?: "partially_open"
        case .fullyOpen?: "fully_open"
        @unknown default: "other"
        }
    }

    private func reportIfChanged() {
        guard let scene = window?.windowScene else { return }
        let sample = Sample(sceneSize: scene.effectiveGeometry.coordinateSpace.bounds.size,
                            horizontal: traitCollection.horizontalSizeClass,
                            vertical: traitCollection.verticalSizeClass,
                            screenSize: scene.screen.bounds.size)
        guard sample != lastSample else { return }
        let isFirst = lastSample == nil
        lastSample = sample
        changeCount += 1
        // Re-deciding the lock can widen the mask or request a rotation; never do that inside the
        // layout pass that reported the change.
        let changeIndex = changeCount
        DispatchQueue.main.async { [weak self, weak scene] in
            guard let self, let scene else { return }
            self.record(sample: sample, scene: scene, isFirst: isFirst, changeIndex: changeIndex)
        }
    }

    private func record(sample: Sample, scene: UIWindowScene, isFirst: Bool, changeIndex: Int) {
        let decision = coordinator?.playerSceneGeometryDidChange(scene)
        let insets = window?.safeAreaInsets ?? .zero
        var fields: [String: DiagnosticFieldValue] = [
            "reason": .label(isFirst ? "attach" : "change"),
            "change_index": .int(changeIndex),
            "scene_w": .int(Int(sample.sceneSize.width.rounded())),
            "scene_h": .int(Int(sample.sceneSize.height.rounded())),
            "screen_w": .int(Int(sample.screenSize.width.rounded())),
            "screen_h": .int(Int(sample.screenSize.height.rounded())),
            "h_class": .label(Self.label(sample.horizontal)),
            "v_class": .label(Self.label(sample.vertical)),
            "orientation": .label(Self.label(scene.effectiveGeometry.interfaceOrientation)),
            "display_class": .label(coordinator?.displayClass(of: scene)?.rawValue ?? "unmeasured"),
            "lock_decision": .label(decision?.rawValue ?? "no_session"),
            "activation": .label(Self.label(scene.activationState)),
            "hinge": .label(hingeStatus),
            "safe_t": .int(Int(insets.top.rounded())),
            "safe_l": .int(Int(insets.left.rounded())),
            "safe_b": .int(Int(insets.bottom.rounded())),
            "safe_r": .int(Int(insets.right.rounded())),
        ]
        if #available(iOS 27.1, *) {
            fields["vertical_bar_edge"] = .label(Self.label(traitCollection.verticalBarEdge))
        }
        AppDiagnostics.record(.playback, "player.geometry_change", fields: fields)
    }

    private static func label(_ sizeClass: UIUserInterfaceSizeClass) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        case .unspecified: "unspecified"
        @unknown default: "other"
        }
    }

    private static func label(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portrait_upside_down"
        case .landscapeLeft: "landscape_left"
        case .landscapeRight: "landscape_right"
        case .unknown: "unknown"
        @unknown default: "other"
        }
    }

    private static func label(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .foregroundActive: "foreground_active"
        case .foregroundInactive: "foreground_inactive"
        case .background: "background"
        case .unattached: "unattached"
        @unknown default: "other"
        }
    }

    @available(iOS 27.1, *)
    private static func label(_ edge: UIVerticalBarEdge) -> String {
        switch edge {
        case .unspecified: "unspecified"
        case .leading: "leading"
        case .trailing: "trailing"
        @unknown default: "other"
        }
    }
}
