import SwiftUI

@main
struct PlexAVPApp: App {
    /// Bridges background `URLSession` relaunch events into the download pipeline so
    /// offline transfers can finish even when the app was suspended/terminated.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var customCinemaSession = CustomCinemaSessionStore()
    @State private var realityTheaterSession = RealityTheaterSessionStore()

    init() {
        // Register App Shortcuts at process start, per Apple guidance; Home refreshes
        // dynamic media parameters again after browse data loads.
        VisionPlexShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(customCinemaSession)
                .environment(realityTheaterSession)
        }
        .windowStyle(.plain)

        // Hidden #12 scaffold. This intentionally has no player-chrome or Settings entry point
        // until real-device RealityKit theater behavior is proven.
        ImmersiveSpace(id: RealityTheaterFeature.immersiveSpaceID) {
            RealityTheaterPrototypeView()
                .environment(realityTheaterSession)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        ImmersiveSpace(id: CustomCinemaMode.immersiveSpaceID) {
            CustomCinemaScaffoldView()
                .environment(customCinemaSession)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
