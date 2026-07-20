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
    // Watch Together is visionOS-only. Shared app/root initializers still carry the
    // coordinator, so macOS owns an inert instance and never observes group sessions.
    @State private var watchTogetherCoordinator = WatchTogetherCoordinator()
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
                    // The source list can collapse natively at compact widths; 760 keeps the
                    // detail-only browse/player surfaces usable without enforcing the old
                    // touch-sized 980-point floor. Final acceptance is evidence-gated in #232.
                    .frame(minWidth: 760, minHeight: 640)
                    .task { recordScenePhase(scenePhase) }
                    .onChange(of: scenePhase) { _, newPhase in
                        recordScenePhase(newPhase)
                    }
            } else {
                SecureStorageUnavailableView()
            }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            if appModel != nil {
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
                    Button("Sign Out") {
                        NotificationCenter.default.post(name: .labstreamMacRequestSignOut, object: nil)
                    }
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
    static let labstreamMacRequestSignOut = Notification.Name("LabstreamMacRequestSignOut")
}
#endif
