#if os(tvOS)
import SwiftUI

@main
struct LabstreamTV: App {
    @State private var appModel: AppModel?
    @State private var authManager: AuthManager?
    @State private var downloadManager: DownloadManager?
    @State private var musicPlayer: MusicPlayerController?
    @State private var watchTogetherCoordinator = WatchTogetherCoordinator()
    @State private var bootstrap = SessionBootstrap()
    @State private var customCinemaSession = CustomCinemaSessionStore()
    @State private var realityTheaterSession = RealityTheaterSessionStore()

    init() {
        guard !AppLaunchMode.isUnitTestHost else { return }
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
                            watchTogetherCoordinator: watchTogetherCoordinator,
                            bootstrap: bootstrap)
                    .environment(customCinemaSession)
                    .environment(realityTheaterSession)
            } else {
                SecureStorageUnavailableView()
            }
        }
    }
}
#endif
