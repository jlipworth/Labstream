import SwiftUI
import PMSKit

/// Home tab: the server's hubs (`GET /hubs`) rendered as horizontal poster rails,
/// Swiftfin-style. Each rail is one `Hub`; tapping a poster opens `DetailView`.
struct HomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.labstreamCompactWidth) private var compactWidth

    @State private var hubs: [Hub] = []
    @State private var mediaBrowserLibraries: [MediaBrowserHomeLibraryLink] = []
    @State private var mediaBrowserRails: [MediaBrowserHomeRail] = []
    @State private var loadState: BrowseLoadState = .idle
    /// Server/backend identity the current hubs were loaded from (pop-back no-op guard).
    /// Includes selected Plex server id because multiple servers can resolve through the same URL.
    @State private var loadedIdentity: String?
    @State private var loadGeneration = 0


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
                if appModel.activeBackend.isMediaBrowser {
                    mediaBrowserHome
                } else if hubs.isEmpty {
                    ContentUnavailableView("Nothing here yet",
                                           systemImage: "house",
                                           description: Text("No hubs returned by the server."))
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(alignment: .leading,
                               spacing: compactWidth ? DS.Space.xl : DS.Space.xxxl) {
                        // Music un-hidden (#17 Phase 7): artists/albums stay in the
                        // hubs; only TRACK items drop (rail cells have no play
                        // affordance — v2, MUSIC-DESIGN §3.1).
                        ForEach(hubs.hidingMusicTracks) { hub in
                            HubRail(hub: hub)
                        }
                    }
                    .padding(.vertical, compactWidth ? DS.Space.lg : DS.Space.xl)
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
                // Capture the active backend as the item's origin (#100) so Play / watched /
                // download resolve against the backend the item came from even if the user
                // switches backends while this detail is still on the stack.
                DetailView(item: item, originBackend: appModel.activeBackend)
            }
        }
        // Re-run whenever the server URL resolves after discovery/rediscovery.
        .task(id: loadIdentity) { await load() }
        .refreshable { await load(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: LibraryVisibilityStore.didChangeNotification)) { notification in
            reloadHomeIfVisibilityChanged(notification)
        }
    }

    private var loadIdentity: String {
        appModel.activeBrowseSessionKey
    }

    @ViewBuilder
    private var mediaBrowserHome: some View {
        if mediaBrowserLibraries.isEmpty {
            ContentUnavailableView("No \(appModel.activeBackend.displayName) libraries",
                                   systemImage: "rectangle.stack",
                                   description: Text("This \(appModel.activeBackend.displayName) user has no visible libraries."))
            .frame(maxWidth: .infinity, minHeight: 360)
        } else {
            LazyVStack(alignment: .leading,
                       spacing: compactWidth ? DS.Space.xl : DS.Space.xxxl) {
                if mediaBrowserRails.isEmpty {
                    ContentUnavailableView("Open a library to browse",
                                           systemImage: "rectangle.stack",
                                           description: Text("\(appModel.activeBackend.displayName) did not return preview items for these libraries."))
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ForEach(mediaBrowserRails) { rail in
                        HubRail(hub: Hub(title: rail.title,
                                         hubIdentifier: "\(appModel.activeBackend.rawValue)-\(rail.id)",
                                         metadata: rail.items))
                    }
                }
            }
            .padding(.vertical, compactWidth ? DS.Space.lg : DS.Space.xl)
        }
    }

    private func load(force: Bool = false) async {
        // `.task` also re-fires every time the stack pops back to Home; without this
        // guard the rails reload and dump the scroll position the user returned to.
        // A real server change (different URL) still reloads.
        let activeIdentity = loadIdentity
        if !force, loadedIdentity == activeIdentity, case .loaded = loadState { return }
        loadGeneration += 1
        let generation = loadGeneration

        let span = PerformanceInstrumentation.begin(.homeLoad,
                                                     backend: appModel.activeBackend.performanceLabel,
                                                     fields: ["force": force ? 1 : 0])
        if appModel.activeBackend.isMediaBrowser {
            loadState = .loading
            do {
                // Mirror the Libraries screen: hide library rails the user has hidden (#104).
                // Jellyfin/Emby Home rails are library-scoped (built from `views`), so filtering
                // `views` here keeps Home consistent. (Plex Home uses non-library `/hubs` and is
                // deferred — see #104.)
                let content = try await MediaBrowserHomeProvider(appModel: appModel).loadHome()
                guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
                mediaBrowserLibraries = content.libraries
                mediaBrowserRails = content.rails
                if let session = appModel.backendSession(for: appModel.activeBackend.downloadBackendKind) {
                    SpotlightIndexer.index(content.rails.flatMap(\.items),
                                           backend: appModel.activeBackend,
                                           server: session.baseURL)
                    LabstreamShortcuts.updateAppShortcutParameters()
                }
                // Only pin the loaded identity for a clean load. A degraded load (some rails
                // errored) is shown but left unpinned so pop-back / the next `.task` re-fetches
                // and can recover the missing rails without a manual pull-to-refresh (#93).
                loadedIdentity = content.isDegraded ? nil : activeIdentity
                loadState = .loaded
                span.end(fields: [
                    "view_count": content.libraries.count,
                    "rail_count": mediaBrowserRails.count,
                    "item_count": mediaBrowserRails.reduce(0) { $0 + $1.items.count },
                    "degraded": content.isDegraded ? 1 : 0,
                ])
            } catch {
                guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
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
            guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
            hubs = resp.mediaContainer.hub
            loadedIdentity = activeIdentity
            loadState = .loaded
            span.end(fields: [
                "hub_count": hubs.count,
                "item_count": hubs.reduce(0) { $0 + $1.metadata.count },
            ])
            // System integration (#24): make the just-browsed items findable in
            // Spotlight, and refresh the "Play <title> on Labstream" Siri phrase
            // vocabulary (drawn from the entity query's suggestions).
            SpotlightIndexer.index(hubs.flatMap(\.metadata), server: server)
            LabstreamShortcuts.updateAppShortcutParameters()
        } catch {
            guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
            span.end(result: "failure", fields: ["error": PerformanceInstrumentation.errorLabel(error)])
            loadState = .failed(friendlyMessage(error))
        }
    }

    /// Jellyfin/Emby Home rails are filtered by the same hidden-library set as the Libraries
    /// screen (#104). Settings can change that set while Home remains mounted in its tab, so
    /// refresh the active MediaBrowser home when the relevant backend key changes. Plex Home uses
    /// non-library `/hubs` and is intentionally deferred for #104, so no reload is needed there.
    private func reloadHomeIfVisibilityChanged(_ notification: Notification) {
        guard appModel.activeBackend != .plex,
              let backendKey = notification.userInfo?[LibraryVisibilityStore.didChangeBackendKeyUserInfoKey] as? String,
              backendKey == appModel.libraryVisibilityBackendKey else { return }
        Task { await load(force: true) }
    }
}

/// One horizontal rail of posters for a hub.
private struct HubRail: View {
    let hub: Hub

    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        VStack(alignment: .leading, spacing: compactWidth ? DS.Space.sm : DS.Space.lg) {
            Text(hub.title)
                .font(compactWidth ? .title3.bold() : .title2.bold())
                .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: compactWidth ? DS.Space.md : DS.Space.xl) {
                    ForEach(hub.metadata) { item in
                        NavigationLink(value: item) {
                            RailMediaCell(item: item)
                        }
                        .cardLink()
                        .videoCardContextMenu(for: item)
                    }
                }
                .padding(.vertical, DS.Space.sm)
            }
            // Inset the scroll content via contentMargins, not .padding on the stack —
            // keeps the inset out of the cards' own geometry (see the gaze-routing
            // gotcha in docs/DEVELOPMENT.md).
            .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth))
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

/// Shared sizing for Home/media-browser rails.
///
/// Episode rails use 16:9 stills while movie/show rails use the canonical 2:3 poster.
/// Without reserving the same overall cell height, a TV rail collapses vertically and
/// makes the next Emby/Jellyfin "Recently Added" rail look incorrectly spaced.
private enum HomeRailCellMetrics {
    static func episodeWidth(compact: Bool) -> CGFloat { compact ? 196 : 252 }
    static func episodeImageHeight(compact: Bool) -> CGFloat {
        episodeWidth(compact: compact) * 9.0 / 16.0
    }
    static let titleBlockHeight: CGFloat = 46
    static func canonicalCellHeight(compact: Bool) -> CGFloat {
        DS.Poster.height(for: DS.Poster.railWidth(compact: compact)) + DS.Space.sm + titleBlockHeight
    }
}

private struct EpisodeRailCell: View {
    let item: MediaItem

    @Environment(\.labstreamCompactWidth) private var compactWidth

    private var width: CGFloat { HomeRailCellMetrics.episodeWidth(compact: compactWidth) }
    private var height: CGFloat { HomeRailCellMetrics.episodeImageHeight(compact: compactWidth) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            PosterImage(path: item.episodeRailArtworkPath,
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
        .frame(width: width,
               height: HomeRailCellMetrics.canonicalCellHeight(compact: compactWidth),
               alignment: .topLeading)
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

private extension MediaItem {
    /// Episode rails want a 16:9 still first. If a backend omits the episode still, fall back
    /// through backdrop-style art before using season/show posters so the card is less likely to
    /// be an empty tile.
    var episodeRailArtworkPath: String? {
        thumb ?? art ?? parentThumb ?? grandparentThumb
    }
}

/// A poster + title cell used in rails and grids.
///
/// Visual polish: a fixed 2:3 poster, a continue-watching progress sliver when the
/// item has a resume point, and a visionOS hover lift. The title block reserves a
/// stable height so rows of cells with 1- vs 2-line titles still align cleanly.
struct PosterCell: View {
    let item: MediaItem
    /// Explicit width from grid callers; nil means "rail default for this size class".
    var width: CGFloat?

    @Environment(\.labstreamCompactWidth) private var compactWidth

    private var resolvedWidth: CGFloat {
        width ?? DS.Poster.railWidth(compact: compactWidth)
    }

    /// Render at the item's real artwork ratio when the backend reports one (Jellyfin/Emby
    /// `PrimaryImageAspectRatio`: 16:9 YouTube, square Twitch, 16:9 episode stills), else the
    /// canonical 2:3 poster. Plex reports no ratio, so it stays 2:3 (GH #101).
    private var height: CGFloat {
        CGFloat(Double(resolvedWidth) / item.resolvedPosterAspect(fallback: Double(DS.Poster.aspect)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            PosterImage(path: item.thumb, width: resolvedWidth, height: height)
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
        .frame(width: resolvedWidth, alignment: .leading)
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
    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        VStack(alignment: .leading, spacing: compactWidth ? DS.Space.xl : DS.Space.xxxl) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                        .fill(.regularMaterial)
                        .frame(width: 200, height: 26)
                        .overlay { ShimmerView() }
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: compactWidth ? DS.Space.md : DS.Space.xl) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                                    .fill(.regularMaterial)
                                    .frame(width: DS.Poster.railWidth(compact: compactWidth),
                                           height: DS.Poster.height(for: DS.Poster.railWidth(compact: compactWidth)))
                                    .overlay { ShimmerView() }
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
                            }
                        }
                    }
                    .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth),
                                          clipDisabled: false)
                    .scrollDisabled(true)
                }
            }
        }
        .padding(.vertical, compactWidth ? DS.Space.lg : DS.Space.xl)
    }
}

/// Map a thrown error (often `PlexError`) to a short user-facing string.
func friendlyMessage(_ error: Error) -> String {
    // Labstream-authored playback messages (e.g. the DV P5 guard block, GH #196) are
    // already user-safe — surface them verbatim instead of redacting to a code.
    let nsError = error as NSError
    if nsError.domain == "Labstream.Playback",
       let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String {
        return message
    }
    if let plex = error as? PlexError {
        switch plex {
        case .unauthorized: return "Your session expired. Please sign in again."
        case .serverUnreachable: return "Couldn’t reach the server."
        case .http(let code): return "Server error (HTTP \(code))."
        case .decoding: return "Unexpected response from the server."
        }
    }
    return DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Loading")
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
