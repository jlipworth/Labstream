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
    let watchTogetherCoordinator: WatchTogetherCoordinator

    @State private var selection: AppTab = .home
    /// Last non-Search tab, so clearing the dedicated Search surface returns to the
    /// browse chrome the user came from instead of leaving them stranded on the
    /// search role tab with the normal top/tab chrome still hidden.
    @State private var lastNonSearchSelection: AppTab = .home
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
    /// Shared with the ornament-backed mini player so visionOS can treat a tap in
    /// the system sheet's dimmed surround exactly like its explicit close button.
    @State private var nowPlayingPresentation = NowPlayingPresentationState()
    /// One-shot focus request for Cinema exits that came from an offline download. The Offline
    /// tab owns the list/row UI; RootView only foregrounds the tab and hands it the ratingKey to
    /// scroll/highlight after the window is recreated.
    @State private var offlineReturnRatingKey: String?
    @State private var systemEntryTask: Task<Void, Never>?
    @State private var systemEntryGeneration = 0
    /// Incremented by the ⌘F shortcut to route to Search and (re-)focus its field.
    @State private var searchFocusRequest = 0
    #if os(macOS)
    @State private var macPlayerPresenter = MacPlayerPresentationStore()
    @State private var macColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var macColumnVisibilityBeforePlayer: NavigationSplitViewVisibility = .all
    #endif
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Compact-width Settings presentation (see `usesCompactTabSet`).
    @State private var showsSettingsSheet = false
    #endif

    enum AppTab: Hashable, CaseIterable {
        case home, libraries, search, music, offline, settings

        var title: String {
            switch self {
            case .home: "Home"
            case .libraries: "Libraries"
            case .search: "Search"
            case .music: "Music"
            case .offline: "Offline"
            case .settings: "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .home: "house"
            case .libraries: "rectangle.stack"
            case .search: "magnifyingglass"
            case .music: "music.note"
            case .offline: "arrow.down.circle"
            case .settings: "gearshape"
            }
        }

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
        rootContent
        // A custom visionOS presentation must make the obscured hierarchy inert;
        // otherwise gaze/pinch can fall through even when an overlay is visible.
        .allowsHitTesting(!nowPlayingPresentation.isPresented)
        .overlay {
            #if os(visionOS)
            if nowPlayingPresentation.isPresented {
                ZStack {
                    // Use a real full-window control, not a gesture on a decorative
                    // Color: visionOS may pass the latter through to an underlying
                    // button. The root content is also inert while this is present.
                    Button {
                        nowPlayingPresentation.dismiss()
                    } label: {
                        Rectangle()
                            .fill(Color.black.opacity(0.28))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Now Playing")
                    .zIndex(0)

                    VisionNowPlayingPanel(
                        scrollToQueue: nowPlayingPresentation.scrollToQueue,
                        onDismiss: { nowPlayingPresentation.dismiss() }
                    )
                    .zIndex(1)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
            #endif
        }
        .background {
            // App-wide ⌘F → Search tab, then focus its field. A zero-size, invisible
            // button keeps the shortcut in the responder chain without occupying layout;
            // works with an iPad hardware keyboard and the visionOS Magic Keyboard.
            Button("Search", action: focusSearch)
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            #if os(macOS)
            // Mac convention: Escape backs out of a pushed content/detail submenu when
            // there is no higher-priority surface active. Player chrome owns Escape while
            // playback is presented, and sheets/dialogs keep their own cancel handling.
            Button("Back", action: macNavigateBack)
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!canMacNavigateBack)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            #endif
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
        .onChange(of: selection) { _, newSelection in
            if newSelection != .search {
                lastNonSearchSelection = newSelection
            }
            #if os(iOS)
            // Selecting the dedicated Search role should behave like a search action,
            // not merely navigate to an idle screen: reveal the keyboard and place the
            // insertion point in SearchView's searchable field.
            if newSelection == .search {
                searchFocusRequest += 1
            }
            #endif
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
        #if os(visionOS)
        .sheet(isPresented: Binding(
            get: { watchTogetherCoordinator.joinPrompt != nil },
            set: { if !$0, watchTogetherCoordinator.joinPrompt != nil { watchTogetherCoordinator.declineIncoming() } }
        )) {
            WatchTogetherJoinView()
        }
        #endif
        .environment(appModel)
        .environment(downloadManager)
        .environment(musicPlayer)
        .environment(watchTogetherCoordinator)
    }

    @ViewBuilder
    private var rootContent: some View {
        #if os(macOS)
        macRootContent
        #elseif os(iOS)
        mobileRootContent
        #else
        visionRootContent
        #endif
    }

    #if os(macOS)
    private var macRootContent: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $macColumnVisibility) {
                List(selection: $selection) {
                    Section("Browse") {
                        macSidebarRow(.home)
                        macSidebarRow(.libraries)
                        macSidebarRow(.search)
                    }
                    Section("Media") {
                        macSidebarRow(.music)
                        macSidebarRow(.offline)
                    }
                    Section("Status") {
                        macSidebarStatusRow(macBackendStatusTitle,
                                            systemImage: appModel.isBrowseReady ? "checkmark.circle" : "exclamationmark.circle")
                        macSidebarStatusRow(macDownloadStatusTitle,
                                            systemImage: "arrow.down.circle")
                    }
                }
                .navigationTitle("Labstream")
                .frame(minWidth: 220)
            } detail: {
                macTabContent(for: selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationSplitViewStyle(.balanced)
            .safeAreaInset(edge: .bottom) {
                if musicPlayer.current != nil, !macPlayerPresenter.isPresented {
                    MiniPlayerBar(presentation: $nowPlayingPresentation)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.regularMaterial)
                }
            }
            .toolbar {
                if !macPlayerPresenter.isPresented {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: focusSearch) {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .labelStyle(.iconOnly)
                        .controlSize(.regular)
                        .help("Search")

                        Button { selection = .offline } label: {
                            Label("Offline", systemImage: "arrow.down.circle")
                        }
                        .labelStyle(.iconOnly)
                        .controlSize(.regular)
                        .help("Offline")
                    }
                }
            }

            if let presentation = macPlayerPresenter.presentation {
                presentation.content
                    .id(presentation.contentID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .ignoresSafeArea()
                    .transition(.opacity.combined(with: .scale(scale: 0.998)))
                    .zIndex(10)
            }
        }
        .background {
            MacWindowToolbarVisibilityController(hidesToolbar: macPlayerPresenter.isPresented)
                .frame(width: 0, height: 0)
        }
        .environment(\.macPlayerPresentationStore, macPlayerPresenter)
        .animation(.easeInOut(duration: 0.16), value: macPlayerPresenter.isPresented)
        .onChange(of: macPlayerPresenter.isPresented) { _, isPresented in
            updateMacNavigationChrome(forPlayerPresentation: isPresented)
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .labstreamMacNavigateBack) {
                macNavigateBack()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .labstreamMacFocusSearch) {
                focusSearch()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .labstreamMacSelectOffline) {
                guard !macPlayerPresenter.isPresented else { continue }
                selection = .offline
            }
        }
    }

    private func updateMacNavigationChrome(forPlayerPresentation isPresented: Bool) {
        if isPresented {
            if macColumnVisibility != .detailOnly {
                macColumnVisibilityBeforePlayer = macColumnVisibility
            }
            macColumnVisibility = .detailOnly
        } else {
            macColumnVisibility = macColumnVisibilityBeforePlayer
        }
    }

    private var canMacNavigateBack: Bool {
        guard !macPlayerPresenter.isPresented else { return false }
        switch selection {
        case .home:
            return !homePath.isEmpty
        case .libraries:
            return !librariesPath.isEmpty
        case .search:
            return !searchPath.isEmpty
        case .music:
            return !musicPath.isEmpty
        case .offline, .settings:
            return false
        }
    }

    private func macNavigateBack() {
        guard canMacNavigateBack else { return }
        switch selection {
        case .home:
            homePath.removeLast()
        case .libraries:
            librariesPath.removeLast()
        case .search:
            searchPath.removeLast()
        case .music:
            musicPath.removeLast()
        case .offline, .settings:
            break
        }
    }

    private func macSidebarRow(_ tab: AppTab) -> some View {
        Label(tab.title, systemImage: tab.systemImage)
            .tag(tab)
    }

    private func macSidebarStatusRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(title)
    }

    private var macBackendStatusTitle: String {
        if appModel.isBrowseReady {
            "\(appModel.activeBackend.displayName) connected"
        } else {
            "\(appModel.activeBackend.displayName) sign-in needed"
        }
    }

    private var macDownloadStatusTitle: String {
        let records = downloadManager.records
        guard !records.isEmpty else { return "No offline downloads" }

        let activeCount = records.filter { $0.status.isActiveWork }.count
        let savedCount = records.filter(\.isComplete).count

        if activeCount > 0, savedCount > 0 {
            return "\(activeCount) active, \(savedCount) saved"
        } else if activeCount > 0 {
            return "\(activeCount) active download\(activeCount == 1 ? "" : "s")"
        } else if savedCount > 0 {
            return "\(savedCount) saved offline"
        } else {
            return "\(records.count) download\(records.count == 1 ? "" : "s")"
        }
    }

    @ViewBuilder
    private func macTabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            NavigationStack(path: $homePath) {
                HomeView()
                    .navigationTitle("Home")
            }
            .environment(\.cinemaOriginTab, .home)
            .environment(\.pushMediaItem, { (item: MediaItem) in homePath.append(item) })
            .id(appModel.activeBrowseSessionKey)
        case .libraries:
            NavigationStack(path: $librariesPath) {
                LibrariesView()
                    .navigationTitle("Libraries")
            }
            .environment(\.cinemaOriginTab, .libraries)
            .environment(\.pushMediaItem, { (item: MediaItem) in librariesPath.append(item) })
            .id(appModel.activeBrowseSessionKey)
        case .search:
            NavigationStack(path: $searchPath) {
                SearchView(focusRequest: searchFocusRequest, onClearSearch: exitSearch)
                    .navigationTitle("Search")
            }
            .environment(\.cinemaOriginTab, .search)
            .environment(\.pushMediaItem, { (item: MediaItem) in searchPath.append(item) })
            .id(appModel.activeBrowseSessionKey)
        case .music:
            NavigationStack(path: $musicPath) {
                MusicLibraryView()
                    .navigationTitle("Music")
            }
            .id(appModel.activeBrowseSessionKey)
        case .offline:
            NavigationStack {
                OfflineLibraryView(manager: downloadManager,
                                   focusedRatingKey: $offlineReturnRatingKey)
                    .navigationTitle("Offline")
            }
        case .settings:
            ContentUnavailableView("Settings live in the app menu",
                                   systemImage: "gearshape",
                                   description: Text("Choose Labstream > Settings to manage accounts and preferences."))
        }
    }
    #endif

    #if os(visionOS)
    private var visionRootContent: some View {
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
                    .environment(\.pushMediaItem, { (item: MediaItem) in homePath.append(item) })
                    .id(appModel.activeBrowseSessionKey)
            }
            Tab("Libraries", systemImage: "rectangle.stack", value: AppTab.libraries) {
                NavigationStack(path: $librariesPath) { LibrariesView() }
                    .environment(\.cinemaOriginTab, .libraries)
                    .environment(\.pushMediaItem, { (item: MediaItem) in librariesPath.append(item) })
                    .id(appModel.activeBrowseSessionKey)
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack(path: $searchPath) {
                    SearchView(focusRequest: searchFocusRequest, onClearSearch: exitSearch)
                }
                    .environment(\.cinemaOriginTab, .search)
                    .environment(\.pushMediaItem, { (item: MediaItem) in searchPath.append(item) })
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
            MiniPlayerBar(presentation: $nowPlayingPresentation)
        }
    }
    #endif

    #if os(iOS)
    /// One adaptive shell for iPhone AND iPad: `.sidebarAdaptable` renders the Liquid
    /// Glass floating tab bar in compact widths and a real sidebar on iPad (#209's iPad
    /// sidebar shell) without a hand-rolled `NavigationSplitView`. Search gets the
    /// system `.search` role so the platform separates it in the tab bar / pins it in
    /// the sidebar. The mini player rides `.tabViewBottomAccessory` — the iOS 26
    /// transport idiom (Apple Music) — matching the visionOS scene ornament's role, and
    /// the tab bar minimizes on scroll so media rails keep the full height.
    private var mobileRootContent: some View {
        TabView(selection: $selection) {
            ForEach(mobileTabs, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    tabContent(for: tab)
                }
            }
            Tab(AppTab.search.title, systemImage: AppTab.search.systemImage,
                value: AppTab.search, role: .search) {
                tabContent(for: .search)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        // `isEnabled:` (not a conditional inside the builder, which leaves an empty
        // glass bubble on screen) removes the accessory entirely when no music is loaded.
        .tabViewBottomAccessory(isEnabled: musicPlayer.current != nil) {
            MiniPlayerBar(presentation: $nowPlayingPresentation)
        }
        .sheet(isPresented: $showsSettingsSheet) {
            NavigationStack {
                SettingsView(authManager: authManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSettingsSheet = false }
                        }
                    }
            }
        }
        // A compact↔regular flip (iPhone Max rotation, iPad split-view resize) can strand
        // the selection on a Settings tab that no longer exists; fall back to Home and
        // keep Settings reachable via the sheet.
        .onChange(of: usesCompactTabSet) { _, isCompact in
            if isCompact, selection == .settings {
                selection = .home
                showsSettingsSheet = true
            }
        }
    }

    /// A phone-width bottom bar holds ~5 items; six spills Offline/Settings into the system
    /// "More" list. On compact width Settings moves out of the tab set to a Home nav-bar
    /// gear (the iPhone idiom — Apple apps use a gear/profile control, not a Settings tab),
    /// keeping the bar to four tabs plus the system search role. Regular width (iPad
    /// sidebar, Max-phone landscape) keeps the full set.
    private var usesCompactTabSet: Bool { horizontalSizeClass == .compact }

    private var mobileTabs: [AppTab] {
        AppTab.allCases.filter { tab in
            if tab == .search { return false }
            if tab == .settings, usesCompactTabSet { return false }
            return true
        }
    }

    @ToolbarContentBuilder
    private var compactSettingsToolbar: some ToolbarContent {
        if usesCompactTabSet {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsSettingsSheet = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            NavigationStack(path: $homePath) {
                HomeView()
                    .toolbar { compactSettingsToolbar }
            }
                .environment(\.cinemaOriginTab, .home)
                .environment(\.pushMediaItem, { (item: MediaItem) in homePath.append(item) })
                .id(appModel.activeBrowseSessionKey)
        case .libraries:
            NavigationStack(path: $librariesPath) {
                LibrariesView()
                    .toolbar { compactSettingsToolbar }
            }
                .environment(\.cinemaOriginTab, .libraries)
                .environment(\.pushMediaItem, { (item: MediaItem) in librariesPath.append(item) })
                .id(appModel.activeBrowseSessionKey)
        case .search:
            NavigationStack(path: $searchPath) {
                SearchView(focusRequest: searchFocusRequest, onClearSearch: exitSearch)
            }
                .environment(\.cinemaOriginTab, .search)
                .environment(\.pushMediaItem, { (item: MediaItem) in searchPath.append(item) })
                .id(appModel.activeBrowseSessionKey)
        case .music:
            NavigationStack(path: $musicPath) {
                MusicLibraryView()
                    .toolbar { compactSettingsToolbar }
            }
                .id(appModel.activeBrowseSessionKey)
        case .offline:
            NavigationStack {
                OfflineLibraryView(manager: downloadManager,
                                   focusedRatingKey: $offlineReturnRatingKey)
                    .toolbar { compactSettingsToolbar }
            }
        case .settings:
            NavigationStack { SettingsView(authManager: authManager) }
        }
    }
    #endif

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
            // Resolve the target to a full item. Spotlight hits and Play/Open
            // intents arrive as a backend-scoped route key and are fetched fresh here;
            // `.item` is reserved for callers that JUST fetched the metadata
            // (Continue Watching), so no snapshot can grow stale in between.
            var item: MediaItem?
            switch route.target {
            case .item(let given):
                item = given
            case .routeKey(let routeKey):
                let routeBackend = MediaBackendKind(routeKey.backend)
                guard appModel.activeBackend == routeBackend,
                      let session = appModel.backendSession(for: routeBackend.downloadBackendKind) else {
                    return
                }
                if let namespace = routeKey.serverNamespace,
                   namespace != BackendScopedMediaID.serverNamespace(session.baseURL) {
                    return
                }
                let result = await DetailMetadataLoader.load(ratingKey: routeKey.ratingKey,
                                                             backend: routeBackend,
                                                             appModel: appModel)
                item = result.item
                guard isCurrentRoute() else { return }
            }
            // Unresolvable (deleted item, stale index from another server): the
            // route quietly degrades to just foregrounding Home.
            guard var item else { return }

            var autoPlay = route.autoPlay
            if autoPlay, item.isContainer {
                // "Play <show/season>": drill to the first episode leaf against the ACTIVE
                // backend only, so a stale route never walks the wrong server's hierarchy.
                let leaf = await resolveSystemEntryLeaf(from: item)
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

    private func resolveSystemEntryLeaf(from item: MediaItem) async -> MediaItem? {
        if item.isPlayableLeaf { return item }
        switch item.kind {
        case .season:
            let episodes = (try? await systemEntryChildren(for: item.ratingKey)) ?? []
            return firstSystemEntryLeaf(in: episodes)
        case .show:
            let seasons = (try? await systemEntryChildren(for: item.ratingKey)) ?? []
            for season in seasons {
                let episodes = (try? await systemEntryChildren(for: season.ratingKey)) ?? []
                if let first = firstSystemEntryLeaf(in: episodes) { return first }
            }
            return nil
        default:
            return nil
        }
    }

    private func systemEntryChildren(for ratingKey: String) async throws -> [MediaItem] {
        switch appModel.activeBackend {
        case .plex:
            guard let service = try? PlexBrowseService(appModel: appModel) else {
                throw URLError(.userAuthenticationRequired)
            }
            return try await service.children(ratingKey: ratingKey)
        case .jellyfin:
            return try await JellyfinBrowseService(appModel: appModel)
                .items(parentId: ratingKey, recursive: false)
        case .emby:
            return try await EmbyBrowseService(appModel: appModel)
                .items(parentId: ratingKey, recursive: false)
        }
    }

    private func firstSystemEntryLeaf(in items: [MediaItem]) -> MediaItem? {
        items
            .filter(\.isPlayableLeaf)
            .sorted { lhs, rhs in
                let l = (lhs.parentIndex ?? Int.max, lhs.index ?? Int.max)
                let r = (rhs.parentIndex ?? Int.max, rhs.index ?? Int.max)
                return l < r
            }
            .first
    }

    private func cancelSystemEntryTask() {
        systemEntryTask?.cancel()
        systemEntryTask = nil
        systemEntryGeneration += 1
    }

    /// ⌘F: land on the Search tab and bump the focus request so SearchView focuses its
    /// field whether it was already mounted or is mounting fresh from the tab switch.
    private func focusSearch() {
        #if os(macOS)
        guard !macPlayerPresenter.isPresented else { return }
        #endif
        selection = .search
        searchFocusRequest += 1
    }

    /// Search's Clear button should close the dedicated search role/surface as well
    /// as emptying the query. On iOS that restores the normal top/floating tab chrome
    /// for Home/Libraries/Music/Offline; on visionOS it returns to the previous tab.
    private func exitSearch() {
        searchPath = NavigationPath()
        selection = lastNonSearchSelection == .search ? .home : lastNonSearchSelection
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
