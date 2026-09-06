import AppKit
import Observation
import SwiftUI

/// Native macOS lifecycle adapter.
///
/// iOS/visionOS background URLSession relaunch events still live in `AppDelegate`.
/// macOS does not use that UIKit callback; downloads continue to use the shared
/// app-container background session machinery, and future download agents can extend this
/// delegate if a Mac-specific handoff proves necessary.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // App Intents and Spotlight can arrive while the reusable main window is hidden. Route
        // activation through the same single-window owner before RootView consumes the request.
        SystemEntryRouter.shared.registerMainWindowActivation {
            MacMainWindowController.shared.activateMainWindow()
        }
        // SwiftUI can remember the main WindowGroup as ordered out across a normal quit/restart.
        // Request presentation on every cold launch; if the scene bridge has not mounted yet,
        // MacMainWindowController carries the request forward until it registers the NSWindow.
        MacMainWindowController.shared.presentMainWindowWhenRegistered()
        AppDiagnostics.record(.downloads, "app.mac_lifecycle", fields: [
            "phase": .label("did_finish_launching"),
        ])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Suppress default scene creation only when we actually presented a retained window.
        // A fresh process can have no restored scene at all; swallowing reopen in that state
        // leaves a live menu-bar-only app and prevents SwiftUI from creating its first window.
        return !MacMainWindowController.shared.activateMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDiagnostics.record(.downloads, "app.mac_lifecycle", fields: [
            "phase": .label("will_terminate"),
        ])
    }
}

/// Process-lifetime owner for the one macOS browse/player window.
///
/// Closing the main window intentionally means "hide", not "destroy": preserving the same
/// SwiftUI graph is what keeps a window-owned video player alive, while AppRuntime independently
/// keeps authentication, downloads, and music alive. A Dock reopen, system entry, or menu command
/// orders this exact window back to the front; no window selection heuristic is involved.
@MainActor
@Observable
final class MacMainWindowController: NSObject {
    enum Command: Equatable {
        case navigateBack
        case focusSearch
        case selectOffline
        case requestSignOut
        case requestSignOutAll
    }

    struct CommandRequest: Equatable, Identifiable {
        let id = UUID()
        let command: Command
    }

    static let shared = MacMainWindowController()
    static let mainWindowID = "main"

    @ObservationIgnored
    private(set) weak var mainWindow: NSWindow?
    @ObservationIgnored
    private var shouldActivateWhenRegistered = false
    /// Retained until RootView acknowledges each request. Commands therefore cannot disappear in
    /// the brief interval while the main scene is being restored or its task observers remount.
    private(set) var pendingCommands: [CommandRequest] = []

    func register(_ window: NSWindow) {
        mainWindow = window
        window.identifier = NSUserInterfaceItemIdentifier(Self.mainWindowID)
        window.isReleasedWhenClosed = false

        // NSWindow.performClose (including Command-W) dispatches through the standard close
        // button. Repointing that action lets us preserve the SwiftUI scene instead of trying to
        // reconstruct an active PlaybackController after its view graph has been dismantled.
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(hideMainWindow(_:))
        }

        if shouldActivateWhenRegistered {
            present(window)
        }
    }

    @discardableResult
    func activateMainWindow() -> Bool {
        // The SwiftUI registration view is the normal path. During the narrow launch interval
        // before that bridge mounts (or during state restoration), recover only the main scene
        // with our explicit identifier/title; never pick an arbitrary visible window such as
        // Settings.
        if mainWindow == nil,
           let restoredMainWindow = NSApp.windows.first(where: {
               $0.identifier?.rawValue == Self.mainWindowID || $0.title == "Labstream"
           }) {
            register(restoredMainWindow)
        }
        if let mainWindow {
            present(mainWindow)
            return true
        }

        shouldActivateWhenRegistered = true
        return false
    }

    /// Cold launch can complete before SwiftUI mounts the registration bridge. Unlike reopen,
    /// launch presentation must not adopt some other AppKit window from the test host or a
    /// transient scene; carry the request until this controller's main window registers.
    func presentMainWindowWhenRegistered() {
        if let mainWindow {
            present(mainWindow)
        } else {
            shouldActivateWhenRegistered = true
        }
    }

    private func present(_ window: NSWindow) {
        shouldActivateWhenRegistered = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func issue(_ command: Command) {
        pendingCommands.append(CommandRequest(command: command))
        activateMainWindow()
    }

    func consume(_ request: CommandRequest) {
        guard pendingCommands.first?.id == request.id else { return }
        pendingCommands.removeFirst()
    }

    @objc func hideMainWindow(_ sender: Any?) {
        let senderWindow = (sender as? NSButton)?.window
        (senderWindow ?? mainWindow)?.orderOut(nil)
    }
}

/// Captures the one retained NSWindow without making AppKit own the SwiftUI content hierarchy.
struct MacMainWindowRegistrationView: NSViewRepresentable {
    func makeNSView(context: Context) -> MacMainWindowRegistrationHostView {
        return MacMainWindowRegistrationHostView()
    }

    func updateNSView(_ nsView: MacMainWindowRegistrationHostView, context: Context) {
        nsView.registerWindowIfAvailable()
    }
}

final class MacMainWindowRegistrationHostView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWindowIfAvailable()
    }

    func registerWindowIfAvailable() {
        guard let window else { return }
        Task { @MainActor in
            MacMainWindowController.shared.register(window)
        }
    }
}
