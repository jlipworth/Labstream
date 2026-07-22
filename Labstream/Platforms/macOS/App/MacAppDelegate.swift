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
        AppDiagnostics.record(.downloads, "app.mac_lifecycle", fields: [
            "phase": .label("did_finish_launching"),
        ])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        MacMainWindowController.shared.activateMainWindow()
        // We already restored the one retained window. Suppress AppKit's default reopen path so
        // it cannot compete by asking SwiftUI to manufacture another scene/window.
        return false
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
    private var reopenMainWindow: (() -> Void)?

    /// Retained until RootView acknowledges each request. Commands therefore cannot disappear in
    /// the brief interval while the main scene is being restored or its task observers remount.
    private(set) var pendingCommands: [CommandRequest] = []

    func registerReopenAction(_ reopen: @escaping () -> Void) {
        reopenMainWindow = reopen
    }

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
    }

    @discardableResult
    func activateMainWindow() -> Bool {
        // The SwiftUI registration view is the normal path. During the narrow launch interval
        // before that bridge mounts (or during state restoration), recover only the Window scene
        // with our explicit identifier/title; never pick an arbitrary visible window such as
        // Settings.
        if mainWindow == nil,
           let restoredMainWindow = NSApp.windows.first(where: {
               $0.identifier?.rawValue == Self.mainWindowID || $0.title == "Labstream"
           }) {
            register(restoredMainWindow)
        }
        if let mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow.makeKeyAndOrderFront(nil)
            return true
        }

        guard let reopenMainWindow else { return false }
        NSApp.activate(ignoringOtherApps: true)
        reopenMainWindow()
        // `openWindow` mounts asynchronously. Registration normally focuses it as part of scene
        // creation; this follow-up covers frameworks that first create the NSWindow ordered out.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let mainWindow = self.mainWindow else { return }
            mainWindow.makeKeyAndOrderFront(nil)
        }
        return true
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

/// Captures the NSWindow created by SwiftUI's unique `Window` scene without making AppKit own
/// the content hierarchy.
struct MacMainWindowRegistrationView: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> MacMainWindowRegistrationHostView {
        registerReopenAction()
        return MacMainWindowRegistrationHostView()
    }

    func updateNSView(_ nsView: MacMainWindowRegistrationHostView, context: Context) {
        registerReopenAction()
        nsView.registerWindowIfAvailable()
    }

    private func registerReopenAction() {
        let openWindow = openWindow
        MacMainWindowController.shared.registerReopenAction {
            openWindow(id: MacMainWindowController.mainWindowID)
        }
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
