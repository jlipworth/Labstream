#if os(visionOS)
import Foundation
import SwiftUI

@main
struct Labstream: App {
    /// Bridges background `URLSession` relaunch events into the download pipeline so
    /// offline transfers can finish even when the app was suspended/terminated.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    // App-lifetime session + services. These used to be created inside `ContentView`, which meant
    // dismissing the main window (entering Cinema) destroyed the whole session and reopening it
    // (leaving Cinema) re-ran Plex server discovery/probing — the slow "Connecting…" splash. Owning
    // them on the `App` keeps the session alive across window teardown. Browse content stays fresh
    // because the browse views are still recreated with the window and re-fetch on appear.
    @State private var appModel: AppModel?
    @State private var authManager: AuthManager?
    @State private var downloadManager: DownloadManager?
    @State private var musicPlayer: MusicPlayerController?
    @State private var bootstrap = SessionBootstrap()
    @State private var customCinemaSession = CustomCinemaSessionStore()
    @State private var realityTheaterSession = RealityTheaterSessionStore()

    init() {
        AppStartup.prepareForLaunch()

        guard let services = AppServices.make() else { return }
        _appModel = State(initialValue: services.appModel)
        _authManager = State(initialValue: services.authManager)
        _downloadManager = State(initialValue: services.downloadManager)
        _musicPlayer = State(initialValue: services.musicPlayer)
    }

    var body: some Scene {
        WindowGroup(id: CustomCinemaMode.mainWindowID) {
            if let appModel, let authManager, let downloadManager, let musicPlayer {
                ContentView(appModel: appModel,
                            authManager: authManager,
                            downloadManager: downloadManager,
                            musicPlayer: musicPlayer,
                            bootstrap: bootstrap)
                    .environment(customCinemaSession)
                    .environment(realityTheaterSession)
                    .task { recordScenePhase(scenePhase) }
                    .onChange(of: scenePhase) { _, newPhase in
                        recordScenePhase(newPhase)
                    }
            } else {
                SecureStorageUnavailableView()
            }
        }
        .windowStyle(.plain)

        // Hidden #12 scaffold. This intentionally has no player-chrome or Settings entry point
        // until real-device RealityKit theater behavior is proven.
        ImmersiveSpace(id: RealityTheaterFeature.immersiveSpaceID) {
            RealityTheaterPrototypeView()
                .environment(customCinemaSession)
                .environment(realityTheaterSession)
                .task { recordScenePhase(scenePhase) }
                .onChange(of: scenePhase) { _, newPhase in
                    recordScenePhase(newPhase)
                }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .immersiveEnvironmentBehavior(.replace)
        .immersiveContentBrightness(.dark)
        .upperLimbVisibility(.hidden)

        ImmersiveSpace(id: CustomCinemaMode.immersiveSpaceID) {
            CustomCinemaScaffoldView()
                .environment(customCinemaSession)
                .environment(realityTheaterSession)
                .task { recordScenePhase(scenePhase) }
                .onChange(of: scenePhase) { _, newPhase in
                    recordScenePhase(newPhase)
                }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .immersiveEnvironmentBehavior(.replace)
        .immersiveContentBrightness(.dark)
        .upperLimbVisibility(.hidden)
    }

    private func recordScenePhase(_ phase: ScenePhase) {
        guard let downloadManager else { return }
        AppStartup.recordScenePhase(phase, downloadManager: downloadManager)
    }
}

#endif
