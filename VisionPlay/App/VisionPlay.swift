import Foundation
import PMSKit
import SwiftUI

@main
struct VisionPlay: App {
    /// Bridges background `URLSession` relaunch events into the download pipeline so
    /// offline transfers can finish even when the app was suspended/terminated.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // App-lifetime session + services. These used to be created inside `ContentView`, which meant
    // dismissing the main window (entering Cinema) destroyed the whole session and reopening it
    // (leaving Cinema) re-ran Plex server discovery/probing — the slow "Connecting…" splash. Owning
    // them on the `App` keeps the session alive across window teardown. Browse content stays fresh
    // because the browse views are still recreated with the window and re-fetch on appear.
    @State private var appModel: AppModel
    @State private var authManager: AuthManager
    @State private var downloadManager: DownloadManager
    @State private var musicPlayer: MusicPlayerController
    @State private var bootstrap = SessionBootstrap()
    @State private var customCinemaSession = CustomCinemaSessionStore()
    @State private var realityTheaterSession = RealityTheaterSessionStore()

    init() {
        // Register App Shortcuts at process start, per Apple guidance; Home refreshes
        // dynamic media parameters again after browse data loads.
        VisionPlayShortcuts.updateAppShortcutParameters()

        // Build a stable identity from the persisted client identifier. Version comes from the
        // bundle (#26) so the X-Plex-Version header can't silently drift from the marketing version.
        let keychain = KeychainStore()
        let identity = ClientIdentity(
            clientIdentifier: keychain.clientIdentifier(),
            product: "VisionPlay",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            deviceName: "Apple Vision Pro"
        )
        let model = AppModel(identity: identity, activeBackend: keychain.selectedBackend)
        _appModel = State(initialValue: model)
        _authManager = State(initialValue: AuthManager(appModel: model, keychain: keychain))
        _downloadManager = State(initialValue: DownloadManager(appModel: model))
        // Single long-lived music player (#17): the queue/audio session outlive any one screen.
        _musicPlayer = State(initialValue: MusicPlayerController(appModel: model))
    }

    var body: some Scene {
        WindowGroup(id: CustomCinemaMode.mainWindowID) {
            ContentView(appModel: appModel,
                        authManager: authManager,
                        downloadManager: downloadManager,
                        musicPlayer: musicPlayer,
                        bootstrap: bootstrap)
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
