import SwiftUI

@main
struct PlexAVPApp: App {
    /// Bridges background `URLSession` relaunch events into the download pipeline so
    /// offline transfers can finish even when the app was suspended/terminated.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var customCinemaSession = CustomCinemaSessionStore()

    init() {
        // Register App Shortcuts at process start, per Apple guidance; Home refreshes
        // dynamic media parameters again after browse data loads.
        VisionPlexShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(customCinemaSession)
        }
        .windowStyle(.plain)

        ImmersiveSpace(id: CustomCinemaMode.immersiveSpaceID) {
            CustomCinemaScaffoldView()
                .environment(customCinemaSession)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
