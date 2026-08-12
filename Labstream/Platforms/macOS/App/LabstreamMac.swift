import AppKit
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
        let runtime = AppRuntime.make()
        _runtime = State(initialValue: runtime)
        #if DEBUG
        if let runtime {
            DebugUITestLaunchConfiguration.configure(appModel: runtime.appModel,
                                                     bootstrap: runtime.bootstrap)
            DebugMacAgentFixtureWindow.scheduleFallbackIfNeeded(runtime: runtime)
        }
        #endif
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

#if DEBUG
/// Xcode 27 can launch a fresh isolated macOS bundle without asking SwiftUI to instantiate its
/// restorable WindowGroup. The normal scene remains authoritative; this fallback mounts the same
/// shipping ContentView only when the fixture launch still has no registered window after settle.
@MainActor
private enum DebugMacAgentFixtureWindow {
    private static var retainedWindow: NSWindow?

    static func scheduleFallbackIfNeeded(runtime: AppRuntime) {
        guard DebugUITestLaunchConfiguration.usesBrowseFixture else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard MacMainWindowController.shared.mainWindow == nil else { return }
            let root = ContentView(runtime: runtime)
                .frame(minWidth: 760, minHeight: 640)
                .reportsAppSceneActivity(runtime.sceneActivity, role: .mainWindow)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Labstream"
            window.contentViewController = NSHostingController(rootView: root)
            window.center()
            retainedWindow = window
            MacMainWindowController.shared.register(window)
            MacMainWindowController.shared.activateMainWindow()
        }
    }
}
#endif
