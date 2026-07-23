import PMSKit
import SwiftUI

@main
struct LabstreamMac: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    @State private var runtime: AppRuntime?

    init() {
        guard !AppLaunchMode.isUnitTestHost else {
            _runtime = State(initialValue: nil)
            return
        }
        AppStartup.prepareForLaunch()
        _runtime = State(initialValue: AppRuntime.make())
    }

    var body: some Scene {
        // The Mac product exposes one reusable browse/player surface. WindowGroup is retained for
        // reliable cold/direct-executable launch; the New Window command is removed below, and the
        // close button is intercepted by MacMainWindowController so the only scene is hidden and
        // reused rather than destroyed or duplicated.
        WindowGroup {
            if let runtime {
                ContentView(runtime: runtime)
                    // The source list can collapse natively at compact widths; 760 keeps the
                    // detail-only browse/player surfaces usable without enforcing the old
                    // touch-sized 980-point floor. Final acceptance is evidence-gated in #232.
                    .frame(minWidth: 760, minHeight: 640)
                    .reportsAppSceneActivity(runtime.sceneActivity, role: .mainWindow)
                    .background(MacMainWindowRegistrationView())
            } else {
                SecureStorageUnavailableView()
                    .background(MacMainWindowRegistrationView())
            }
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) { }
            if let runtime {
                CommandMenu("Navigate") {
                    Button("Back") {
                        MacMainWindowController.shared.issue(.navigateBack)
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!runtime.appModel.isAuthenticated)

                    Button("Search") {
                        MacMainWindowController.shared.issue(.focusSearch)
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!runtime.appModel.isAuthenticated)

                    Button("Offline") {
                        MacMainWindowController.shared.issue(.selectOffline)
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!runtime.appModel.isAuthenticated)
                }

                CommandMenu("Account") {
                    Button("Sign Out of \(runtime.appModel.activeBackend.displayName)") {
                        MacMainWindowController.shared.issue(.requestSignOut)
                    }
                        .disabled(!runtime.appModel.isAuthenticated)
                    if MediaBackendSignOutAllPresentation.shouldOfferAction(
                        for: runtime.authManager.savedAuthenticatedBackends
                    ) {
                        Button("Sign Out of All Backends") {
                            MacMainWindowController.shared.issue(.requestSignOutAll)
                        }
                    }
                }
            }
        }

        Settings {
            if let runtime {
                NavigationStack {
                    SettingsView(authManager: runtime.authManager,
                                 catalogRepository: runtime.libraryCatalogRepository)
                        .environment(runtime.appModel)
                        .environment(runtime.downloadManager)
                        .environment(runtime.musicPlayer)
                        .environment(\.artworkPipeline, runtime.artworkPipeline)
                }
                .formStyle(.grouped)
                .frame(minWidth: 680, minHeight: 560)
                .reportsAppSceneActivity(runtime.sceneActivity, role: .settings)
            } else {
                EmptyView()
            }
        }
    }
}
