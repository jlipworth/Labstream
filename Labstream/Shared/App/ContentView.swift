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
    let runtime: AppRuntime

    private var appModel: AppModel { runtime.appModel }
    private var authManager: AuthManager { runtime.authManager }
    #if !os(tvOS)
    private var downloadManager: DownloadManager { runtime.downloadManager }
    #endif
    private var musicPlayer: MusicPlayerController { runtime.musicPlayer }
    private var bootstrap: SessionBootstrap { runtime.bootstrap }

    var body: some View {
        #if os(tvOS) && DEBUG
        // Deterministic tvOS UI-test fixtures (season browser, player chrome, system keyboard)
        // bypass the restore/login/browse gate entirely; production launches never set one.
        switch TVUITestLaunchConfiguration.fixtureKind {
        case .season:
            NavigationStack {
                ContainerBrowserView(container: TVUIFixtureCatalog.seasonContainer)
            }
            .environment(appModel)
        case .player:
            TVPlayerFixtureView()
                .environment(musicPlayer)
                .environment(appModel)
        case .keyboard:
            TVKeyboardFixtureView()
        case .keyboardShell:
            TVKeyboardShellFixtureView()
        case .browse, nil:
            mainBody
        }
        #else
        mainBody
        #endif
    }

    private var mainBody: some View {
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
                RootView(runtime: runtime)
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
            SystemEntryRouter.shared.register(
                appModel: appModel,
                authManager: authManager,
                libraryCatalogRepository: runtime.libraryCatalogRepository)
            // Restore exactly once per app launch. The session objects are app-lifetime, so a window
            // reopened after Cinema already holds a live, connected session — re-running discovery
            // here would needlessly re-show "Connecting…" and re-probe the server.
            guard !bootstrap.didStartRestore else { return }
            bootstrap.didStartRestore = true
            await authManager.restoreSession()
            bootstrap.isRestoring = false
            #if !os(tvOS)
            // Restore the selected browse lane first, then hydrate only inactive backends that
            // currently own durable active work. Paused/failed/completed rows remain cold until
            // their explicit resume, retry, or side-asset dispatch edge.
            let inactiveDownloadBackends = Set(
                downloadManager.records.lazy
                    .filter { $0.status.isActiveWork }
                    .map { DownloadJobSnapshot(record: $0).backend }
            ).subtracting([appModel.activeBackend])
            for backend in inactiveDownloadBackends.sorted(by: { $0.rawValue < $1.rawValue }) {
                _ = await authManager.hydrateSavedSessionForDownloads(backend: backend)
            }
            downloadManager.resumePendingServerPrepDownloads()
            downloadManager.rehydrateMissingOptionalSideAssetsForCompletedRows(
                reason: "session_restored")
            downloadManager.scheduleServerPrepResumeRetries()
            downloadManager.teardownOrphanedEncodersOnLaunch()
            #endif
#if DEBUG
            let debugArgs = ProcessInfo.processInfo.arguments
            if let idx = debugArgs.firstIndex(of: "--vp-probe-backend"),
               debugArgs.indices.contains(idx + 1),
               let backend = MediaBackendKind(rawValue: debugArgs[idx + 1]),
               backend != appModel.activeBackend {
                await authManager.switchBackend(backend)
            }

            await DebugRawURLPlaybackProbe.runIfRequested()
            await DebugPlexBrowseProbe.runIfRequested(appModel: appModel)
            await DebugJellyfinPlaybackProbe.runIfRequested(appModel: appModel)
            await DebugEmbyPlaybackProbe.runIfRequested(appModel: appModel)
            await DebugPlexPlaybackProbe.runIfRequested(appModel: appModel)
            #if !os(tvOS)
            await DebugPlexDownloadProbe.runIfRequested(appModel: appModel, downloadManager: downloadManager)
            await DebugEmbyDownloadProbe.runIfRequested(appModel: appModel, downloadManager: downloadManager)
            await DebugJellyfinDownloadProbe.runIfRequested(appModel: appModel, downloadManager: downloadManager)
            #endif
#endif
        }
        // A Spotlight result was tapped: stash the ratingKey with the router. If
        // we're still on the restore splash the route waits there until RootView
        // mounts and consumes it.
        #if !os(tvOS)
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  !id.isEmpty else { return }
            SystemEntryRouter.shared.open(routeKey: SpotlightIndexer.routeKey(from: id), autoPlay: false)
        }
        #endif
        // Sign-out: the music player outlives RootView, so without this music would
        // keep playing over the login screen with stale credentials (#17).
        .onChange(of: appModel.isBrowseReady) { _, ready in
            if !ready {
                musicPlayer.stop()
            } else {
                // #90: remember we've shown the browse UI so a later backend switch keeps it
                // mounted (BrowseUIGate) instead of bouncing through the restore splash.
                bootstrap.hasEverBeenBrowseReady = true
                #if !os(tvOS)
                downloadManager.resumePendingServerPrepDownloads()
                downloadManager.rehydrateMissingOptionalSideAssetsForCompletedRows(
                    reason: "backend_ready")
                downloadManager.scheduleServerPrepResumeRetries()
                #endif
            }
        }
        .onChange(of: appModel.activeBackend) { _, backend in
            #if !os(tvOS)
            if backend == .plex, appModel.isBrowseReady {
                downloadManager.resumePendingServerPrepDownloads()
            }
            #endif
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
            #if !os(tvOS)
            guard wasSwitching, !isSwitching, appModel.isBrowseReady else { return }
            downloadManager.resumePendingServerPrepDownloads()
            downloadManager.rehydrateMissingOptionalSideAssetsForCompletedRows(
                reason: "backend_switched")
            downloadManager.scheduleServerPrepResumeRetries()
            downloadManager.teardownOrphanedEncodersOnLaunch()
            #endif
        }
    }
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

#if os(visionOS)
#Preview(windowStyle: .plain) {
    let identity = PlatformClientIdentity.make(clientIdentifier: "preview", version: "0.0.0")
    let model = AppModel(identity: identity)
    let artworkPipeline = ArtworkPipeline()
    let runtime = AppRuntime(appModel: model,
                             authManager: AuthManager(appModel: model),
                             downloadManager: DownloadManager(appModel: model),
                             sceneActivity: AppSceneActivity { _ in },
                             musicPlayer: MusicPlayerController(appModel: model,
                                                                artworkPipeline: artworkPipeline),
                             artworkPipeline: artworkPipeline,
                             bootstrap: SessionBootstrap())
    let watchTogetherCoordinator = WatchTogetherCoordinator()
    ContentView(runtime: runtime)
        .environment(CustomCinemaSessionStore())
        .environment(watchTogetherCoordinator)
}
#else
#Preview {
    let identity = PlatformClientIdentity.make(clientIdentifier: "preview", version: "0.0.0")
    let model = AppModel(identity: identity)
    let artworkPipeline = ArtworkPipeline()
    #if os(tvOS)
    let runtime = AppRuntime(appModel: model,
                             authManager: AuthManager(appModel: model),
                             musicPlayer: MusicPlayerController(appModel: model,
                                                                artworkPipeline: artworkPipeline),
                             artworkPipeline: artworkPipeline,
                             bootstrap: SessionBootstrap())
    #else
    let runtime = AppRuntime(appModel: model,
                             authManager: AuthManager(appModel: model),
                             downloadManager: DownloadManager(appModel: model),
                             sceneActivity: AppSceneActivity { _ in },
                             musicPlayer: MusicPlayerController(appModel: model,
                                                                artworkPipeline: artworkPipeline),
                             artworkPipeline: artworkPipeline,
                             bootstrap: SessionBootstrap())
    #endif
    ContentView(runtime: runtime)
}
#endif
