import SwiftUI
import UIKit

/// Reports a Select press made while focus is on the tab bar.
///
/// On tvOS the tab bar changes tabs as focus moves across it, so the `TabView` selection
/// binding is never written when the user presses Select on the tab that is already showing
/// (measured in the simulator, 2026-11-15): the system only drops focus back into the page.
/// This view attaches a tap recognizer to its window, restricted to the Select press type,
/// notes at press-down whether focus is inside the tab bar, and calls `onReselect` when that
/// press completes. It neither delays nor cancels the system's own handling.
struct TVTabReselectMonitor: UIViewRepresentable {
    var onReselect: () -> Void

    func makeUIView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.isUserInteractionEnabled = false
        view.onReselect = onReselect
        return view
    }

    func updateUIView(_ view: MonitorView, context: Context) {
        view.onReselect = onReselect
    }

    static func dismantleUIView(_ view: MonitorView, coordinator: ()) {
        view.detach()
    }

    final class MonitorView: UIView, UIGestureRecognizerDelegate {
        var onReselect: (() -> Void)?
        private var recognizer: UITapGestureRecognizer?
        private weak var attachedWindow: UIWindow?
        private var pressBeganInTabBar = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            attachedWindow = window
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(selected(_:)))
            recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
            recognizer.allowedTouchTypes = []
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        func detach() {
            if let recognizer { attachedWindow?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            attachedWindow = nil
        }

        @objc private func selected(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, pressBeganInTabBar else { return }
            pressBeganInTabBar = false
            onReselect?()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive press: UIPress) -> Bool {
            pressBeganInTabBar = Self.focusIsInTabBar(of: attachedWindow)
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        private static func focusIsInTabBar(of window: UIWindow?) -> Bool {
            guard let window,
                  let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem else { return false }
            var environment: UIFocusEnvironment? = focused
            while let current = environment {
                if current is UITabBar { return true }
                environment = current.parentFocusEnvironment
            }
            return false
        }
    }
}
