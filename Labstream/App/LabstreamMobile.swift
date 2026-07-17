#if os(iOS)
import Foundation
import SwiftUI

@main
struct LabstreamMobile: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var appModel: AppModel?
    @State private var authManager: AuthManager?
    @State private var downloadManager: DownloadManager?
    @State private var musicPlayer: MusicPlayerController?
    @State private var bootstrap = SessionBootstrap()
    // Mobile does not present immersive spaces, but the shared custom player/chrome expects
    // these app-lifetime stores in the environment. The iOS store implementations are inert.
    @State private var customCinemaSession = CustomCinemaSessionStore()
    @State private var realityTheaterSession = RealityTheaterSessionStore()

    init() {
        guard !AppLaunchMode.isUnitTestHost else {
            _appModel = State(initialValue: nil)
            _authManager = State(initialValue: nil)
            _downloadManager = State(initialValue: nil)
            _musicPlayer = State(initialValue: nil)
            return
        }
        AppStartup.prepareForLaunch()

        guard let services = AppServices.make() else { return }
        _appModel = State(initialValue: services.appModel)
        _authManager = State(initialValue: services.authManager)
        _downloadManager = State(initialValue: services.downloadManager)
        _musicPlayer = State(initialValue: services.musicPlayer)
    }

    var body: some Scene {
        WindowGroup {
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
    }

    private func recordScenePhase(_ phase: ScenePhase) {
        guard let downloadManager else { return }
        AppStartup.recordScenePhase(phase, downloadManager: downloadManager)
    }
}
#endif
