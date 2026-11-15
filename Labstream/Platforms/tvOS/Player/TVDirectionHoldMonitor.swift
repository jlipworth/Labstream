import SwiftUI
import UIKit

/// Reports a held Left/Right remote press as a stream of repeats.
///
/// SwiftUI's `onMoveCommand` fires once per press on tvOS: holding the remote's direction
/// button does not repeat it (measured in the simulator and on a physical Apple TV, #458), so
/// a scrubber built on it alone needs one click per step. This view attaches two long-press
/// recognizers to its window, restricted to the arrow press types, and calls `onRepeat` on a
/// timer from the moment a hold is recognized until the button is released. The first step of
/// the press still comes from `onMoveCommand`; the recognizers neither delay nor cancel it.
struct TVDirectionHoldMonitor: UIViewRepresentable {
    var onRepeat: (MoveCommandDirection) -> Void

    func makeUIView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.isUserInteractionEnabled = false
        view.onRepeat = onRepeat
        return view
    }

    func updateUIView(_ view: MonitorView, context: Context) {
        view.onRepeat = onRepeat
    }

    static func dismantleUIView(_ view: MonitorView, coordinator: ()) {
        view.detach()
    }

    final class MonitorView: UIView, UIGestureRecognizerDelegate {
        /// Seconds a direction must stay down before it counts as a hold.
        static let holdDelay: TimeInterval = 0.35
        /// Seconds between repeats while held.
        static let repeatInterval: TimeInterval = 0.12

        var onRepeat: ((MoveCommandDirection) -> Void)?
        private var recognizers: [UILongPressGestureRecognizer] = []
        private weak var attachedWindow: UIWindow?
        private var timer: Timer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            attachedWindow = window
            recognizers = [(UIPress.PressType.leftArrow, #selector(heldLeft(_:))),
                           (UIPress.PressType.rightArrow, #selector(heldRight(_:)))]
                .map { pressType, action in
                    let recognizer = UILongPressGestureRecognizer(target: self, action: action)
                    recognizer.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
                    recognizer.allowedTouchTypes = []
                    recognizer.minimumPressDuration = Self.holdDelay
                    recognizer.cancelsTouchesInView = false
                    recognizer.delaysTouchesBegan = false
                    recognizer.delaysTouchesEnded = false
                    recognizer.delegate = self
                    window.addGestureRecognizer(recognizer)
                    return recognizer
                }
        }

        func detach() {
            stop()
            for recognizer in recognizers { attachedWindow?.removeGestureRecognizer(recognizer) }
            recognizers = []
            attachedWindow = nil
        }

        @objc private func heldLeft(_ recognizer: UILongPressGestureRecognizer) {
            handle(recognizer, direction: .left)
        }

        @objc private func heldRight(_ recognizer: UILongPressGestureRecognizer) {
            handle(recognizer, direction: .right)
        }

        private func handle(_ recognizer: UILongPressGestureRecognizer,
                            direction: MoveCommandDirection) {
            switch recognizer.state {
            case .began:
                stop()
                onRepeat?(direction)
                let timer = Timer(timeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onRepeat?(direction) }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            case .ended, .cancelled, .failed:
                stop()
            default:
                break
            }
        }

        private func stop() {
            timer?.invalidate()
            timer = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
