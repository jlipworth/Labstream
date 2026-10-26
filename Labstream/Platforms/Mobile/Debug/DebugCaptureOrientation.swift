import SwiftUI
import UIKit

extension View {
    /// DEBUG capture route `--ui-testing-orientation landscape-left|landscape-right|portrait`
    /// (any `--ui-testing` launch): asks this window's scene for that interface orientation.
    ///
    /// The iPhone Duo simulator on Xcode 27.1 ignores `XCUIDevice.orientation`, so folded-landscape
    /// layouts (both camera rotations) need an app-side request to get headless evidence. A no-op
    /// otherwise, and compiled out of Release.
    @ViewBuilder
    func debugCaptureOrientation() -> some View {
        #if DEBUG
        if let mask = DebugCaptureOrientation.requestedMask {
            background { DebugCaptureOrientation.Requester(mask: mask).allowsHitTesting(false) }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
@MainActor
enum DebugCaptureOrientation {
    nonisolated static let flag = "--ui-testing-orientation"

    static var requestedMask: UIInterfaceOrientationMask? {
        switch DebugUITestLaunchConfiguration.argumentValue(flag, in: ProcessInfo.processInfo.arguments) {
        case "landscape-left": .landscapeLeft
        case "landscape-right": .landscapeRight
        case "portrait": .portrait
        default: nil
        }
    }

    struct Requester: UIViewRepresentable {
        let mask: UIInterfaceOrientationMask

        func makeUIView(context: Context) -> RequesterView { RequesterView(mask: mask) }
        func updateUIView(_ uiView: RequesterView, context: Context) {}
    }

    final class RequesterView: UIView {
        private let orientationMask: UIInterfaceOrientationMask
        private var requested = false

        init(mask: UIInterfaceOrientationMask) {
            self.orientationMask = mask
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !requested, let scene = window?.windowScene else { return }
            requested = true
            // Pin the app mask first so the scene does not rotate back to the device orientation.
            AppDelegate.supportedInterfaceOrientations = orientationMask
            window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationMask)) { error in
                NSLog("%@", "DebugCaptureOrientation request failed: \(error.localizedDescription)")
            }
        }
    }
}
#endif
