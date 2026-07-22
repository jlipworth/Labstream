import Foundation
import SwiftUI

@main
struct Labstream: App {
    /// Bridges background `URLSession` relaunch events into the download pipeline so
    /// offline transfers can finish even when the app was suspended/terminated.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // App-lifetime session + services. These used to be created inside `ContentView`, which meant
    // dismissing the main window (entering Cinema) destroyed the whole session and reopening it
    // (leaving Cinema) re-ran Plex server discovery/probing — the slow "Connecting…" splash. Owning
    // them on the `App` keeps the session alive across window teardown. Browse content stays fresh
    // because the browse views are still recreated with the window and re-fetch on appear.
    @State private var runtime: AppRuntime?
    @State private var watchTogetherCoordinator = WatchTogetherCoordinator()
    @State private var customCinemaSession = CustomCinemaSessionStore()

    init() {
        AppStartup.prepareForLaunch()

        _runtime = State(initialValue: AppRuntime.make())
    }

    var body: some Scene {
        WindowGroup(id: CustomCinemaMode.mainWindowID) {
            if let runtime {
                ContentView(runtime: runtime)
                    .environment(customCinemaSession)
                    .environment(watchTogetherCoordinator)
                    .task {
                        watchTogetherCoordinator.configure(appModel: runtime.appModel)
                        watchTogetherCoordinator.startObservingSessionsIfNeeded()
                    }
                    .reportsAppSceneActivity(runtime.sceneActivity, role: .mainWindow)
            } else {
                SecureStorageUnavailableView()
            }
        }
        .windowStyle(.plain)

        ImmersiveSpace(id: CustomCinemaMode.immersiveSpaceID) {
            if let runtime {
                CustomCinemaScaffoldView()
                    .environment(customCinemaSession)
                    .environment(watchTogetherCoordinator)
                    .reportsAppSceneActivity(runtime.sceneActivity, role: .cinemaImmersive)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .immersiveEnvironmentBehavior(.replace)
        .immersiveContentBrightness(.dark)
        .upperLimbVisibility(.hidden)
    }

}
