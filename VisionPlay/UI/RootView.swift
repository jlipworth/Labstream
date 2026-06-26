import SwiftUI
import PMSKit

/// Top-level authenticated UI: a tab strip of Home · Libraries · Search, plus an
/// Offline entry and a Settings control. Created once the user is signed in.
///
/// `RootView` receives the app-owned managers and passes them through the environment so
/// Detail/Offline can reach them.
struct RootView: View {
    let appModel: AppModel
    let authManager: AuthManager
    let downloadManager: DownloadManager
    let musicPlayer: MusicPlayerController

    @State private var selection: AppTab = .home
    /// Music tab's navigation path, lifted here so Now Playing's "go to
    /// artist/album" (which lives in a sheet, outside the stack) can push into it.
    @State private var musicPath = NavigationPath()
    /// Home tab's navigation path, lifted here so system entries (App Intents,
    /// Spotlight results — #24) can push a DetailView from outside the stack.
    @State private var homePath = NavigationPath()
    /// Libraries / Search paths, lifted so Cinema exit can return to the ORIGINATING
    /// browse tab's detail instead of always Home (#87) — same pattern as `homePath`.
    @State private var librariesPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    /// One-shot focus request for Cinema exits that came from an offline download. The Offline
    /// tab owns the list/row UI; RootView only foregrounds the tab and hands it the ratingKey to
    /// scroll/highlight after the window is recreated.
    @State private var offlineReturnRatingKey: String?
    @State private var systemEntryTask: Task<Void, Never>?
    @State private var systemEntryGeneration = 0

    enum AppTab: Hashable {
        case home, libraries, search, music, offline, settings

        /// Map to/from the backend-agnostic `CinemaTab` PMSKit uses for exit routing (#87).
        /// Only the three online browse tabs participate; other tabs have no Cinema origin.
        init?(_ cinemaTab: CinemaTab) {
            switch cinemaTab {
            case .home: self = .home
            case .libraries: self = .libraries
            case .search: self = .search
            }
        }

        var cinemaTab: CinemaTab? {
            switch self {
            case .home: return .home
            case .libraries: return .libraries
            case .search: return .search
            default: return nil
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            // Browse tabs are keyed on `appModel.activeBrowseSessionKey` so a backend/server/user
            // change or same-server re-auth tears down and rebuilds each stack — dropping any
            // pushed DetailView and resetting the root — instead of leaving a stale item from the
            // previous session mounted (#100/#136). `.onChange` below also clears the lifted paths
            // so the rebuilt stack does not re-push old snapshots. Offline/Settings are deliberately
            // NOT keyed: Downloads is cross-backend by design (each DownloadRecord carries its own
            // backendKind) and must persist across switches.
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack(path: $homePath) { HomeView() }
                    .environment(\.cinemaOriginTab, .home)
                    .id(appModel.activeBrowseSessionKey)
            }
            Tab("Libraries", systemImage: "rectangle.stack", value: AppTab.libraries) {
                NavigationStack(path: $librariesPath) { LibrariesView() }
                    .environment(\.cinemaOriginTab, .libraries)
                    .id(appModel.activeBrowseSessionKey)
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack(path: $searchPath) { SearchView() }
                    .environment(\.cinemaOriginTab, .search)
                    .id(appModel.activeBrowseSessionKey)
            }
            Tab("Music", systemImage: "music.note", value: AppTab.music) {
                NavigationStack(path: $musicPath) { MusicLibraryView() }
                    .id(appModel.activeBrowseSessionKey)
            }
            Tab("Offline", systemImage: "arrow.down.circle", value: AppTab.offline) {
                NavigationStack {
                    OfflineLibraryView(manager: downloadManager,
                                       focusedRatingKey: $offlineReturnRatingKey)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack { SettingsView(authManager: authManager) }
            }
        }
        // The mini player spans every tab so music keeps a visible handle while
        // browsing; it renders nothing when no track is loaded (#17). A bottom scene
        // ornament — NOT safeAreaInset, which a visionOS TabView simply never displays
        // (verified live: body ran with a current track, nothing rendered). The
        // ornament floats below the window glass, the platform idiom for transport.
        .ornament(attachmentAnchor: .scene(.bottom)) {
            MiniPlayerBar()
        }
        // Browse-session switch (#136): clear every lifted browse path so the rebuilt,
        // session-keyed NavigationStacks (see `.id(appModel.activeBrowseSessionKey)` above) do
        // not re-push a stale DetailView from the previous backend/server/user/session. The
        // `.id()` change tears the stack views down; clearing the external path bindings here
        // prevents the fresh stacks from immediately re-appending old snapshots. Offline's path is
        // intentionally left alone — Downloads is cross-backend (#100).
        .onChange(of: appModel.activeBrowseSessionKey) { _, _ in
            cancelSystemEntryTask()
            homePath = NavigationPath()
            librariesPath = NavigationPath()
            searchPath = NavigationPath()
            musicPath = NavigationPath()
            musicPlayer.stopIfBrowseSessionChanged()
        }
        // Now Playing's "go to artist/album": land on the Music tab and push.
        .onChange(of: musicPlayer.navigationRequest) { _, item in
            guard let item else { return }
            musicPlayer.navigationRequest = nil
            selection = .music
            // Push on the NEXT runloop tick: appending in the same transaction as
            // the tab switch can land before the stack is mounted, which leaves the
            // back button popping a stack the UI never showed.
            Task { @MainActor in
                musicPath.append(item)
            }
        }
        // System entries from App Intents / Spotlight (#24): same pattern as the
        // music navigation request above — observe the router, land on Home, push.
        .onChange(of: SystemEntryRouter.shared.pending) { _, route in
            guard let route else { return }
            handleSystemEntry(route)
        }
        // Cinema exit from an offline download (#87): land on the Offline tab and focus the
        // download with no server fetch. Separate channel from `pending` (which is online-only).
        .onChange(of: SystemEntryRouter.shared.offlinePending) { _, route in
            guard let route else { return }
            handleOfflineReturn(route)
        }
        .task {
            // Consume a route that arrived BEFORE RootView mounted (cold launch
            // from an intent/Spotlight: it was set while the restore splash was up).
            if let route = SystemEntryRouter.shared.pending {
                handleSystemEntry(route)
            }
            // `offlinePending` can also be set while the main window is absent during Cinema
            // teardown. `.onChange` only observes future mutations, so consume a pre-existing
            // offline return here just like the online/system-entry route.
            if let route = SystemEntryRouter.shared.offlinePending {
                handleOfflineReturn(route)
            }
        }
        .environment(appModel)
        .environment(downloadManager)
        .environment(musicPlayer)
    }

    // MARK: - System entries (App Intents / Spotlight, #24)

    /// Perform one system-entry route: land on the origin tab (Home for intents/Spotlight,
    /// the originating browse tab for a Cinema exit — #87), resolve the target to a full
    /// `MediaItem`, and push its DetailView. For "play" requests on a container
    /// (show/season) the tested `EpisodeResolver` walks down to the first episode
    /// so "Play <show>" actually plays something. Single-window by design: the
    /// player then presents as DetailView's `.fullScreenCover`, never a new scene.
    private func handleSystemEntry(_ route: SystemEntryRouter.Route) {
        let router = SystemEntryRouter.shared
        router.pending = nil
        systemEntryTask?.cancel()
        systemEntryGeneration += 1
        let generation = systemEntryGeneration
        let browseSessionKey = appModel.activeBrowseSessionKey
        // Land on the originating browse tab when Cinema exit recorded one (#87); intents/Spotlight
        // and the legacy fallback carry no origin tab and keep landing on Home.
        let targetTab = route.originTab.flatMap(AppTab.init) ?? .home
        selection = targetTab
        // Pop the target tab to root first so repeated entries don't stack stale details.
        resetPath(for: targetTab)
        systemEntryTask = Task { @MainActor in
            defer {
                if generation == systemEntryGeneration {
                    systemEntryTask = nil
                }
            }
            @MainActor
            func isCurrentRoute() -> Bool {
                if Task.isCancelled { return false }
                if generation != systemEntryGeneration { return false }
                return appModel.activeBrowseSessionKey == browseSessionKey
            }

            guard isCurrentRoute() else { return }
            let identity = appModel.identity
            let client = appModel.client

            // Resolve the target to a full item. Spotlight hits and Play/Open
            // intents arrive as a backend-scoped route key and are fetched fresh here;
            // `.item` is reserved for callers that JUST fetched the metadata
            // (Continue Watching), so no snapshot can grow stale in between.
            var item: MediaItem?
            switch route.target {
            case .item(let given):
                item = given
            case .routeKey(let routeKey):
                // Only Plex system-entry ids are currently indexed/routable. If a future
                // non-Plex id reaches this path before non-Plex system indexing is enabled,
                // do not resolve it against whichever backend happens to be active.
                guard routeKey.backend == .plex,
                      appModel.activeBackend.backendChoice == routeKey.backend,
                      let server = appModel.serverBaseURL,
                      let token = appModel.serverToken else { return }
                if let namespace = routeKey.serverNamespace,
                   namespace != BackendScopedMediaID.serverNamespace(server) {
                    return
                }
                let req = BrowseAPI.metadata(server: server, token: token,
                                             identity: identity, ratingKey: routeKey.ratingKey)
                item = (try? await client.send(req, as: MetadataResponse.self))?
                    .mediaContainer.metadata.first
                guard isCurrentRoute() else { return }
            }
            // Unresolvable (deleted item, stale index from another server): the
            // route quietly degrades to just foregrounding Home.
            guard var item else { return }

            var autoPlay = route.autoPlay
            if autoPlay, item.isContainer {
                guard let server = appModel.serverBaseURL,
                      let token = appModel.serverToken else {
                    autoPlay = false
                    await Task.yield()
                    guard isCurrentRoute() else { return }
                    appendPath(for: targetTab, item)
                    return
                }
                // "Play <show/season>": drill to the first episode leaf. Explicitly
                // @Sendable (capturing only Sendable values) so the closure may
                // cross from the main actor into the nonisolated resolver.
                let loadChildren: @Sendable (String) async throws -> [MediaItem] = { ratingKey in
                    let req = BrowseAPI.children(server: server, token: token,
                                                 identity: identity, ratingKey: ratingKey)
                    return try await client.send(req, as: MetadataResponse.self)
                        .mediaContainer.metadata
                }
                let leaf = try? await EpisodeResolver.resolveLeaf(from: item,
                                                                  loadChildren: loadChildren)
                guard isCurrentRoute() else { return }
                if let leaf {
                    item = leaf
                } else {
                    autoPlay = false // fall back to opening the container browser
                }
            }

            // Cinema exit calls `SystemEntryRouter.open(item:)` while the main window is being
            // recreated. Unlike Spotlight/intent rating-key routes, the `.item` case has no
            // network fetch delay, so appending in the same transaction as the `selection` /
            // path-reset above can land before the target NavigationStack is mounted on device.
            // Yield one turn, matching the proven Music-tab navigation pattern above, so Exit
            // Cinema reliably lands on the item's detail page (preserved per #87).
            await Task.yield()
            guard isCurrentRoute() else { return }
            if autoPlay, item.isPlayableLeaf, !item.isMusic {
                // Arm the handshake immediately before pushing; DetailView consumes it in its
                // `.task` and presents the player. The generation/session guard above keeps
                // stale system-entry tasks from arming autoplay for a route they won't append.
                router.requestAutoPlay(forRatingKey: item.ratingKey)
            }
            appendPath(for: targetTab, item)
        }
    }

    private func cancelSystemEntryTask() {
        systemEntryTask?.cancel()
        systemEntryTask = nil
        systemEntryGeneration += 1
    }

    /// Pop the lifted path for a browse tab to root (Home / Libraries / Search). Other tabs have
    /// no lifted path and need no reset.
    private func resetPath(for tab: AppTab) {
        switch tab {
        case .home: homePath = NavigationPath()
        case .libraries: librariesPath = NavigationPath()
        case .search: searchPath = NavigationPath()
        default: break
        }
    }

    /// Push an item's detail onto the lifted path for a browse tab (#87).
    private func appendPath(for tab: AppTab, _ item: MediaItem) {
        switch tab {
        case .home: homePath.append(item)
        case .libraries: librariesPath.append(item)
        case .search: searchPath.append(item)
        default: homePath.append(item)
        }
    }

    // MARK: - Offline return (Cinema exit from a download, #87)

    /// Land on the Offline tab after a Cinema exit that started from an offline download. The
    /// Offline tab row IS the offline item screen and plays straight from the row, so there is no
    /// detail to push and — critically — no server fetch. We foreground the Offline tab and hand
    /// the ratingKey to the list so the matching row is visible after window recreation.
    private func handleOfflineReturn(_ route: SystemEntryRouter.OfflineReturn) {
        SystemEntryRouter.shared.offlinePending = nil
        offlineReturnRatingKey = route.ratingKey
        selection = .offline
    }
}
