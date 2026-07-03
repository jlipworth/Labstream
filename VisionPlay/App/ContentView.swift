import CoreSpotlight
import SwiftUI
import PMSKit

/// Main-window root. The `App` owns the long-lived state objects; this view switches between
/// restore, login, and browse UI based on `appModel.isBrowseReady` and passes the app-owned
/// services down to `RootView`.
///
/// Ownership (per the module contract): `AppModel` holds identity/token/server + the shared
/// client; it deliberately does NOT own the player, downloads, or auth controller.
struct ContentView: View {
    // Owned by the `App`, not this view, so they survive the main window being dismissed (entering
    // Cinema) and reopened (leaving Cinema). That is what makes leaving Cinema instant instead of
    // re-running server discovery. Browse content does NOT become stale: the browse views are still
    // recreated with the window and re-fetch on appear (HomeView keys its reload on the window-
    // lifetime load state), so newly-added media still shows up.
    let appModel: AppModel
    let authManager: AuthManager
    let downloadManager: DownloadManager
    let musicPlayer: MusicPlayerController

    /// Launch bootstrap state, also app-lifetime so a reopened window never re-runs the one-time
    /// session restore. While restoring we show a neutral splash — NOT `LoginView` — because a saved
    /// token takes a moment to resolve a reachable server (discovery + connection probing), during
    /// which `isBrowseReady` is still false. Showing the Sign-In button in that window let the user
    /// start a second OAuth flow whose web sheet then orphaned itself over the restored UI.
    let bootstrap: SessionBootstrap

    var body: some View {
        // #90: the gate is centralized in `BrowseUIGate` so the "switch must not bounce the
        // browse UI" invariant holds for ANY backend (not just Plex via the refreshServers
        // field-preservation carve-out). An already-ready browse UI stays mounted through a
        // switch; a genuinely signed-out user still gets the splash/login.
        Group {
            switch BrowseUIGate.state(isBrowseReady: appModel.isBrowseReady,
                                      isRestoring: bootstrap.isRestoring,
                                      isSwitchingBackend: appModel.isSwitchingBackend,
                                      hasEverBeenBrowseReady: bootstrap.hasEverBeenBrowseReady) {
            case .browse:
                RootView(appModel: appModel,
                         authManager: authManager,
                         downloadManager: downloadManager,
                         musicPlayer: musicPlayer)
            case .restoringSplash:
                RestoringSessionView()
            case .login:
                LoginView(authManager: authManager)
                    .environment(appModel)
            }
        }
        .onAppear {
            // #90: seed the "has shown browse UI" flag for the case where we're ALREADY
            // browse-ready at first render (a window reopened after Cinema, or an instant
            // restore) — `.onChange(of:isBrowseReady)` only fires on a transition, so it
            // wouldn't otherwise catch a UI that was ready from the start.
            if appModel.isBrowseReady { bootstrap.hasEverBeenBrowseReady = true }
        }
        .task {
            // Register the live state objects for out-of-app entry points (App
            // Intents, Spotlight) BEFORE restoring, so an intent that launched the
            // app can await `ensureBrowseReady()` against the real instances.
            SystemEntryRouter.shared.register(appModel: appModel, authManager: authManager)
            // Restore exactly once per app launch. The session objects are app-lifetime, so a window
            // reopened after Cinema already holds a live, connected session — re-running discovery
            // here would needlessly re-show "Connecting…" and re-probe the server.
            guard !bootstrap.didStartRestore else { return }
            bootstrap.didStartRestore = true
            await authManager.restoreSession()
            bootstrap.isRestoring = false
            downloadManager.resumePendingServerPrepDownloads()
            downloadManager.scheduleServerPrepResumeRetries()
            downloadManager.teardownOrphanedEncodersOnLaunch()
#if DEBUG
            let debugArgs = ProcessInfo.processInfo.arguments
            if let idx = debugArgs.firstIndex(of: "--vp-probe-backend"),
               debugArgs.indices.contains(idx + 1),
               let backend = MediaBackendKind(rawValue: debugArgs[idx + 1]),
               backend != appModel.activeBackend {
                await authManager.switchBackend(backend)
            }

            await DebugRawURLPlaybackProbe.runIfRequested()
            await DebugJellyfinPlaybackProbe.runIfRequested(appModel: appModel)
            await DebugEmbyPlaybackProbe.runIfRequested(appModel: appModel)
            await DebugPlexPlaybackProbe.runIfRequested(appModel: appModel)
            await DebugPlexDownloadProbe.runIfRequested(appModel: appModel, downloadManager: downloadManager)
            await DebugEmbyDownloadProbe.runIfRequested(appModel: appModel, downloadManager: downloadManager)
            await DebugJellyfinDownloadProbe.runIfRequested(appModel: appModel, downloadManager: downloadManager)
#endif
        }
        // A Spotlight result was tapped: stash the ratingKey with the router. If
        // we're still on the restore splash the route waits there until RootView
        // mounts and consumes it.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  !id.isEmpty else { return }
            SystemEntryRouter.shared.open(routeKey: SpotlightIndexer.routeKey(from: id), autoPlay: false)
        }
        // Sign-out: the music player outlives RootView, so without this music would
        // keep playing over the login screen with stale credentials (#17).
        .onChange(of: appModel.isBrowseReady) { _, ready in
            if !ready {
                musicPlayer.stop()
            } else {
                // #90: remember we've shown the browse UI so a later backend switch keeps it
                // mounted (BrowseUIGate) instead of bouncing through the restore splash.
                bootstrap.hasEverBeenBrowseReady = true
                downloadManager.resumePendingServerPrepDownloads()
                downloadManager.scheduleServerPrepResumeRetries()
            }
        }
        .onChange(of: appModel.activeBackend) { _, backend in
            if backend == .plex, appModel.isBrowseReady {
                downloadManager.resumePendingServerPrepDownloads()
            }
        }
        // #136: queued music `MediaItem`s are only meaningful for the backend/server/user/session
        // that produced them. Clear playback when the active browse session changes so Next/remote
        // controls never resolve a stale queue against a different server or backend.
        .onChange(of: appModel.activeBrowseSessionKey) { oldKey, newKey in
            guard oldKey != newKey else { return }
            musicPlayer.stopIfBrowseSessionChanged()
        }
        // #84: a backend switch just re-restored another lane's saved session, so a job
        // that couldn't resume earlier (its lane was inactive) can now run. `switchBackend`'s
        // restore path raises `isSwitchingBackend` while it re-resolves the target lane and
        // lowers it when done; on that true→false edge (and only once the lane is actually
        // live) re-run the per-backend resume + encoder sweep so the newly-restored backend
        // picks up its own pending server-prep rows and clears any encoder it leaked earlier.
        // Both helpers resolve each row against its OWN backend lane, so this never disturbs a
        // foreign-backend job that is mid-flight. (A brand-new sign-in is already covered by
        // the launch `.task` / reattach resume path above.)
        .onChange(of: appModel.isSwitchingBackend) { wasSwitching, isSwitching in
            guard wasSwitching, !isSwitching, appModel.isBrowseReady else { return }
            downloadManager.resumePendingServerPrepDownloads()
            downloadManager.scheduleServerPrepResumeRetries()
            downloadManager.teardownOrphanedEncodersOnLaunch()
        }
    }
}

/// App-lifetime launch bootstrap state. Lives above the window (owned by the `App`) so dismissing
/// and reopening the main window — which entering and leaving Cinema does — never re-triggers the
/// one-time session restore.
@MainActor
@Observable
final class SessionBootstrap {
    /// True until the launch-time `restoreSession()` finishes.
    var isRestoring = true
    /// Set once the restore has been kicked off, so a reopened window skips it.
    var didStartRestore = false
    /// #90: true once the browse UI has been mounted at least once this app run. Lets
    /// `BrowseUIGate` keep an already-ready UI mounted through a backend switch instead of
    /// bouncing to the restore splash. App-lifetime (on `SessionBootstrap`) so it survives the
    /// main window being dismissed/reopened by entering/leaving Cinema.
    var hasEverBeenBrowseReady = false
}

/// Neutral launch splash shown while a saved session is being restored (token read +
/// server discovery/probing), so the Sign-In screen never flashes for an already-signed-in
/// user.
private struct RestoringSessionView: View {
    var body: some View {
        VStack(spacing: DS.Space.lg) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview(windowStyle: .plain) {
    let identity = ClientIdentity(clientIdentifier: "preview",
                                  product: "VisionPlay",
                                  version: "0.0.0",
                                  deviceName: "Apple Vision Pro")
    let model = AppModel(identity: identity)
    ContentView(appModel: model,
                authManager: AuthManager(appModel: model),
                downloadManager: DownloadManager(appModel: model),
                musicPlayer: MusicPlayerController(appModel: model),
                bootstrap: SessionBootstrap())
        .environment(CustomCinemaSessionStore())
        .environment(RealityTheaterSessionStore())
}
