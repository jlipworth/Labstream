import SwiftUI
import PlexKit

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

    enum AppTab: Hashable {
        case home, libraries, search, music, offline, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack { HomeView() }
            }
            Tab("Libraries", systemImage: "rectangle.stack", value: AppTab.libraries) {
                NavigationStack { LibrariesView() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack { SearchView() }
            }
            Tab("Music", systemImage: "music.note", value: AppTab.music) {
                NavigationStack { MusicLibraryView() }
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
        .environment(appModel)
        .environment(downloadManager)
        .environment(musicPlayer)
    }
}

// MARK: - Library request builders (UI-owned)
//
// The committed PlexKit ships builders for auth/transcode/timeline/optimize but
// not for the plain browse endpoints (sections, hubs, search, item children).
// Those are simple GETs, so the UI builds the `PlexRequest`s directly using the
// shared `PlexHeaders.standard(...)`. Keeping them here (a UI-owned file) avoids
// touching PlexKit and keeps all browse wiring in one place.
enum BrowseAPI {
    /// `GET /library/sections` — the list of libraries on the server.
    static func sections(server: URL, token: String, identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/sections"),
                    method: "GET",
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `GET /library/sections/<key>/all` — every item in a section.
    static func sectionItems(server: URL, token: String, identity: ClientIdentity,
                             sectionKey: String) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/sections/\(sectionKey)/all"),
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
    /// a show's seasons, or a season's episodes. Delegates to the pure PlexKit builder.
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
