#if os(tvOS) && DEBUG
import ObjectiveC
import UIKit

/// DEBUG-only remote-input evidence for TVUI-024. Logs, with an `TVEvidence:` prefix:
///
/// 1. every `UIPress` a `UIWindow` dispatches (proof events reach UIKit at all), plus the
///    focus system's current focused item at that moment;
/// 2. every focus-engine update (`UIFocusSystem.didUpdateNotification`), i.e. what the engine
///    focused after chrome controls appeared or vanished.
///
/// Combined with the SwiftUI-side `TVPlayerEvidence:` logs in `CustomPlayerChrome`, this
/// separates "event never reached the process", "event reached UIKit but not SwiftUI", and
/// "event reached SwiftUI". Installed by default in every DEBUG launch (opt out with
/// `--no-tv-input-evidence`); never in release builds.
@MainActor
enum TVInputEvidence {
    nonisolated static var isRequested: Bool {
        // Default-on for tvOS DEBUG builds (this whole file is `#if os(tvOS) && DEBUG`):
        // manual remote-testing sessions need press/focus evidence on every screen, not
        // just under the XCUI harness. `--no-tv-input-evidence` opts a launch out.
        !ProcessInfo.processInfo.arguments.contains("--no-tv-input-evidence")
    }

    private static var installed = false

    static func installIfNeeded() {
        guard isRequested, !installed else { return }
        installed = true

        let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:)))
        let swizzled = class_getInstanceMethod(UIWindow.self,
                                               #selector(UIWindow.labstream_evidenceSendEvent(_:)))
        if let original, let swizzled {
            method_exchangeImplementations(original, swizzled)
        }

        NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification,
                                               object: nil, queue: .main) { notification in
            // Delivered on the main queue; `assumeIsolated` re-enters the main actor for UIKit
            // access, so handing the userInfo dictionary across is thread-safe in practice.
            nonisolated(unsafe) let userInfo = notification.userInfo
            MainActor.assumeIsolated {
                let context = userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext
                let previous = context?.previouslyFocusedItem.map { describe($0) } ?? "nil"
                let next = context?.nextFocusedItem.map { describe($0) } ?? "nil"
                NSLog("%@", "TVEvidence: focus update \(previous) -> \(next)")
            }
        }
        NSLog("%@", "TVEvidence: recorder installed")
    }

    static func describe(_ item: UIFocusItem) -> String {
        let type = String(describing: Swift.type(of: item))
        if let view = item as? UIView {
            if let identifier = view.accessibilityIdentifier {
                return "\(type)(\(identifier))"
            }
            return "\(type)(label=\(view.accessibilityLabel ?? "nil"))"
        }
        // SwiftUI wraps focusables in non-UIView responder items; walk to the hosting view
        // so the log can say WHICH SwiftUI element holds focus, not just the wrapper type.
        if let responder = item as? UIResponder {
            var next = responder.next
            var hops = 0
            while let candidate = next, hops < 6 {
                if let view = candidate as? UIView {
                    let id = view.accessibilityIdentifier ?? view.accessibilityLabel
                        ?? String(describing: Swift.type(of: view))
                    return "\(type)→\(id)"
                }
                next = candidate.next
                hops += 1
            }
        }
        let raw = String(describing: item)
        return "\(type)[\(raw.prefix(120))]"
    }

    static func label(for pressType: UIPress.PressType) -> String {
        switch pressType {
        case .upArrow: "upArrow"
        case .downArrow: "downArrow"
        case .leftArrow: "leftArrow"
        case .rightArrow: "rightArrow"
        case .select: "select"
        case .menu: "menu"
        case .playPause: "playPause"
        case .pageUp: "pageUp"
        case .pageDown: "pageDown"
        case .tvRemoteOneTwoThree: "tvRemoteOneTwoThree"
        case .tvRemoteFourColors: "tvRemoteFourColors"
        @unknown default: "unknown(\(pressType.rawValue))"
        }
    }

    static func label(for phase: UIPress.Phase) -> String {
        switch phase {
        case .began: "began"
        case .changed: "changed"
        case .stationary: "stationary"
        case .ended: "ended"
        case .cancelled: "cancelled"
        @unknown default: "unknown"
        }
    }
}

extension UIWindow {
    @objc func labstream_evidenceSendEvent(_ event: UIEvent) {
        if let pressesEvent = event as? UIPressesEvent {
            let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem
                .map { TVInputEvidence.describe($0) } ?? "nil"
            for press in pressesEvent.allPresses {
                NSLog("%@", "TVEvidence: window press \(TVInputEvidence.label(for: press.type))"
                    + " \(TVInputEvidence.label(for: press.phase)) focused=\(focused)")
            }
        }
        // Swizzled: this call invokes the original implementation.
        labstream_evidenceSendEvent(event)
    }
}
#endif
