import SwiftUI
import PMSKit

/// Top-level authenticated UI: a tab strip of Home · Libraries · Search, plus an
/// Offline entry and a Settings control. Created once the user is signed in.
///
/// `RootView` owns the single `DownloadManager` for the app and passes it (and
/// `AppModel`) down through the environment so Detail/Offline can reach them.
struct RootView: View {
    let appModel: AppModel
    let authManager: AuthManager
    let downloadManager: DownloadManager
    let musicPlayer: MusicPlayerController

    @State private var selection: AppTab = .home
    /// Music tab's navigation path, lifted here so Now Playing's "go to
    /// artist/album" (which lives in a sheet, outside the stack) can push into it.
    @State private var musicPath = NavigationPath()
    /// Home tab's navigation path, lifted here so deep links (App Intents,
    /// Spotlight results — #24) can push a DetailView from outside the stack.
    @State private var homePath = NavigationPath()

    enum AppTab: Hashable {
        case home, libraries, search, music, offline, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack(path: $homePath) { HomeView() }
            }
            Tab("Libraries", systemImage: "rectangle.stack", value: AppTab.libraries) {
                NavigationStack { LibrariesView() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack { SearchView() }
            }
            Tab("Music", systemImage: "music.note", value: AppTab.music) {
                NavigationStack(path: $musicPath) { MusicLibraryView() }
            }
            Tab("Offline", systemImage: "arrow.down.circle", value: AppTab.offline) {
                NavigationStack { OfflineLibraryView(manager: downloadManager) }
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
        // Deep links from App Intents / Spotlight (#24): same pattern as the music
        // navigation request above — observe the router, land on Home, push.
        .onChange(of: DeepLinkRouter.shared.pending) { _, route in
            guard let route else { return }
            handleDeepLink(route)
        }
        .task {
            // Consume a route that arrived BEFORE RootView mounted (cold launch
            // from an intent/Spotlight: it was set while the restore splash was up).
            if let route = DeepLinkRouter.shared.pending {
                handleDeepLink(route)
            }
        }
        .environment(appModel)
        .environment(downloadManager)
        .environment(musicPlayer)
    }

    // MARK: - Deep links (App Intents / Spotlight, #24)

    /// Perform one router route: land on Home, resolve the target to a full
    /// `MediaItem`, and push its DetailView. For "play" requests on a container
    /// (show/season) the tested `EpisodeResolver` walks down to the first episode
    /// so "Play <show>" actually plays something. Single-window by design: the
    /// player then presents as DetailView's `.fullScreenCover`, never a new scene.
    private func handleDeepLink(_ route: DeepLinkRouter.Route) {
        let router = DeepLinkRouter.shared
        router.pending = nil
        selection = .home
        // Pop home to root first so repeated intents don't stack stale details.
        homePath = NavigationPath()
        Task { @MainActor in
            guard let server = appModel.serverBaseURL,
                  let token = appModel.serverToken else { return }
            let identity = appModel.identity
            let client = appModel.client

            // Resolve the target to a full item. Spotlight hits and Play/Open
            // intents arrive as a bare ratingKey and are fetched fresh here;
            // `.item` is reserved for callers that JUST fetched the metadata
            // (Continue Watching), so no snapshot can grow stale in between.
            var item: MediaItem?
            switch route.target {
            case .item(let given):
                item = given
            case .ratingKey(let ratingKey):
                let req = BrowseAPI.metadata(server: server, token: token,
                                             identity: identity, ratingKey: ratingKey)
                item = (try? await client.send(req, as: MetadataResponse.self))?
                    .mediaContainer.metadata.first
            }
            // Unresolvable (deleted item, stale index from another server): the
            // route quietly degrades to just foregrounding Home.
            guard var item else { return }

            var autoPlay = route.autoPlay
            if autoPlay, item.isContainer {
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
                if let leaf {
                    item = leaf
                } else {
                    autoPlay = false // fall back to opening the container browser
                }
            }

            if autoPlay, item.isPlayableLeaf, !item.isMusic {
                // Arm the handshake BEFORE pushing; DetailView consumes it in its
                // `.task` and presents the player.
                router.requestAutoPlay(forRatingKey: item.ratingKey)
            }
            homePath.append(item)
        }
    }
}

// MARK: - Library request builders (UI-owned)
//
// The committed PMSKit ships builders for auth/transcode/timeline/optimize but
// not for the plain browse endpoints (sections, hubs, search, item children).
// Those are simple GETs, so the UI builds the `PlexRequest`s directly using the
// shared `PlexHeaders.standard(...)`. Keeping them here (a UI-owned file) avoids
// touching PMSKit and keeps all browse wiring in one place.
enum BrowseAPI {
    /// `GET /library/sections` — the list of libraries on the server.
    static func sections(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/sections"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/sections/<key>/all` — every item in a section.
    static func sectionItems(server: URL, token: String, identity: ClientIdentity,
                             sectionKey: String,
                             containerStart: Int? = nil,
                             containerSize: Int? = nil,
                             sort: String? = nil,
                             firstCharacter: String? = nil) -> PlexRequest {
        var queryItems: [URLQueryItem] = []
        if let sort { queryItems.append(.init(name: "sort", value: sort)) }
        if let firstCharacter { queryItems.append(.init(name: "firstCharacter", value: firstCharacter)) }
        if let containerStart, let containerSize {
            queryItems.append(.init(name: "X-Plex-Container-Start", value: String(containerStart)))
            queryItems.append(.init(name: "X-Plex-Container-Size", value: String(containerSize)))
        }
        return PlexRequest(url: server.appendingPathComponent("/library/sections/\(sectionKey)/all"),
                           method: "GET",
                           queryItems: queryItems,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/sections/<key>/firstCharacter` — available initials + counts for fast jumps.
    static func firstCharacters(server: URL, token: String, identity: ClientIdentity,
                                sectionKey: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/sections/\(sectionKey)/firstCharacter"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /hubs` — the home hubs (Continue Watching, Recently Added, …).
    static func hubs(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/hubs"),
                    method: "GET",
                    queryItems: [.init(name: "count", value: "20")],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/onDeck` — the global Continue Watching / On Deck list (the
    /// movies/episodes with a resume point). Drives the Continue Watching intent
    /// and the Shortcuts parameter suggestions (#24).
    static func onDeck(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/onDeck"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /hubs/search?query=` — global search grouped into hubs.
    static func search(server: URL, token: String, identity: ClientIdentity,
                       query: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/hubs/search"),
                    method: "GET",
                    queryItems: [
                        .init(name: "query", value: query),
                        .init(name: "limit", value: "30"),
                    ],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/metadata/<ratingKey>/children` — one level of the TV hierarchy:
    /// a show's seasons, or a season's episodes. Delegates to the pure PMSKit builder.
    static func children(server: URL, token: String, identity: ClientIdentity,
                         ratingKey: String) -> PlexRequest {
        ChildrenRequest.children(server: server, token: token,
                                 identity: identity, ratingKey: ratingKey)
    }

    /// `GET /library/metadata/<ratingKey>` — full metadata for one item.
    ///
    /// Requests chapters, intro/credits markers and extras inline so the detail/player
    /// UI can render chapter rows and Skip Intro / Skip Credits without extra round-trips.
    /// These are additive query params; PMS simply omits the corresponding elements when
    /// the item has none.
    static func metadata(server: URL, token: String, identity: ClientIdentity,
                         ratingKey: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/metadata/\(ratingKey)"),
                    method: "GET",
                    queryItems: [
                        .init(name: "includeChapters", value: "1"),
                        .init(name: "includeMarkers", value: "1"),
                        .init(name: "includeExtras", value: "1"),
                    ],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }
}
