#if os(macOS)
import AppKit

/// Native macOS lifecycle adapter.
///
/// iOS/visionOS background URLSession relaunch events still live in `AppDelegate`.
/// macOS does not use that UIKit callback; downloads continue to use the shared
/// app-container background session machinery, and future download agents can extend this
/// delegate if a Mac-specific handoff proves necessary.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDiagnostics.record(.downloads, "app.mac_lifecycle", fields: [
            "phase": .label("did_finish_launching"),
        ])
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDiagnostics.record(.downloads, "app.mac_lifecycle", fields: [
            "phase": .label("will_terminate"),
        ])
    }
}
#endif
