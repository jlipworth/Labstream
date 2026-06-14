import SwiftUI
import PMSKit

/// Home tab: the server's hubs (`GET /hubs`) rendered as horizontal poster rails,
/// Swiftfin-style. Each rail is one `Hub`; tapping a poster opens `DetailView`.
struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    @State private var hubs: [Hub] = []
    @State private var jellyfinViews: [JellyfinLibraryLink] = []
    @State private var jellyfinRails: [JellyfinHomeRail] = []
    @State private var loadState: LoadState = .idle
    /// The server the current hubs were loaded from (pop-back no-op guard).
    @State private var loadedServer: URL?

    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                // Skeleton rails instead of a lone spinner: the page keeps its shape
                // while content loads, so the transition to real posters is seamless.
                SkeletonRails()
            case .failed(let message):
                ContentUnavailableView("Couldn’t load Home",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                .frame(maxWidth: .infinity, minHeight: 360)
            case .loaded:
                if appModel.activeBackend == .jellyfin {
                    jellyfinHome
                } else if hubs.isEmpty {
                    ContentUnavailableView("Nothing here yet",
                                           systemImage: "house",
                                           description: Text("No hubs returned by the server."))
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                        // Music un-hidden (#17 Phase 7): artists/albums stay in the
                        // hubs; only TRACK items drop (rail cells have no play
                        // affordance — v2, MUSIC-DESIGN §3.1).
                        ForEach(hubs.hidingMusicTracks) { hub in
                            HubRail(hub: hub)
                        }
                    }
                    .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .navigationTitle("Home")
        .navigationDestination(for: JellyfinLibraryLink.self) { view in
            LibraryGridView(jellyfin: view)
        }
        .navigationDestination(for: MediaItem.self) { item in
            // Music items route into the music module, never the video detail/player
            // (#17 Phase 7). Home hubs are cross-section, so no music sectionKey —
            // the artist view falls back to its children endpoint. Video/photo
            // playlists are NOT music and keep the DetailView path.
            if item.isMusicContainer || item.isAudioPlaylist {
                musicDestination(for: item, sectionKey: nil)
            } else {
                DetailView(item: item)
            }
        }
        // Re-run whenever the server URL resolves after discovery/rediscovery.
        .task(id: appModel.serverBaseURL) { await load() }
        .refreshable { await load(force: true) }
    }

    @ViewBuilder
    private var jellyfinHome: some View {
        if jellyfinViews.isEmpty {
            ContentUnavailableView("No Jellyfin libraries",
                                   systemImage: "rectangle.stack",
                                   description: Text("This Jellyfin user has no visible libraries."))
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                JellyfinLibrariesRail(views: jellyfinViews)

                if jellyfinRails.isEmpty {
                    ContentUnavailableView("Open a library to browse",
                                           systemImage: "rectangle.stack",
                                           description: Text("Jellyfin did not return preview items for these libraries."))
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(jellyfinRails) { rail in
                        HubRail(hub: Hub(title: rail.title,
                                         hubIdentifier: "jellyfin-\(rail.id)",
                                         metadata: rail.items))
                    }
                }
            }
            .padding(.vertical, DS.Space.xl)
        }
    }

    private func load(force: Bool = false) async {
        // `.task` also re-fires every time the stack pops back to Home; without this
        // guard the rails reload and dump the scroll position the user returned to.
        // A real server change (different URL) still reloads.
        let activeServer = appModel.activeBackend == .jellyfin ? appModel.jellyfinServerBaseURL : appModel.serverBaseURL
        if !force, loadedServer == activeServer, case .loaded = loadState { return }
        if appModel.activeBackend == .jellyfin {
            loadState = .loading
            do {
                let service = JellyfinBrowseService(appModel: appModel)
                let views = try await service.userViewLinks()
                jellyfinViews = views
                jellyfinRails = try await service.homeRails(for: views)
                loadedServer = activeServer
                loadState = .loaded
            } catch {
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No reachable Plex server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.hubs(server: server, token: token, identity: appModel.identity)
        do {
            let resp = try await appModel.client.send(req, as: HubsResponse.self)
            hubs = resp.mediaContainer.hub
            loadedServer = server
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// Icon-card row for Jellyfin user views. This replaces the old full-screen folder
/// list with a compact launch rail, leaving the rest of Home for Plex-style media rails.
struct JellyfinLibrariesRail: View {
    let views: [JellyfinLibraryLink]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Libraries")
                .font(.title2.bold())
                .padding(.horizontal, DS.Space.xxl)

            ScrollView(.horizontal) {
                LazyHStack(spacing: DS.Space.lg) {
                    ForEach(views) { view in
                        NavigationLink(value: view) {
                            JellyfinLibraryCard(view: view)
                        }
                        .cardLink(cornerRadius: DS.Radius.card)
                    }
                }
                .padding(.vertical, DS.Space.sm)
            }
            .contentMargins(.horizontal, DS.Space.xxl, for: .scrollContent)
            .scrollClipDisabled()
        }
    }
}

/// One horizontal rail of posters for a hub.
private struct HubRail: View {
    let hub: Hub

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(hub.title)
                .font(.title2.bold())
                .padding(.horizontal, DS.Space.xxl)

            ScrollView(.horizontal) {
                LazyHStack(spacing: DS.Space.xl) {
                    ForEach(hub.metadata) { item in
                        NavigationLink(value: item) {
                            PosterCell(item: item)
                        }
                        .cardLink()
                    }
                }
                .padding(.vertical, DS.Space.sm)
            }
            // Inset the scroll content via contentMargins, not .padding on the stack —
            // keeps the inset out of the cards' own geometry (see the gaze-routing
            // gotcha in docs/DEVELOPMENT.md).
            .contentMargins(.horizontal, DS.Space.xxl, for: .scrollContent)
            .scrollClipDisabled() // let hover-lifted posters breathe past the rail edge
        }
    }
}

/// A poster + title cell used in rails and grids.
///
/// Visual polish: a fixed 2:3 poster, a continue-watching progress sliver when the
/// item has a resume point, and a visionOS hover lift. The title block reserves a
/// stable height so rows of cells with 1- vs 2-line titles still align cleanly.
struct PosterCell: View {
    let item: MediaItem
    var width: CGFloat = DS.Poster.railWidth

    private var height: CGFloat { DS.Poster.height(for: width) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            PosterImage(path: item.thumb, width: width, height: height)
                .overlay(alignment: .bottom) { progressSliver }
                .posterHover()

            VStack(alignment: .leading, spacing: 2) {
                // Episodes read like Plex/Emby: show name on top, then
                // "S{parentIndex}E{index} · {title}". Everything else keeps the
                // title + year treatment.
                if item.kind == .episode {
                    Text(item.grandparentTitle ?? item.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(episodeSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let year = item.year {
                        Text(String(year))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: width, alignment: .leading)
        // NOTE: no hover effect here — the wrapping link uses `.cardLink()`, whose
        // built-in `.plain` style draws (and correctly registers) the gaze highlight.
        // A custom ButtonStyle here misroutes pinches to neighboring cards (DEVELOPMENT.md).
    }

    /// "S{x}E{y} · {title}" for an episode poster's second line, gracefully dropping the
    /// code when the season/episode numbers are missing.
    private var episodeSubtitle: String {
        if let code = item.seasonEpisodeCode {
            return "\(code) · \(item.title)"
        }
        return item.title
    }

    /// A thin "continue watching" progress bar pinned to the poster's bottom edge,
    /// shown only when the item carries a resume offset. Mirrors Plex/Netflix posters.
    @ViewBuilder
    private var progressSliver: some View {
        if let offset = item.viewOffset, offset > 0,
           let duration = item.duration, duration > 0 {
            let fraction = min(1, max(0, Double(offset) / Double(duration)))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.45))
                    Capsule().fill(.tint)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, DS.Space.sm)
            .padding(.bottom, DS.Space.sm)
        }
    }
}

/// Placeholder rails shown while Home loads — a couple of titled rows of shimmering
/// poster blanks so the screen has structure (and no jarring spinner-to-grid jump).
struct SkeletonRails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxxl) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                        .fill(.regularMaterial)
                        .frame(width: 200, height: 26)
                        .overlay { ShimmerView() }
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        .padding(.horizontal, DS.Space.xxl)

                    ScrollView(.horizontal) {
                        HStack(spacing: DS.Space.xl) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                                    .fill(.regularMaterial)
                                    .frame(width: DS.Poster.railWidth,
                                           height: DS.Poster.height(for: DS.Poster.railWidth))
                                    .overlay { ShimmerView() }
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
                            }
                        }
                        .padding(.horizontal, DS.Space.xxl)
                    }
                    .scrollDisabled(true)
                }
            }
        }
        .padding(.vertical, DS.Space.xl)
    }
}

/// Map a thrown error (often `PlexError`) to a short user-facing string.
func friendlyMessage(_ error: Error) -> String {
    if let plex = error as? PlexError {
        switch plex {
        case .unauthorized: return "Your session expired. Please sign in again."
        case .serverUnreachable: return "Couldn’t reach the server."
        case .http(let code): return "Server error (HTTP \(code))."
        case .decoding: return "Unexpected response from the server."
        }
    }
    return error.localizedDescription
}

// MARK: - Music track filtering (#17 Phase 7 — replaces the #15 full hide)

extension Array where Element == Hub {
    /// Drops TRACK items from each hub (and any hub left empty). The #15-era
    /// `hidingMusic` full strip is gone — artists/albums now render and route via
    /// `musicDestination` — but track cells in a generic poster rail would navigate
    /// instead of play, so they stay out until rails grow a play affordance
    /// (MUSIC-DESIGN §3.1, v2).
    var hidingMusicTracks: [Hub] {
        compactMap { hub in
            let kept = hub.metadata.filter { $0.kind != .track }
            guard !kept.isEmpty else { return nil }
            return Hub(hubKey: hub.hubKey, key: hub.key, title: hub.title, type: hub.type,
                       hubIdentifier: hub.hubIdentifier, size: hub.size, metadata: kept)
        }
    }
}

// MARK: - MediaItem Hashable for navigationDestination

extension MediaItem: @retroactive Hashable {
    public static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.ratingKey == rhs.ratingKey
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ratingKey)
    }
}
