import SwiftUI
import PMSKit

/// Home tab: the server's hubs (`GET /hubs`) rendered as horizontal poster rails,
/// Swiftfin-style. Each rail is one `Hub`; tapping a poster opens `DetailView`.
struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    @State private var hubs: [Hub] = []
    @State private var jellyfinViews: [JellyfinLibraryLink] = []
    @State private var jellyfinRails: [JellyfinHomeRail] = []
    @State private var embyViews: [EmbyLibraryLink] = []
    @State private var embyRails: [EmbyHomeRail] = []
    @State private var loadState: LoadState = .idle
    /// Server/backend identity the current hubs were loaded from (pop-back no-op guard).
    /// Includes selected Plex server id because multiple servers can resolve through the same URL.
    @State private var loadedIdentity: String?

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
                } else if appModel.activeBackend == .emby {
                    embyHome
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
        .navigationDestination(for: EmbyLibraryLink.self) { view in
            LibraryGridView(emby: view)
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
        .task(id: loadIdentity) { await load() }
        .refreshable { await load(force: true) }
    }

    private var loadIdentity: String {
        switch appModel.activeBackend {
        case .plex:
            return "plex:\(appModel.selectedServer?.clientIdentifier ?? "nil"):\(appModel.serverBaseURL?.absoluteString ?? "nil")"
        case .jellyfin:
            return "jellyfin:\(appModel.jellyfinServerBaseURL?.absoluteString ?? "nil")"
        case .emby:
            return "emby:\(appModel.embyServerBaseURL?.absoluteString ?? "nil")"
        }
    }

    @ViewBuilder
    private var embyHome: some View {
        if embyViews.isEmpty {
            ContentUnavailableView("No Emby libraries",
                                   systemImage: "rectangle.stack",
                                   description: Text("This Emby user has no visible libraries."))
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                if embyRails.isEmpty {
                    ContentUnavailableView("Open a library to browse",
                                           systemImage: "rectangle.stack",
                                           description: Text("Emby did not return preview items for these libraries."))
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(embyRails) { rail in
                        HubRail(hub: Hub(title: rail.title,
                                         hubIdentifier: "emby-\(rail.id)",
                                         metadata: rail.items))
                    }
                }
            }
            .padding(.vertical, DS.Space.xl)
        }
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
        let activeIdentity = loadIdentity
        if !force, loadedIdentity == activeIdentity, case .loaded = loadState { return }

        let span = PerformanceInstrumentation.begin(.homeLoad,
                                                     backend: appModel.activeBackend.performanceLabel,
                                                     fields: ["force": force ? 1 : 0])
        if appModel.activeBackend == .jellyfin {
            loadState = .loading
            do {
                let service = JellyfinBrowseService(appModel: appModel)
                let views = try await service.userViewLinks()
                jellyfinViews = views
                jellyfinRails = try await service.homeRails(for: views)
                loadedIdentity = activeIdentity
                loadState = .loaded
                span.end(fields: [
                    "view_count": views.count,
                    "rail_count": jellyfinRails.count,
                    "item_count": jellyfinRails.reduce(0) { $0 + $1.items.count },
                ])
            } catch {
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        if appModel.activeBackend == .emby {
            loadState = .loading
            do {
                let service = EmbyBrowseService(appModel: appModel)
                let views = try await service.userViewLinks()
                embyViews = views
                embyRails = try await service.homeRails(for: views)
                loadedIdentity = activeIdentity
                loadState = .loaded
                span.end(fields: [
                    "view_count": views.count,
                    "rail_count": embyRails.count,
                    "item_count": embyRails.reduce(0) { $0 + $1.items.count },
                ])
            } catch {
                span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            span.end(result: "failure", fields: ["error": "missing_plex_server"])
            loadState = .failed("No reachable Plex server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.hubs(server: server, token: token, identity: appModel.identity)
        do {
            let resp = try await appModel.client.send(req, as: HubsResponse.self)
            hubs = resp.mediaContainer.hub
            loadedIdentity = activeIdentity
            loadState = .loaded
            span.end(fields: [
                "hub_count": hubs.count,
                "item_count": hubs.reduce(0) { $0 + $1.metadata.count },
            ])
            // System integration (#24): make the just-browsed items findable in
            // Spotlight, and refresh the "Play <title> on VisionPlay" Siri phrase
            // vocabulary (drawn from the entity query's suggestions).
            SpotlightIndexer.index(hubs.flatMap(\.metadata), server: server)
            VisionPlayShortcuts.updateAppShortcutParameters()
        } catch {
            span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
            loadState = .failed(friendlyMessage(error))
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
                            RailMediaCell(item: item)
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

/// Rail cell that respects the media artwork shape.
///
/// Movies/shows/seasons keep the canonical 2:3 poster card, but episode thumbs are
/// screenshots. Rendering those screenshots through `PosterCell` asks the server for
/// poster-sized artwork and then clips it into a poster frame, which makes TV rails look
/// stretched/cropped. Episode rails use a 16:9 card like Apple/Plex episode shelves.
struct RailMediaCell: View {
    let item: MediaItem

    var body: some View {
        if item.kind == .episode {
            EpisodeRailCell(item: item)
        } else {
            PosterCell(item: item)
        }
    }
}

private struct EpisodeRailCell: View {
    let item: MediaItem

    private let width: CGFloat = 252
    private var height: CGFloat { width * 9.0 / 16.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            PosterImage(path: item.thumb,
                        width: width,
                        height: height,
                        cornerRadius: DS.Radius.poster)
                .overlay(alignment: .bottom) { progressSliver }
                .posterHover()

            VStack(alignment: .leading, spacing: 2) {
                Text(item.grandparentTitle ?? item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(episodeSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var episodeSubtitle: String {
        if let code = item.seasonEpisodeCode {
            return "\(code) · \(item.title)"
        }
        return item.title
    }

    private var progressSliver: some View {
        ProgressSliver(offset: item.viewOffset, duration: item.duration)
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
    private var progressSliver: some View {
        ProgressSliver(offset: item.viewOffset, duration: item.duration)
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
