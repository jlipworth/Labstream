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
        Group {
            if appModel.isBrowseReady {
                RootView(appModel: appModel,
                         authManager: authManager,
                         downloadManager: downloadManager,
                         musicPlayer: musicPlayer)
            } else if bootstrap.isRestoring || appModel.isSwitchingBackend {
                RestoringSessionView()
            } else {
                LoginView(authManager: authManager)
                    .environment(appModel)
            }
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
#if DEBUG
            await DebugJellyfinPlaybackProbe.runIfRequested(appModel: appModel)
            await DebugEmbyPlaybackProbe.runIfRequested(appModel: appModel)
            await DebugPlexDownloadProbe.runIfRequested(appModel: appModel, downloadManager: downloadManager)
#endif
        }
        // A Spotlight result was tapped: stash the ratingKey with the router. If
        // we're still on the restore splash the route waits there until RootView
        // mounts and consumes it.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  !id.isEmpty else { return }
            SystemEntryRouter.shared.open(ratingKey: SpotlightIndexer.ratingKey(from: id), autoPlay: false)
        }
        // Sign-out: the music player outlives RootView, so without this music would
        // keep playing over the login screen with stale credentials (#17).
        .onChange(of: appModel.isBrowseReady) { _, ready in
            if !ready { musicPlayer.stop() }
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
