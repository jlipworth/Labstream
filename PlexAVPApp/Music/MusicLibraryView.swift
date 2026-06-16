import SwiftUI
import PMSKit

/// Music tab root: the Plexamp-style entry point for the server's music libraries
/// (`artist`-type sections). One music section renders inline; multiple sections get
/// a picker; zero sections shows a friendly empty state.
///
/// This view also owns the music navigation routing: artist and album items pushed
/// from anywhere in this stack resolve through the shared `musicDestination(for:)`.
struct MusicLibraryView: View {
    @Environment(AppModel.self) private var appModel

    @State private var sections: [PlexSection] = []
    @State private var loadState: HomeView.LoadState = .idle
    /// Key of the section the user is browsing (only meaningful with 2+ sections).
    @State private var selectedSectionKey: String?
    /// The server the current sections were loaded from (pop-back no-op guard).
    @State private var loadedServer: URL?

    var body: some View {
        if appModel.activeBackend == .jellyfin {
            ContentUnavailableView("Jellyfin music is not in this slice",
                                   systemImage: "music.note",
                                   description: Text("This branch is focused on Jellyfin video login, browse, and playback."))
                .navigationTitle("Music")
        } else {
        Group {
            switch loadState {
            case .idle, .loading:
                ProgressView("Loading…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView("Couldn’t load Music",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .loaded:
                if sections.isEmpty {
                    ContentUnavailableView("No Music Libraries",
                                           systemImage: "music.note",
                                           description: Text("This server has no music libraries."))
                } else if let section = selectedSection {
                    MusicHomeView(section: section)
                        .id(section.key) // reset pivot/scroll/load when switching libraries
                }
            }
        }
        .navigationTitle("Music")
        .toolbar {
            // Library switcher only when the server has more than one music section.
            if sections.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Library", selection: $selectedSectionKey) {
                        ForEach(sections) { section in
                            Text(section.title).tag(Optional(section.key))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .navigationDestination(for: MediaItem.self) { item in
            musicDestination(for: item, sectionKey: selectedSection?.key)
        }
        .task(id: appModel.serverBaseURL) { await load() }
        .refreshable { await load(force: true) }
        }
    }

    /// The section to browse: the explicit selection, else the first music section.
    private var selectedSection: PlexSection? {
        sections.first { $0.key == selectedSectionKey } ?? sections.first
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires every time the stack pops back to this root view; without
        // this guard the reload tears down MusicHomeView and resets the pivot/scroll
        // state the user is popping back TO (live bug: Back always landed on a fresh
        // Home pivot). Only pull-to-refresh and a real server change refetch.
        if !force, loadedServer == appModel.serverBaseURL, case .loaded = loadState { return }
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No reachable Plex server selected.")
            return
        }
        if case .loaded = loadState {} else { loadState = .loading }
        let req = BrowseAPI.sections(server: server, token: token, identity: appModel.identity)
        do {
            let resp = try await appModel.client.send(req, as: SectionsResponse.self)
            sections = resp.mediaContainer.directory.filter(\.isMusic)
            if selectedSectionKey == nil { selectedSectionKey = sections.first?.key }
            loadedServer = server
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

// MARK: - Shared music routing

/// The one place a music `MediaItem` resolves to a destination view, shared by the
/// Music tab and (Phase 3) SearchView. Tracks never navigate — they play — so there
/// is deliberately no `.track` destination (MUSIC-DESIGN §2).
///
/// `sectionKey` enables the artist.id discography search; callers without one
/// (e.g. cross-section search results) pass nil and the artist view falls back
/// to the children endpoint.
@ViewBuilder
func musicDestination(for item: MediaItem, sectionKey: String?) -> some View {
    switch item.kind {
    case .artist: ArtistDetailView(artist: item, sectionKey: sectionKey)
    case .album: AlbumDetailView(album: item)
    case .playlist: PlaylistDetailView(playlist: item)
    default: EmptyView()
    }
}

// MARK: - Pivot shell

/// The four-way (v1: three-way) pivot inside the Music tab — MUSIC-DESIGN §2 chose a
/// pivot over a sidebar: one control + a `switch`, near-zero regression surface, and
/// each pivot view is self-contained so a later sidebar swap stays cheap.
private enum MusicPivot: String, CaseIterable, Identifiable {
    case home = "Home"
    case artists = "Artists"
    case albums = "Albums"
    case playlists = "Playlists"

    var id: String { rawValue }
}

/// One music section: pivot control on top, the selected pivot below. Replaces the
/// old single-scroll MusicSectionBrowseView (rail + full artist dump).
private struct MusicHomeView: View {
    let section: PlexSection

    @State private var pivot: MusicPivot = .home

    var body: some View {
        VStack(spacing: 0) {
            Picker("Browse", selection: $pivot) {
                ForEach(MusicPivot.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            .padding(.top, DS.Space.md)
            .padding(.bottom, DS.Space.sm)

            // Each pivot owns its load state and scroll position; `id` keeps them
            // alive across switches only within one section (parent resets by key).
            switch pivot {
            case .home: MusicHomePivot(section: section)
            case .artists: MusicArtistsPivot(section: section)
            case .albums: MusicAlbumsPivot(section: section)
            case .playlists: MusicPlaylistsPivot()
            }
        }
    }
}

// MARK: - Home pivot (hub rails + Shuffle Library)

/// Server-driven hub rails with the never-a-blank-screen ladder (MUSIC-DESIGN §3.1):
///   1. `/hubs/sections/{key}` hubs, rendered generically in server order;
///   2. no usable Recently-Played hub → synthesize the rail from play history;
///   3. hubs failed entirely → the old layout (Recently Added rail + Artists nudge).
private struct MusicHomePivot: View {
    let section: PlexSection

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player

    /// Hubs that survived filtering (artist/album items only, non-empty).
    @State private var hubs: [Hub] = []
    /// Recently-Played SONGS from play history — always shown first, replacing the
    /// server's `music.recent.played` hub (which carries artists; Plexamp-style
    /// recents are the tracks themselves).
    @State private var historyTracks: [MediaItem] = []
    /// Ladder rung 3: recently-added albums when hubs failed entirely.
    @State private var fallbackAlbums: [MediaItem] = []
    @State private var loadState: HomeView.LoadState = .idle
    @State private var isShuffling = false
    @State private var shuffleError: String?

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                MusicSkeleton()
            case .failed(let message):
                ContentUnavailableView("Couldn’t load \(section.title)",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .loaded:
                if hubs.isEmpty && historyTracks.isEmpty && fallbackAlbums.isEmpty {
                    ContentUnavailableView("Empty library",
                                           systemImage: "music.note",
                                           description: Text("No music in \(section.title)."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                        if !historyTracks.isEmpty {
                            MusicTrackRail(title: "Recently Played", tracks: historyTracks)
                        }
                        ForEach(hubs) { hub in
                            MusicRail(title: hub.title, items: hub.metadata)
                        }
                        if !fallbackAlbums.isEmpty {
                            MusicRail(title: "Recently Added", items: fallbackAlbums)
                            Text("Browse everything from the Artists and Albums pivots above.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, DS.Space.xxl)
                        }
                        shuffleButton
                    }
                    .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private var shuffleButton: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Button {
                Task { await shuffleLibrary() }
            } label: {
                Label(isShuffling ? "Shuffling…" : "Shuffle Library",
                      systemImage: "shuffle")
                    .font(.headline)
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.xs)
            }
            .buttonStyle(.bordered)
            .disabled(isShuffling)

            if let shuffleError {
                Label(shuffleError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.top, DS.Space.md)
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires on every pop-back/tab-return; reloading then would swap
        // the rails for the skeleton and throw away scroll position. Refresh only
        // on first load or explicit pull-to-refresh.
        if !force, case .loaded = loadState { return }
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        do {
            // Rung 1 — server hubs, rendered generically. v1 keeps artist/album hub
            // items only (track rows need play affordances first — v2); empty hubs drop.
            let hubsReq = MusicRequest.sectionHubs(server: server, token: token,
                                                   identity: appModel.identity,
                                                   sectionKey: section.key)
            let resp = try await appModel.client.send(hubsReq, as: HubsResponse.self)
            hubs = resp.mediaContainer.hub.compactMap { hub in
                // The played hub carries ARTISTS; our history-songs rail replaces it.
                // Prefix-match the identifier; exact ids drift across PMS versions.
                if (hub.hubIdentifier ?? "").hasPrefix("music.recent.played") { return nil }
                let items = hub.metadata.filter { $0.kind == .artist || $0.kind == .album }
                guard !items.isEmpty else { return nil }
                return Hub(hubKey: hub.hubKey, key: hub.key, title: hub.title,
                           type: hub.type, hubIdentifier: hub.hubIdentifier,
                           size: items.count, metadata: items)
            }

            historyTracks = await loadHistoryTracks(server: server, token: token)
            fallbackAlbums = []
            loadState = .loaded
        } catch {
            // Rung 3 — hubs failed entirely: degrade to exactly the old layout.
            hubs = []
            historyTracks = []
            await loadFallback(server: server, token: token)
        }
    }

    /// Play history → unique recently-played SONGS, newest first. History rows are
    /// skinny (no Media/Part) — the rail re-fetches full metadata on tap to play.
    private func loadHistoryTracks(server: URL, token: String) async -> [MediaItem] {
        let req = MusicRequest.playHistory(server: server, token: token,
                                           identity: appModel.identity,
                                           librarySectionID: section.key, count: 40)
        guard let resp = try? await appModel.client.send(req, as: MetadataResponse.self)
        else { return [] }

        var seen = Set<String>()
        var tracks: [MediaItem] = []
        for item in resp.mediaContainer.metadata where item.kind == .track {
            guard seen.insert(item.ratingKey).inserted else { continue }
            tracks.append(item)
            if tracks.count >= 20 { break }
        }
        return tracks
    }

    private func loadFallback(server: URL, token: String) async {
        let req = MusicRequest.recentlyAddedAlbums(server: server, token: token,
                                                   identity: appModel.identity,
                                                   sectionKey: section.key)
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            fallbackAlbums = resp.mediaContainer.metadata
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }

    /// ONE un-paged random page → shuffle-play. Never page `sort=random`: PMS
    /// re-randomizes per container page, producing duplicates (MUSIC-DESIGN §3.1).
    private func shuffleLibrary() async {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else { return }
        isShuffling = true
        shuffleError = nil
        defer { isShuffling = false }
        let req = MusicRequest.randomTracks(server: server, token: token,
                                            identity: appModel.identity,
                                            sectionKey: section.key)
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            let tracks = resp.mediaContainer.metadata.filter { $0.kind == .track }
            guard !tracks.isEmpty else {
                shuffleError = "No tracks to shuffle."
                return
            }
            player.playAlbumShuffled(tracks: tracks)
        } catch {
            shuffleError = friendlyMessage(error)
        }
    }
}

/// Horizontal rail of square art cells — the shared hub-rail UI (also the shelf
/// unit on `ArtistDetailView`, hence not private).
struct MusicRail: View {
    let title: String
    let items: [MediaItem]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal, DS.Space.xxl)

            ScrollView(.horizontal) {
                LazyHStack(spacing: DS.Space.xl) {
                    ForEach(items.prefix(20)) { item in
                        NavigationLink(value: item) {
                            SquareArtCell(item: item,
                                          size: MusicArt.railSize,
                                          subtitle: item.parentTitle)
                        }
                        .cardLink()
                    }
                }
                .padding(.vertical, DS.Space.sm)
            }
            // contentMargins, not .padding on the lazy content — see the hit-region
            // gotcha in docs/DEVELOPMENT.md (padding shifts gaze/hit shapes left).
            .contentMargins(.horizontal, DS.Space.xxl, for: .scrollContent)
            .scrollClipDisabled() // let hover-lifted art breathe past the rail edge
        }
    }
}

/// Horizontal rail of recently-played SONGS. Tap REPLAYS (Plexamp's Recent Plays
/// behavior — items replay, they don't navigate). History rows are skinny (no
/// Media/Part), so a tap fetches full metadata for the whole rail in one
/// comma-keyed request and queues it starting from the tapped song.
private struct MusicTrackRail: View {
    let title: String
    let tracks: [MediaItem]

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player

    @State private var isStarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal, DS.Space.xxl)

            ScrollView(.horizontal) {
                LazyHStack(spacing: DS.Space.xl) {
                    ForEach(tracks.prefix(20)) { track in
                        Button {
                            Task { await play(from: track) }
                        } label: {
                            SquareArtCell(item: displayItem(for: track),
                                          size: MusicArt.railSize,
                                          subtitle: track.grandparentTitle)
                        }
                        .cardLink()
                        .disabled(isStarting)
                    }
                }
                .padding(.vertical, DS.Space.sm)
            }
            // contentMargins, not .padding on the lazy content — see the hit-region
            // gotcha in docs/DEVELOPMENT.md (padding shifts gaze/hit shapes left).
            .contentMargins(.horizontal, DS.Space.xxl, for: .scrollContent)
            .scrollClipDisabled() // let hover-lifted art breathe past the rail edge
        }
    }

    /// Track cells show the resolved music art (album cover; track thumbs 404 here).
    private func displayItem(for track: MediaItem) -> MediaItem {
        MediaItem(ratingKey: track.ratingKey, title: track.title,
                  type: track.type, thumb: track.musicArtPath)
    }

    private func play(from tapped: MediaItem) async {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else { return }
        isStarting = true
        defer { isStarting = false }
        let keys = tracks.prefix(20).map(\.ratingKey).joined(separator: ",")
        let req = BrowseAPI.metadata(server: server, token: token,
                                     identity: appModel.identity, ratingKey: keys)
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            let full = resp.mediaContainer.metadata.filter { $0.kind == .track }
            guard !full.isEmpty else { return }
            let index = full.firstIndex { $0.ratingKey == tapped.ratingKey } ?? 0
            player.play(tracks: full, startingAt: index)
        } catch {
            AppDiagnostics.record(.music, "music.recently_played_replay_failed", fields: [
                "error": .error(error),
                "candidate_count": .int(tracks.count),
            ])
            NSLog("[VP] recently-played replay failed: %@", String(describing: error))
        }
    }
}

/// One container page for the pivot grids; load-more appends a page at a time.
private let musicGridPageSize = 200

// MARK: - Artists pivot (paged, sorted grid)

private struct MusicArtistsPivot: View {
    let section: PlexSection

    private enum Sort: String, CaseIterable, Identifiable {
        case name = "titleSort"
        case recentlyAdded = "addedAt:desc"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: "Name"
            case .recentlyAdded: "Recently Added"
            }
        }
    }

    @State private var sort: Sort = .name

    var body: some View {
        PagedArtGrid(section: section,
                     sortKey: sort.rawValue,
                     subtitle: { _ in nil },
                     request: { server, token, identity, start in
                         MusicRequest.artists(server: server, token: token,
                                              identity: identity,
                                              sectionKey: section.key,
                                              sort: sort.rawValue,
                                              containerStart: start,
                                              containerSize: musicGridPageSize)
                     },
                     sortMenu: {
                         sortMenu
                     })
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { s in Text(s.label).tag(s) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .font(.callout)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Albums pivot (new, paged grid)

private struct MusicAlbumsPivot: View {
    let section: PlexSection

    private enum Sort: String, CaseIterable, Identifiable {
        case recentlyAdded = "addedAt:desc"
        case title = "titleSort"
        case year = "originallyAvailableAt:desc"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recentlyAdded: "Recently Added"
            case .title: "Title"
            case .year: "Year"
            }
        }
    }

    @State private var sort: Sort = .recentlyAdded

    var body: some View {
        PagedArtGrid(section: section,
                     sortKey: sort.rawValue,
                     subtitle: { album in
                         // "Artist · 1973" — drop whichever half is missing.
                         [album.parentTitle, album.year.map(String.init)]
                             .compactMap { $0 }
                             .joined(separator: " · ")
                     },
                     request: { server, token, identity, start in
                         MusicRequest.albums(server: server, token: token,
                                             identity: identity,
                                             sectionKey: section.key,
                                             sort: sort.rawValue,
                                             containerStart: start,
                                             containerSize: musicGridPageSize)
                     },
                     sortMenu: {
                         sortMenu
                     })
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { s in Text(s.label).tag(s) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .font(.callout)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Playlists pivot (read-only v1, MUSIC-DESIGN §3.4)

/// Audio playlists as card rows — 56-pt composite art, title, "N tracks". Playlists
/// live OUTSIDE the section tree (`GET /playlists?playlistType=audio` is server-wide),
/// so unlike the other pivots this takes no section; the toolbar library Picker does
/// not scope it. Rows push `PlaylistDetailView` via the shared `musicDestination`.
private struct MusicPlaylistsPivot: View {
    @Environment(AppModel.self) private var appModel

    @State private var playlists: [MediaItem] = []
    @State private var loadState: HomeView.LoadState = .idle

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                MusicSkeleton()
            case .failed(let message):
                ContentUnavailableView("Couldn’t load Playlists",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .loaded:
                if playlists.isEmpty {
                    ContentUnavailableView("No Playlists",
                                           systemImage: "music.note.list",
                                           description: Text("This server has no audio playlists."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    playlistList
                        .padding(.horizontal, DS.Space.xxl)
                        .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    /// One material card of playlist rows, hairline-separated — the same card-of-rows
    /// treatment as the album track list, at list (not track) density.
    private var playlistList: some View {
        VStack(spacing: 0) {
            ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                NavigationLink(value: playlist) {
                    PlaylistRow(playlist: playlist)
                }
                .cardLink(cornerRadius: DS.Radius.chip)

                if index < playlists.count - 1 {
                    Divider().padding(.leading, DS.Space.xxl + DS.Space.lg)
                }
            }
        }
        .padding(.vertical, DS.Space.sm)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private func load() async {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let req = PlaylistRequest.audioPlaylists(server: server, token: token,
                                                 identity: appModel.identity)
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            playlists = resp.mediaContainer.metadata.filter { $0.kind == .playlist }
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One playlist row: 56-pt composite art, title, "N tracks". Row height clears the
/// 60-pt gaze target with the card paddings.
private struct PlaylistRow: View {
    let playlist: MediaItem

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            PosterImage(path: playlist.musicArtPath, width: 56, height: 56,
                        cornerRadius: DS.Radius.chip)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.body)
                    .lineLimit(1)
                if let count = playlist.leafCount {
                    Text("^[\(count) track](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: DS.Space.md)

            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .contentShape(Rectangle())
        // Highlight comes from the wrapping button's `.cardLink(cornerRadius: .chip)` —
        // a custom ButtonStyle misroutes pinches to neighboring rows (DEVELOPMENT.md).
        // The outer inset keeps the row highlight clear of the card's corner curve.
        .padding(.horizontal, DS.Space.sm)
    }
}

// MARK: - Shared paged grid

/// Adaptive grid over a paged section listing, pre-sized to the section's FULL
/// `totalSize`: every row exists from the start (unloaded ones as shimmer
/// placeholders), so the scrollbar's range spans the whole library and dragging it
/// to the bottom lands on the true end of the list. A placeholder appearing fetches
/// exactly the page that contains it (random access via `X-Plex-Container-Start`),
/// so a long-distance drag loads what the viewport shows — not everything between.
/// Reloads from scratch whenever `sortKey` changes.
private struct PagedArtGrid<SortMenu: View>: View {
    let section: PlexSection
    let sortKey: String
    let subtitle: (MediaItem) -> String?
    let request: (URL, String, ClientIdentity, Int) -> PlexRequest
    @ViewBuilder let sortMenu: () -> SortMenu

    @Environment(AppModel.self) private var appModel

    /// One slot per item in the full listing; `nil` = not fetched yet.
    @State private var slots: [MediaItem?] = []
    @State private var loadState: HomeView.LoadState = .idle
    /// Page indices currently in flight (a failed page is removed so a placeholder
    /// re-appearing retries it).
    @State private var loadingPages: Set<Int> = []
    /// The sort the current `slots` were loaded under — `.task(id: sortKey)` also
    /// re-fires on pop-back/reappear, and only a real sort CHANGE should reload
    /// (a reload would dump the user's scroll position back to the top).
    @State private var loadedSortKey: String?

    private let columns = [GridItem(.adaptive(minimum: MusicArt.gridMin, maximum: MusicArt.gridMax),
                                    spacing: DS.Space.xl)]

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                MusicSkeleton()
            case .failed(let message):
                ContentUnavailableView("Couldn’t load \(section.title)",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .loaded:
                if slots.isEmpty {
                    ContentUnavailableView("Empty library",
                                           systemImage: "music.note",
                                           description: Text("No music in \(section.title)."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.lg) {
                        HStack {
                            Spacer()
                            sortMenu()
                        }
                        .padding(.horizontal, DS.Space.xxl)

                        LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
                            // Position-keyed: a slot's identity is its place in the
                            // listing; its content arrives when the page loads.
                            ForEach(slots.indices, id: \.self) { index in
                                if let item = slots[index] {
                                    NavigationLink(value: item) {
                                        SquareArtCell(item: item, size: MusicArt.gridMin,
                                                      subtitle: subtitle(item))
                                    }
                                    .cardLink()
                                } else {
                                    placeholderCell
                                        .onAppear {
                                            Task { await loadPage(containing: index) }
                                        }
                                }
                            }
                        }
                        .padding(.horizontal, DS.Space.xxl)
                    }
                    .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .task(id: sortKey) { await load() }
        .refreshable { await load(force: true) }
    }

    /// Shimmer stand-in matching a loaded cell's footprint (art + one text line).
    private var placeholderCell: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: MusicArt.gridMin, height: MusicArt.gridMin)
                .overlay { ShimmerView() }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: MusicArt.gridMin * 0.6, height: 16)
        }
        .frame(width: MusicArt.gridMin, alignment: .leading)
    }

    private func load(force: Bool = false) async {
        // Reappear-driven `.task` runs are no-ops once loaded; only a sort change
        // or pull-to-refresh rebuilds the slots (and so resets scroll).
        if !force, loadedSortKey == sortKey, case .loaded = loadState { return }
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        loadingPages = []
        do {
            let req = request(server, token, appModel.identity, 0)
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            let page = resp.mediaContainer.metadata
            // Pre-size to the full listing so the scroll range is the whole library;
            // no totalSize (shouldn't happen on a paged request) degrades to page 1.
            let total = max(resp.mediaContainer.totalSize ?? page.count, page.count)
            var fresh = [MediaItem?](repeating: nil, count: total)
            for (i, item) in page.enumerated() { fresh[i] = item }
            slots = fresh
            loadedSortKey = sortKey
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }

    /// Fetch the fixed-size page containing `index` and fill its slots in place.
    private func loadPage(containing index: Int) async {
        let page = index / musicGridPageSize
        guard !loadingPages.contains(page),
              let server = appModel.serverBaseURL, let token = appModel.serverToken
        else { return }
        loadingPages.insert(page)
        let start = page * musicGridPageSize
        do {
            let req = request(server, token, appModel.identity, start)
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            for (i, item) in resp.mediaContainer.metadata.enumerated()
            where slots.indices.contains(start + i) {
                slots[start + i] = item
            }
        } catch {
            // Non-fatal: drop the in-flight mark so the placeholder retries when
            // it next appears.
            loadingPages.remove(page)
        }
    }
}

/// Shimmering placeholder mirroring the rail-above-grid layout while a section loads.
private struct MusicSkeleton: View {
    private let columns = [GridItem(.adaptive(minimum: MusicArt.gridMin, maximum: MusicArt.gridMax),
                                    spacing: DS.Space.xl)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxxl) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                skeletonBlock(width: 220, height: 26, radius: DS.Radius.chip)
                    .padding(.horizontal, DS.Space.xxl)
                HStack(spacing: DS.Space.xl) {
                    ForEach(0..<5, id: \.self) { _ in
                        skeletonBlock(width: MusicArt.railSize, height: MusicArt.railSize,
                                      radius: DS.Radius.poster)
                    }
                }
                .padding(.horizontal, DS.Space.xxl)
            }

            LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
                ForEach(0..<8, id: \.self) { _ in
                    skeletonBlock(width: MusicArt.gridMin, height: MusicArt.gridMin,
                                  radius: DS.Radius.poster)
                }
            }
            .padding(.horizontal, DS.Space.xxl)
        }
        .padding(.vertical, DS.Space.xl)
    }

    private func skeletonBlock(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.regularMaterial)
            .frame(width: width, height: height)
            .overlay { ShimmerView() }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Shared music cell & geometry

extension MediaItem {
    /// Best artwork path for a music item. Proven live against this PMS: track-level
    /// `thumb` paths 404 (PMS advertises them anyway), and a `…/thumb/-1` suffix is
    /// the server's "no art" sentinel (also a 404). So tracks prefer the album cover
    /// (`parentThumb`), then artist art; everything skips `/-1` paths.
    var musicArtPath: String? {
        let candidates: [String?]
        switch kind {
        case .track: candidates = [parentThumb, grandparentThumb, thumb, art]
        // A playlist's art is its server-built mosaic (`composite`); no `thumb`.
        case .playlist: candidates = [composite, thumb, art]
        default: candidates = [thumb, parentThumb, art]
        }
        return candidates.compactMap { $0 }.first { !$0.hasSuffix("/-1") }
    }
}

/// Square-art geometry for music (album covers and artist portraits are 1:1, unlike
/// the 2:3 posters in `DS.Poster`). Internal so every music view shares one scale.
enum MusicArt {
    /// Album cell size in the hub rails.
    static let railSize: CGFloat = 184
    /// Adaptive grid bounds for artist/album cells.
    static let gridMin: CGFloat = 168
    static let gridMax: CGFloat = 208
}

/// Square artwork + title (+ optional subtitle) cell shared by the music rails and
/// grids — the music counterpart of `PosterCell`. Artist art renders circular
/// (the music-app idiom that visually separates people from records).
struct SquareArtCell: View {
    let item: MediaItem
    var size: CGFloat = MusicArt.gridMin
    /// Optional second line (e.g. artist name on an album, year on a discography cell).
    var subtitle: String? = nil

    private var artRadius: CGFloat {
        item.kind == .artist ? size / 2 : DS.Radius.poster
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            PosterImage(path: item.thumb, width: size, height: size,
                        cornerRadius: artRadius)
                .posterHover()

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: size, alignment: .leading)
        // NOTE: highlight comes from the wrapping link's `.cardLink()` — a custom
        // ButtonStyle here misroutes pinches to neighboring cards (DEVELOPMENT.md).
    }
}
