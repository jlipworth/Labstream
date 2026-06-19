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
        VisionPlayShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup(id: CustomCinemaMode.mainWindowID) {
            ContentView()
                .environment(customCinemaSession)
                .environment(realityTheaterSession)
        }
        .windowStyle(.plain)

        // Hidden #12 scaffold. This intentionally has no player-chrome or Settings entry point
        // until real-device RealityKit theater behavior is proven.
        ImmersiveSpace(id: RealityTheaterFeature.immersiveSpaceID) {
            RealityTheaterPrototypeView()
                .environment(customCinemaSession)
                .environment(realityTheaterSession)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .immersiveEnvironmentBehavior(.replace)
        .immersiveContentBrightness(.dark)
        .upperLimbVisibility(.hidden)

        ImmersiveSpace(id: CustomCinemaMode.immersiveSpaceID) {
            CustomCinemaScaffoldView()
                .environment(customCinemaSession)
                .environment(realityTheaterSession)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .immersiveEnvironmentBehavior(.replace)
        .immersiveContentBrightness(.dark)
        .upperLimbVisibility(.hidden)
    }
}
