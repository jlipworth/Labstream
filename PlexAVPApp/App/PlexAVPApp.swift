import SwiftUI

@main
struct PlexAVPApp: App {
    /// Bridges background `URLSession` relaunch events into the download pipeline so
    /// offline transfers can finish even when the app was suspended/terminated.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.plain)
    }
}
