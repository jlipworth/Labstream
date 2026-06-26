import SwiftUI
import PMSKit

/// Search tab: queries the active backend and renders normalized library/type groups
/// into the same Detail flow as browse. Debounced via `.task(id:)`.
///
/// Music results are faceted Plexamp-style (MUSIC-DESIGN §5): Artists and Albums
/// rails up top routing through the shared `musicDestination`, then a Songs list
/// whose rows PLAY on tap (tracks never navigate), then non-music library groups.
struct SearchView: View {
    @Environment(AppModel.self) private var appModel

    @State private var query = ""
    @State private var results: SearchResults = .empty
    @State private var loadState: HomeView.LoadState = .idle
    /// The query the current results were fetched for (pop-back no-op guard).
    @State private var loadedQuery: String?

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle:
                ContentUnavailableView("Search your libraries",
                                       systemImage: "magnifyingglass",
                                       description: Text("Find movies, shows, music, and more."))
                .frame(maxWidth: .infinity, minHeight: 300)
            case .loading:
                ProgressView("Searching…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .failed(let message):
                ContentUnavailableView("Search failed",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                .frame(maxWidth: .infinity, minHeight: 300)
            case .loaded:
                if nonMusicGroups.isEmpty && artistResults.isEmpty
                    && albumResults.isEmpty && trackResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                        // Music facets first, Plexamp order: Artists, Albums, Songs.
                        if !artistResults.isEmpty {
                            MusicRail(title: "Artists", items: artistResults)
                        }
                        if !albumResults.isEmpty {
                            MusicRail(title: "Albums", items: albumResults)
                        }
                        if !trackResults.isEmpty {
                            SearchSongsSection(tracks: trackResults)
                        }
                        ForEach(nonMusicGroups) { group in
                            SearchLibrarySection(group: group)
                        }
                    }
                    .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .navigationTitle("Search")
        .navigationDestination(for: MediaItem.self) { item in
            // Artist/album results resolve through the shared music routing; search
            // results are cross-section so there's no music sectionKey (the artist
            // view falls back to the children endpoint). Everything else keeps the
            // video Detail flow.
            if item.isMusicContainer {
                musicDestination(for: item, sectionKey: nil)
            } else {
                // Capture the active backend as the item's origin (#100) so actions resolve
                // against the source backend even after a backend switch.
                DetailView(item: item, originBackend: appModel.activeBackend)
            }
        }
        .searchable(text: $query, prompt: "Movies, shows, music…")
        .task(id: searchTaskID) {
            await runSearch()
        }
    }

    private var searchTaskID: String {
        "\(appModel.activeBrowseSessionKey):\(query)"
    }

    // MARK: - Faceting

    /// Non-music hubs, with any music items stripped from mixed hubs (they reappear
    /// above, faceted — stripping here is dedup, not hiding) and hubs left empty
    /// dropped. Local on purpose: the app-wide `hidingMusic` hide is gone (#17
    /// Phase 7) — Home now keeps music and only drops tracks.
    private var nonMusicGroups: [SearchResultGroup] {
        results.groups.compactMap { group -> SearchResultGroup? in
            let nonMusicHubs: [Hub] = group.hubs.compactMap { hub -> Hub? in
                let kept = hub.metadata.filter { !$0.isMusic }
                guard !kept.isEmpty else { return nil }
                return Hub(hubKey: hub.hubKey, key: hub.key, title: hub.title, type: hub.type,
                           hubIdentifier: hub.hubIdentifier, size: kept.count, metadata: kept)
            }
            guard !nonMusicHubs.isEmpty else { return nil }
            return SearchResultGroup(id: group.id, title: group.title, hubs: nonMusicHubs)
        }
    }

    private var artistResults: [MediaItem] { musicResults(of: .artist) }
    private var albumResults: [MediaItem] { musicResults(of: .album) }
    private var trackResults: [MediaItem] { musicResults(of: .track) }

    /// `/hubs/search` groups results into per-type hubs, but collect across ALL
    /// hubs (deduped) so a music item surfaced by an unexpected hub still facets.
    private func musicResults(of kind: MediaItem.Kind) -> [MediaItem] {
        var seen = Set<String>()
        return results.groups.flatMap(\.hubs).flatMap(\.metadata).filter {
            $0.kind == kind && seen.insert($0.ratingKey).inserted
        }
    }

    private func plexSearchSections(server: URL, token: String) async -> [PlexSection] {
        let req = BrowseAPI.sections(server: server, token: token, identity: appModel.identity)
        let response = try? await appModel.client.send(req, as: SectionsResponse.self)
        return response?.mediaContainer.directory ?? []
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = .empty
            loadState = .idle
            return
        }
        // `.task(id:)` re-fires on pop-back from a result with the query unchanged;
        // re-running then would flash the spinner and dump the scroll position.
        let searchKey = "\(appModel.activeBrowseSessionKey):\(trimmed)"
        if searchKey == loadedQuery, case .loaded = loadState { return }
        // Light debounce so we don't fire a request per keystroke.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }

        if appModel.activeBackend == .jellyfin {
            loadState = .loading
            do {
                let searchResults = try await JellyfinBrowseService(appModel: appModel)
                    .searchResults(query: trimmed)
                if Task.isCancelled { return }
                results = searchResults
                loadedQuery = searchKey
                loadState = .loaded
            } catch {
                if Task.isCancelled { return }
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        if appModel.activeBackend == .emby {
            loadState = .loading
            do {
                let searchResults = try await EmbyBrowseService(appModel: appModel)
                    .searchResults(query: trimmed)
                if Task.isCancelled { return }
                results = searchResults
                loadedQuery = searchKey
                loadState = .loaded
            } catch {
                if Task.isCancelled { return }
                loadState = .failed(friendlyMessage(error))
            }
            return
        }

        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.search(server: server, token: token,
                                   identity: appModel.identity, query: trimmed)
        do {
            async let searchResponse = appModel.client.send(req, as: HubsResponse.self)
            async let sections = plexSearchSections(server: server, token: token)
            let resp = try await searchResponse
            let plexSections = await sections
            if Task.isCancelled { return }
            results = .plexNativeHubs(resp.mediaContainer.hub, sections: plexSections)
            loadedQuery = searchKey
            loadState = .loaded
        } catch {
            if Task.isCancelled { return }
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One source-library section containing one or more type/native result hubs.
private struct SearchLibrarySection: View {
    let group: SearchResultGroup

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            Text(group.title)
                .font(.title.bold())
                .padding(.horizontal, DS.Space.xxl)

            ForEach(group.hubs) { hub in
                SearchHubSection(hub: hub)
            }
        }
    }
}

/// One titled section of search results (a hub) rendered as a horizontal rail.
private struct SearchHubSection: View {
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
            // contentMargins, not .padding on the lazy content — see the hit-region
            // gotcha in docs/DEVELOPMENT.md (padding shifts gaze/hit shapes left).
            .contentMargins(.horizontal, DS.Space.xxl, for: .scrollContent)
            .scrollClipDisabled()
        }
    }
}

// MARK: - Songs facet

/// How many song rows show before the "Show all" expander.
private let songsCollapsedCount = 5
/// Queue cap when a song is tapped (matches the rail-replay pattern).
private let songsQueueCap = 20

/// Vertical list of track results on a material card. Tapping a row PLAYS it with
/// the rest of the song results queued behind it — tracks never navigate. Search
/// hub rows are skinny (no Media/Part), so a tap re-fetches full metadata for the
/// queue in one comma-keyed request first (the `MusicTrackRail.play` pattern).
private struct SearchSongsSection: View {
    let tracks: [MediaItem]

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player

    @State private var showAll = false
    @State private var isStarting = false
    @State private var playError: String?

    private var visibleTracks: [MediaItem] {
        showAll ? tracks : Array(tracks.prefix(songsCollapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Songs")
                .font(.title2.bold())
                .padding(.horizontal, DS.Space.xxl)

            VStack(spacing: 0) {
                ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        Task { await play(from: track) }
                    } label: {
                        SearchTrackRow(track: track,
                                       isCurrent: player.current?.ratingKey == track.ratingKey)
                    }
                    .cardLink(cornerRadius: DS.Radius.chip)
                    .disabled(isStarting)
                    // Queue actions (#17 Phase 4). Search rows are skinny (no
                    // Media/Part), so each action re-fetches full metadata first.
                    .contextMenu {
                        Button {
                            Task { await enqueue(track, .playNext) }
                        } label: {
                            Label("Play Next",
                                  systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button {
                            Task { await enqueue(track, .addToQueue) }
                        } label: {
                            Label("Add to Queue",
                                  systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                    }

                    if index < visibleTracks.count - 1 {
                        Divider().padding(.leading, DS.Space.xxl + DS.Space.lg)
                    }
                }

                if tracks.count > songsCollapsedCount {
                    Divider().padding(.leading, DS.Space.xxl + DS.Space.lg)
                    Button {
                        withAnimation { showAll.toggle() }
                    } label: {
                        Label(showAll ? "Show fewer" : "Show all \(tracks.count) songs",
                              systemImage: showAll ? "chevron.up" : "chevron.down")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DS.Space.lg)
                            .padding(.vertical, DS.Space.md)
                            .contentShape(Rectangle())
                            .padding(.horizontal, DS.Space.sm)
                    }
                    .cardLink(cornerRadius: DS.Radius.chip)
                }
            }
            .padding(.vertical, DS.Space.sm)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .padding(.horizontal, DS.Space.xxl)

            if let playError {
                Label(playError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, DS.Space.xxl)
            }
        }
    }

    private enum QueueAction { case playNext, addToQueue }

    /// Context-menu queue action: hydrate the skinny search row into a full
    /// track (Media/Part) with one metadata request, then hand it to the player.
    private func enqueue(_ track: MediaItem, _ action: QueueAction) async {
        playError = nil

        // MediaBrowser rows are already playable by id — enqueue directly.
        guard appModel.activeBackend == .plex else {
            switch action {
            case .playNext: player.playNext([track])
            case .addToQueue: player.addToQueue([track])
            }
            return
        }

        // Plex: hydrate the skinny search row into a full track (Media/Part) first.
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else { return }
        let req = BrowseAPI.metadata(server: server, token: token,
                                     identity: appModel.identity,
                                     ratingKey: track.ratingKey)
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            guard let full = resp.mediaContainer.metadata.first(where: { $0.kind == .track }) else {
                playError = "Couldn’t load that song."
                return
            }
            switch action {
            case .playNext: player.playNext([full])
            case .addToQueue: player.addToQueue([full])
            }
        } catch {
            playError = friendlyMessage(error)
        }
    }

    private func play(from tapped: MediaItem) async {
        isStarting = true
        playError = nil
        defer { isStarting = false }

        // MediaBrowser audio rows are already playable by id (the universal stream
        // endpoint needs only the item id), so queue them directly.
        guard appModel.activeBackend == .plex else {
            let queue = Array(tracks.prefix(songsQueueCap))
            guard !queue.isEmpty else { return }
            let index = queue.firstIndex { $0.ratingKey == tapped.ratingKey } ?? 0
            player.play(tracks: queue, startingAt: index)
            return
        }

        // Plex search rows are skinny (no Media/Part) — re-fetch full metadata so the
        // tracks carry a playable part key.
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else { return }
        // Queue = the song results (capped), starting at the tapped one; if the
        // tapped track somehow falls outside the cap, play it alone.
        var keys = tracks.prefix(songsQueueCap).map(\.ratingKey)
        if !keys.contains(tapped.ratingKey) { keys = [tapped.ratingKey] }
        let req = BrowseAPI.metadata(server: server, token: token,
                                     identity: appModel.identity,
                                     ratingKey: keys.joined(separator: ","))
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            let full = resp.mediaContainer.metadata.filter { $0.kind == .track }
            guard !full.isEmpty else {
                playError = "Couldn’t load that song."
                return
            }
            let index = full.firstIndex { $0.ratingKey == tapped.ratingKey } ?? 0
            player.play(tracks: full, startingAt: index)
        } catch {
            playError = friendlyMessage(error)
        }
    }
}

/// One song result row: 44-pt album art, title, artist · album, duration, and a
/// play glyph (tinted waveform when it's the playing track). Sibling of
/// `AlbumDetailView`'s TrackRow with art instead of a track number.
private struct SearchTrackRow: View {
    let track: MediaItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            PosterImage(path: track.musicArtPath, width: 44, height: 44,
                        cornerRadius: DS.Radius.chip)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                // On a *track*, `grandparentTitle` is the artist and `parentTitle`
                // the album (artist → album → track).
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Space.md)

            if let duration = track.duration {
                Text(formatSongDuration(milliseconds: duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Image(systemName: isCurrent ? "waveform" : "play.fill")
                .font(.subheadline)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .contentShape(Rectangle())
        // Highlight comes from the wrapping button's `.cardLink(cornerRadius: .chip)` —
        // a custom ButtonStyle misroutes pinches to neighboring rows (DEVELOPMENT.md).
        // The outer inset keeps the row highlight clear of the card's corner curve.
        .padding(.horizontal, DS.Space.sm)
    }

    private var subtitle: String {
        [track.grandparentTitle, track.parentTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Format a song duration as `m:ss`, or `h:mm:ss` at an hour or more.
private func formatSongDuration(milliseconds: Int) -> String {
    let total = milliseconds / 1000
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}
