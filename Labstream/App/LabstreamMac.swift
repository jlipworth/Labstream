#if os(macOS)
import SwiftUI

@main
struct LabstreamMac: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var appModel: AppModel?
    @State private var authManager: AuthManager?
    @State private var downloadManager: DownloadManager?
    @State private var musicPlayer: MusicPlayerController?
    @State private var bootstrap = SessionBootstrap()
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
        let services = AppServices.make()
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
                    .frame(minWidth: 980, minHeight: 680)
                    .task { recordScenePhase(scenePhase) }
                    .onChange(of: scenePhase) { _, newPhase in
                        recordScenePhase(newPhase)
                    }
            } else {
                EmptyView()
            }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            if let authManager {
                CommandMenu("Navigate") {
                    Button("Back") {
                        NotificationCenter.default.post(name: .labstreamMacNavigateBack, object: nil)
                    }
                    .keyboardShortcut("[", modifiers: .command)

                    Button("Search") {
                        NotificationCenter.default.post(name: .labstreamMacFocusSearch, object: nil)
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    Button("Offline") {
                        NotificationCenter.default.post(name: .labstreamMacSelectOffline, object: nil)
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                }

                CommandMenu("Account") {
                    Button("Sign Out") { authManager.signOut() }
                        .disabled(!(appModel?.isAuthenticated ?? false))
                }
            }
        }

        Settings {
            if let appModel, let authManager, let downloadManager, let musicPlayer {
                NavigationStack {
                    SettingsView(authManager: authManager)
                        .environment(appModel)
                        .environment(downloadManager)
                        .environment(musicPlayer)
                }
                .formStyle(.grouped)
                .frame(minWidth: 680, minHeight: 560)
            } else {
                EmptyView()
            }
        }
    }

    private func recordScenePhase(_ phase: ScenePhase) {
        guard let downloadManager else { return }
        AppStartup.recordScenePhase(phase, downloadManager: downloadManager)
    }
}

extension Notification.Name {
    static let labstreamMacNavigateBack = Notification.Name("LabstreamMacNavigateBack")
    static let labstreamMacFocusSearch = Notification.Name("LabstreamMacFocusSearch")
    static let labstreamMacSelectOffline = Notification.Name("LabstreamMacSelectOffline")
}
#endif
