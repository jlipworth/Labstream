import SwiftUI
import PlexKit

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

    var body: some View {
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
            musicDestination(for: item)
        }
        .task(id: appModel.serverBaseURL) { await load() }
        .refreshable { await load() }
    }

    /// The section to browse: the explicit selection, else the first music section.
    private var selectedSection: PlexSection? {
        sections.first { $0.key == selectedSectionKey } ?? sections.first
    }

    private func load() async {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No reachable Plex server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.sections(server: server, token: token, identity: appModel.identity)
        do {
            let resp = try await appModel.client.send(req, as: SectionsResponse.self)
            sections = resp.mediaContainer.directory.filter(\.isMusic)
            if selectedSectionKey == nil { selectedSectionKey = sections.first?.key }
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
@ViewBuilder
func musicDestination(for item: MediaItem) -> some View {
    switch item.kind {
    case .artist: ArtistDetailView(artist: item)
    case .album: AlbumDetailView(album: item)
    // .playlist arrives with PlaylistDetailView in Phase 5.
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
    // case playlists — Phase 5.

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
    /// Ladder rung 2: Recently-Played albums synthesized from play history.
    @State private var historyAlbums: [MediaItem] = []
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
                if hubs.isEmpty && historyAlbums.isEmpty && fallbackAlbums.isEmpty {
                    ContentUnavailableView("Empty library",
                                           systemImage: "music.note",
                                           description: Text("No music in \(section.title)."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                        if !historyAlbums.isEmpty {
                            MusicRail(title: "Recently Played", items: historyAlbums)
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
        .refreshable { await load() }
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

    private func load() async {
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
            // Phase-0 evidence (MUSIC-DESIGN §8): what hubs does THIS PMS return, with
            // which identifiers and item types? Read back via `log show`.
            for hub in resp.mediaContainer.hub {
                NSLog("[VP] music hub: id=%@ title=%@ type=%@ size=%d",
                      hub.hubIdentifier ?? "nil", hub.title, hub.type ?? "nil",
                      hub.metadata.count)
            }
            hubs = resp.mediaContainer.hub.compactMap { hub in
                let items = hub.metadata.filter { $0.kind == .artist || $0.kind == .album }
                guard !items.isEmpty else { return nil }
                return Hub(hubKey: hub.hubKey, key: hub.key, title: hub.title,
                           type: hub.type, hubIdentifier: hub.hubIdentifier,
                           size: items.count, metadata: items)
            }

            // Rung 2 — no usable Recently-Played hub: synthesize it from history.
            // Prefix-match the identifier; exact ids drift across PMS versions.
            let hasPlayedHub = hubs.contains {
                ($0.hubIdentifier ?? "").hasPrefix("music.recent.played")
            }
            if !hasPlayedHub {
                historyAlbums = await loadHistoryAlbums(server: server, token: token)
            } else {
                historyAlbums = []
            }
            fallbackAlbums = []
            loadState = .loaded
        } catch {
            // Rung 3 — hubs failed entirely: degrade to exactly the old layout.
            hubs = []
            historyAlbums = []
            await loadFallback(server: server, token: token)
        }
    }

    /// Play history → unique albums, newest first: each track row contributes its
    /// album (`parentRatingKey`) once, so the rail navigates like any album cell.
    private func loadHistoryAlbums(server: URL, token: String) async -> [MediaItem] {
        let req = MusicRequest.playHistory(server: server, token: token,
                                           identity: appModel.identity,
                                           librarySectionID: section.key, count: 40)
        guard let resp = try? await appModel.client.send(req, as: MetadataResponse.self)
        else { return [] }

        var seen = Set<String>()
        var albums: [MediaItem] = []
        for item in resp.mediaContainer.metadata {
            guard let albumKey = item.parentRatingKey, seen.insert(albumKey).inserted
            else { continue }
            albums.append(MediaItem(ratingKey: albumKey,
                                    title: item.parentTitle ?? "Album",
                                    type: "album",
                                    thumb: item.parentThumb,
                                    parentTitle: item.grandparentTitle))
            if albums.count >= 20 { break }
        }
        return albums
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

/// Horizontal rail of square art cells — the shared hub-rail UI.
private struct MusicRail: View {
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
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, DS.Space.xxl)
                .padding(.vertical, DS.Space.sm)
            }
            .scrollClipDisabled() // let hover-lifted art breathe past the rail edge
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

// MARK: - Shared paged grid

/// Adaptive grid over a paged section listing: loads `pageSize` items, appends the
/// next page when the tail cell appears, stops when a short page arrives. Reloads
/// from page zero whenever `sortKey` changes.
private struct PagedArtGrid<SortMenu: View>: View {
    let section: PlexSection
    let sortKey: String
    let subtitle: (MediaItem) -> String?
    let request: (URL, String, ClientIdentity, Int) -> PlexRequest
    @ViewBuilder let sortMenu: () -> SortMenu

    @Environment(AppModel.self) private var appModel

    @State private var items: [MediaItem] = []
    @State private var loadState: HomeView.LoadState = .idle
    @State private var isLoadingMore = false
    @State private var reachedEnd = false

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
                if items.isEmpty {
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
                            ForEach(items) { item in
                                NavigationLink(value: item) {
                                    SquareArtCell(item: item, size: MusicArt.gridMin,
                                                  subtitle: subtitle(item))
                                }
                                .buttonStyle(.card)
                                .onAppear {
                                    if item.id == items.last?.id {
                                        Task { await loadMore() }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, DS.Space.xxl)

                        if isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DS.Space.lg)
                        }
                    }
                    .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .task(id: sortKey) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        reachedEnd = false
        do {
            let req = request(server, token, appModel.identity, 0)
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            items = resp.mediaContainer.metadata
            reachedEnd = items.count < musicGridPageSize
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, !reachedEnd,
              let server = appModel.serverBaseURL, let token = appModel.serverToken
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let req = request(server, token, appModel.identity, items.count)
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            let page = resp.mediaContainer.metadata
            // Dedupe defensively: a library edit between pages can shift offsets.
            let known = Set(items.map(\.ratingKey))
            items.append(contentsOf: page.filter { !known.contains($0.ratingKey) })
            reachedEnd = page.count < musicGridPageSize
        } catch {
            // A failed page is non-fatal: keep what we have; the tail cell retries
            // on its next appearance.
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
                .gazeHighlight(cornerRadius: artRadius)
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
        // NOTE (#20): the wrapping NavigationLink uses `.buttonStyle(.card)` (no automatic
        // hover effect); the gaze highlight is the explicit `.gazeHighlight()` on the art above.
    }
}
