#if os(iOS)
import Foundation
import SwiftUI

@main
struct LabstreamMobile: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var appModel: AppModel
    @State private var authManager: AuthManager
    @State private var downloadManager: DownloadManager
    @State private var musicPlayer: MusicPlayerController
    @State private var bootstrap = SessionBootstrap()
    // Mobile does not present immersive spaces, but the shared custom player/chrome expects
    // these app-lifetime stores in the environment. The iOS store implementations are inert.
    @State private var customCinemaSession = CustomCinemaSessionStore()
    @State private var realityTheaterSession = RealityTheaterSessionStore()

    init() {
        LabstreamShortcuts.updateAppShortcutParameters()
        MetricKitDiagnostics.shared.register()

        let keychain = KeychainStore()
        let identity = PlatformClientIdentity.make(clientIdentifier: keychain.clientIdentifier())
        let model = AppModel(identity: identity, activeBackend: keychain.selectedBackend)
        _appModel = State(initialValue: model)
        _authManager = State(initialValue: AuthManager(appModel: model, keychain: keychain))
        _downloadManager = State(initialValue: DownloadManager(appModel: model))
        _musicPlayer = State(initialValue: MusicPlayerController(appModel: model))
    }

    var body: some Scene {
        WindowGroup {
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
        }
    }

    private func recordScenePhase(_ phase: ScenePhase) {
        let label: String
        switch phase {
        case .active: label = "active"
        case .inactive: label = "inactive"
        case .background: label = "background"
        @unknown default: label = "unknown"
        }
        AppDiagnostics.record(.downloads, "app.scene_phase", fields: [
            "phase": .label(label),
        ])
        downloadManager.noteAppScenePhase(label)
    }
}
#endif
