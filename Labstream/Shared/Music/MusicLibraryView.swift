import SwiftUI
import PMSKit

/// Music tab root: the Plexamp-style entry point for the server's music libraries
/// (`artist`-type sections). One music section renders inline; multiple sections get
/// a picker; zero sections shows a friendly empty state.
///
/// This view also owns the music navigation routing: artist and album items pushed
/// from anywhere in this stack resolve through the shared `musicDestination(for:)`.
struct MusicLibraryView: View {
    let macPivot: MusicPivot?
    let allowedLibraryIDs: Set<String>?
    private let catalogRepository: LibraryCatalogRepository
    private let externalSelectedLibraryID: Binding<String?>?
    @Environment(AppModel.self) private var appModel

    @State private var sections: [PlexSection] = []
    @State private var loadState: BrowseLoadState = .idle
    /// Key of the section the user is browsing (only meaningful with 2+ sections).
    @State private var selectedSectionKey: String?
    /// Server identity the current sections were loaded from (pop-back no-op guard).
    /// Includes selected Plex server id because multiple servers can share the same base URL.
    @State private var loadedIdentity: MusicCatalogLoadIdentity?
    @State private var loadGeneration = 0

    init(macPivot: MusicPivot? = nil,
         selectedLibraryID: Binding<String?>? = nil,
         allowedLibraryIDs: Set<String>? = nil,
         catalogRepository: LibraryCatalogRepository) {
        self.macPivot = macPivot
        self.externalSelectedLibraryID = selectedLibraryID
        self.allowedLibraryIDs = allowedLibraryIDs
        self.catalogRepository = catalogRepository
    }

    var body: some View {
        switch appModel.activeBackend {
        case .plex:
            plexBody
        case .jellyfin, .emby:
            // Jellyfin/Emby music browses through the shared MusicProvider (#111).
            MediaBrowserMusicView(macPivot: macPivot,
                                  selectedLibraryID: externalSelectedLibraryID,
                                  allowedLibraryIDs: allowedLibraryIDs,
                                  catalogRepository: catalogRepository)
        }
    }

    @ViewBuilder
    private var plexBody: some View {
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
                    MusicHomeView(section: section,
                                  requestedPivot: macPivot,
                                  catalogRepository: catalogRepository)
                        .id("\(section.key):\(macPivot?.rawValue ?? "adaptive")")
                }
            }
        }
        // tvOS suppresses the top-level title (helper is a no-op there); other platforms
        // keep main's pivot-aware dynamic title.
        .labstreamTopLevelNavigationTitle(macPivot == nil || macPivot == .home ? "Music" : macPivot?.rawValue ?? "Music")
        .toolbar {
            // Library switcher only when the server has more than one music section.
            if sections.count > 1 {
                #if os(macOS)
                ToolbarItem {
                    musicSectionPicker
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    musicSectionPicker
                }
                #endif
            }
        }
        .navigationDestination(for: MediaItem.self) { item in
            musicDestination(for: item, sectionKey: selectedSection?.key)
        }
        .navigationDestination(for: RailViewAllDestination.self) { destination in
            RailViewAllView(destination: destination)
        }
        .task(id: loadIdentity) { await load() }
        .refreshable { await load(force: true) }
    }

    private var musicSectionPicker: some View {
        Picker("Library", selection: selectedSectionBinding) {
            ForEach(sections) { section in
                Text(section.title).tag(Optional(section.key))
            }
        }
        .pickerStyle(.menu)
    }

    private var loadIdentity: MusicCatalogLoadIdentity {
        MusicCatalogLoadIdentity(appModel: appModel, allowedLibraryIDs: allowedLibraryIDs)
    }

    /// The section to browse: the explicit selection, else the first music section.
    private var selectedSection: PlexSection? {
        sections.first { $0.key == selectedSectionBinding.wrappedValue } ?? sections.first
    }

    private var selectedSectionBinding: Binding<String?> {
        externalSelectedLibraryID ?? $selectedSectionKey
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires every time the stack pops back to this root view; without
        // this guard the reload tears down MusicHomeView and resets the pivot/scroll
        // state the user is popping back TO (live bug: Back always landed on a fresh
        // Home pivot). Only pull-to-refresh and a real server change refetch.
        let activeIdentity = loadIdentity
        if !force, loadedIdentity == activeIdentity, case .loaded = loadState { return }
        loadGeneration += 1
        let generation = loadGeneration
        if case .loaded = loadState {} else { loadState = .loading }
        do {
            let snapshot = try await catalogRepository.catalog(appModel: appModel,
                                                               forceRefresh: force)
            let libraries = snapshot.descriptors.compactMap(\.plexSection)
            guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
            sections = libraries.filter { section in
                section.isMusic && (allowedLibraryIDs?.contains(section.key) ?? true)
            }
            let currentSelection = selectedSectionBinding.wrappedValue
            if currentSelection == nil || !sections.contains(where: { $0.key == currentSelection }) {
                selectedSectionBinding.wrappedValue = sections.first?.key
            }
            loadedIdentity = activeIdentity
            loadState = .loaded
        } catch {
            guard generation == loadGeneration, loadIdentity == activeIdentity, !Task.isCancelled else { return }
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

/// One music section: pivot control on top, the selected pivot below. Replaces the
/// old single-scroll MusicSectionBrowseView (rail + full artist dump).
private struct MusicHomeView: View {
    let section: PlexSection
    let requestedPivot: MusicPivot?
    let catalogRepository: LibraryCatalogRepository

    @State private var pivot: MusicPivot = .home

    init(section: PlexSection,
         requestedPivot: MusicPivot? = nil,
         catalogRepository: LibraryCatalogRepository) {
        self.section = section
        self.requestedPivot = requestedPivot
        self.catalogRepository = catalogRepository
        _pivot = State(initialValue: requestedPivot ?? .home)
    }

    var body: some View {
        Group {
            if let requestedPivot {
                pivotContent(requestedPivot)
            } else {
                MusicPivotShell(pivot: $pivot) { pivot in
                    pivotContent(pivot)
                }
            }
        }
    }

    @ViewBuilder
    private func pivotContent(_ pivot: MusicPivot) -> some View {
        // Each pivot owns its load state and scroll position; the parent identity resets when the
        // explicit Mac source-list destination or selected library changes.
        switch pivot {
        case .home: MusicHomePivot(section: section)
        case .artists:
            MusicPagedGrid(libraryID: section.key, libraryTitle: section.title, kind: .artists)
        case .albums:
            MusicPagedGrid(libraryID: section.key, libraryTitle: section.title, kind: .albums)
        case .playlists: MusicPlaylistsPivot(catalogRepository: catalogRepository)
        }
    }
}

// MARK: - Home pivot (hub rails + Shuffle Library)

/// Server-driven hub rails with the never-a-blank-screen ladder (MUSIC-DESIGN §3.1):
///   1. `/hubs/sections/{key}` hubs, rendered generically in server order;
///   2. no usable Recently-Played hub → synthesize the rail from play history;
///   3. hubs failed entirely → the old layout (Recently Added rail + Artists nudge).
private struct MusicHomePivot: View {
    @Environment(\.labstreamCompactWidth) private var compactWidth
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
    @State private var loadState: BrowseLoadState = .idle
    @State private var isShuffling = false
    @State private var shuffleError: String?
    @State private var loadGeneration = 0

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
                            MusicRail(title: "Recently Added", items: fallbackAlbums,
                                      destination: RailViewAllDestination(
                                        title: "Recently Added", backend: .plex,
                                        sessionIdentity: appModel.activeBrowseSessionKey,
                                        query: .albums(libraryID: section.key)))
                            Text("Browse everything from the Artists and Albums pivots above.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))
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
            .labstreamGlassButtonStyle()
            .disabled(isShuffling)

            if let shuffleError {
                Label(shuffleError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))
        .padding(.top, DS.Space.md)
    }

    private func load(force: Bool = false) async {
        // `.task` re-fires on every pop-back/tab-return; reloading then would swap
        // the rails for the skeleton and throw away scroll position. Refresh only
        // on first load or explicit pull-to-refresh.
        if !force, case .loaded = loadState { return }
        loadGeneration += 1
        let generation = loadGeneration
        guard let service = try? PlexBrowseService(appModel: appModel) else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        do {
            // Rung 1 — server hubs, rendered generically. v1 keeps artist/album hub
            // items only (track rows need play affordances first — v2); empty hubs drop.
            let sectionHubs = try await service.musicSectionHubs(sectionKey: section.key)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            hubs = sectionHubs.compactMap { hub in
                // The played hub carries ARTISTS; our history-songs rail replaces it.
                // Prefix-match the identifier; exact ids drift across PMS versions.
                if (hub.hubIdentifier ?? "").hasPrefix("music.recent.played") { return nil }
                let items = hub.metadata.filter { $0.kind == .artist || $0.kind == .album }
                guard !items.isEmpty else { return nil }
                return Hub(hubKey: hub.hubKey, key: hub.key, title: hub.title,
                           type: hub.type, hubIdentifier: hub.hubIdentifier,
                           size: items.count, metadata: items)
            }

            let freshHistoryTracks = await loadHistoryTracks(service: service)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            historyTracks = freshHistoryTracks
            fallbackAlbums = []
            loadState = .loaded
        } catch {
            // Rung 3 — hubs failed entirely: degrade to exactly the old layout.
            guard generation == loadGeneration, !Task.isCancelled else { return }
            hubs = []
            historyTracks = []
            await loadFallback(service: service, generation: generation)
        }
    }

    /// Play history → unique recently-played SONGS, newest first. History rows are
    /// skinny (no Media/Part) — the rail re-fetches full metadata on tap to play.
    private func loadHistoryTracks(service: PlexBrowseService) async -> [MediaItem] {
        guard let history = try? await service.playHistory(librarySectionID: section.key, count: 40)
        else { return [] }

        var seen = Set<String>()
        var tracks: [MediaItem] = []
        for item in history where item.kind == .track {
            guard seen.insert(item.ratingKey).inserted else { continue }
            tracks.append(item)
            if tracks.count >= 20 { break }
        }
        return tracks
    }

    private func loadFallback(service: PlexBrowseService, generation: Int) async {
        do {
            let albums = try await service.recentlyAddedAlbums(sectionKey: section.key)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            fallbackAlbums = albums
            loadState = .loaded
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            loadState = .failed(friendlyMessage(error))
        }
    }

    /// ONE un-paged random page → shuffle-play. Never page `sort=random`: PMS
    /// re-randomizes per container page, producing duplicates (MUSIC-DESIGN §3.1).
    private func shuffleLibrary() async {
        guard let service = try? PlexBrowseService(appModel: appModel) else { return }
        isShuffling = true
        shuffleError = nil
        defer { isShuffling = false }
        do {
            let tracks = try await service.randomTracks(sectionKey: section.key)
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
    var destination: RailViewAllDestination? = nil

    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        VStack(alignment: .leading, spacing: compactWidth ? DS.Space.sm : DS.Space.lg) {
            RailSectionHeader(title: title, destination: destination)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: compactWidth ? DS.Space.md : DS.Space.xl) {
                    ForEach(items.prefix(20)) { item in
                        NavigationLink(value: item) {
                            SquareArtCell(item: item,
                                          size: MusicArt.railSize(compact: compactWidth),
                                          subtitle: item.parentTitle)
                        }
                        .cardLink()
                    }
                }
                .padding(.vertical, DS.Space.sm)
            }
            // contentMargins, not .padding on the lazy content — see the hit-region
            // gotcha in docs/DEVELOPMENT.md (padding shifts gaze/hit shapes left).
            .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth))
            #if os(tvOS)
            // Declared focus row (see HubRail): whole-rail target for vertical moves.
            .focusSection()
            #endif
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

    @Environment(\.labstreamCompactWidth) private var compactWidth

    var body: some View {
        VStack(alignment: .leading, spacing: compactWidth ? DS.Space.sm : DS.Space.lg) {
            Text(title)
                .font(compactWidth ? .title3.bold() : .title2.bold())
                .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: compactWidth ? DS.Space.md : DS.Space.xl) {
                    ForEach(tracks.prefix(20)) { track in
                        Button {
                            Task { await play(from: track) }
                        } label: {
                            SquareArtCell(item: displayItem(for: track),
                                          size: MusicArt.railSize(compact: compactWidth),
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
            .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth))
            #if os(tvOS)
            // Declared focus row (see HubRail): whole-rail target for vertical moves.
            .focusSection()
            #endif
        }
    }

    /// Track cells show the resolved music art (album cover; track thumbs 404 here).
    private func displayItem(for track: MediaItem) -> MediaItem {
        MediaItem(ratingKey: track.ratingKey, title: track.title,
                  type: track.type, thumb: track.musicArtPath)
    }

    private func play(from tapped: MediaItem) async {
        guard let service = try? PlexBrowseService(appModel: appModel) else { return }
        isStarting = true
        defer { isStarting = false }
        let keys = tracks.prefix(20).map(\.ratingKey).joined(separator: ",")
        do {
            let full = try await service.metadataItems(ratingKeys: keys).filter { $0.kind == .track }
            guard !full.isEmpty else { return }
            let index = full.firstIndex { $0.ratingKey == tapped.ratingKey } ?? 0
            player.play(tracks: full, startingAt: index)
        } catch {
            AppDiagnostics.record(.music, "music.recently_played_replay_failed", fields: [
                "error": .error(error),
                "candidate_count": .int(tracks.count),
            ])
            NSLog("[VP] recently-played replay failed: %@",
                  DiagnosticRedactor.safeErrorSummary(error))
        }
    }
}

// MARK: - Playlists pivot (read-only v1, MUSIC-DESIGN §3.4)

/// Audio playlists as card rows — 56-pt composite art, title, "N tracks". Playlists
/// are loaded through `MusicProvider` and are backend-wide, so unlike the artist/album pivots
/// this takes no library id; the toolbar library Picker does not scope it. Rows push the shared
/// provider-backed `PlaylistDetailView` via `musicDestination`.
struct MusicPlaylistsPivot: View {
    let catalogRepository: LibraryCatalogRepository
    @Environment(AppModel.self) private var appModel
    @Environment(\.labstreamCompactWidth) private var compactWidth

    @State private var playlists: [MediaItem] = []
    @State private var loadState: BrowseLoadState = .idle
    @State private var loadGeneration = 0

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
                        .padding(.horizontal, compactWidth ? DS.pagePadding(compact: true) : DS.Space.xxl)
                        .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .task(id: loadIdentity) { await load() }
        .refreshable { await load(force: true) }
    }

    private var loadIdentity: MusicCatalogLoadIdentity {
        MusicCatalogLoadIdentity(appModel: appModel, allowedLibraryIDs: nil)
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

    private func load(force: Bool = false) async {
        let identity = loadIdentity
        loadGeneration += 1
        let generation = loadGeneration
        loadState = .loading
        do {
            let loaded = try await appModel.musicProvider
                .musicPlaylists(catalogRepository: catalogRepository, forceRefresh: force)
            guard generation == loadGeneration, loadIdentity == identity,
                  !Task.isCancelled else { return }
            playlists = loaded
            loadState = .loaded
        } catch {
            guard generation == loadGeneration, loadIdentity == identity,
                  !Task.isCancelled else { return }
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

/// Shimmering placeholder mirroring the rail-above-grid layout while a section loads.
/// Internal so the shared `MusicPagedGrid` shows the same loading treatment (#111).
struct MusicSkeleton: View {
    @Environment(\.labstreamCompactWidth) private var compactWidth

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: MusicArt.gridMin(compact: compactWidth),
                            maximum: MusicArt.gridMax(compact: compactWidth)),
                  spacing: MusicArt.gridGutter(compact: compactWidth))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxxl) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                skeletonBlock(width: 220, height: 26, radius: DS.Radius.chip)
                    .padding(.horizontal, DS.Scroll.railHorizontalMargin(compact: compactWidth))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: compactWidth ? DS.Space.md : DS.Space.xl) {
                        ForEach(0..<5, id: \.self) { _ in
                            skeletonBlock(width: MusicArt.railSize(compact: compactWidth),
                                          height: MusicArt.railSize(compact: compactWidth),
                                          radius: DS.Radius.poster)
                        }
                    }
                    .padding(.vertical, DS.Space.xs)
                }
                .mediaRailScrollStyle(horizontalMargin: DS.Scroll.railHorizontalMargin(compact: compactWidth),
                                      clipDisabled: false)
            }

            LazyVGrid(columns: columns, spacing: MusicArt.gridRowSpacing(compact: compactWidth)) {
                ForEach(0..<8, id: \.self) { _ in
                    skeletonBlock(width: MusicArt.gridMin(compact: compactWidth),
                                  height: MusicArt.gridMin(compact: compactWidth),
                                  radius: DS.Radius.poster)
                }
            }
            .padding(.horizontal, DS.pagePadding(compact: compactWidth))
        }
        .padding(.vertical, MusicArt.gridVerticalPadding)
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

    /// Compact-width (iPhone) counterparts, matching `DS.Poster.Compact` so music
    /// and video browse density stay in lock-step on the phone.
    enum Compact {
        static let railSize: CGFloat = 110
        static let gridMin: CGFloat = 104
        static let gridMax: CGFloat = 150
    }

    #if os(macOS)
    /// Native Mac music browse grids should read like a desktop media library: denser
    /// than the touch/visionOS tiles, but still large enough for artwork recognition.
    enum MacGrid {
        static let gridMin: CGFloat = 126
        static let gridMax: CGFloat = 148
        static let gutter: CGFloat = 18
        static let rowSpacing: CGFloat = 22
        static let verticalPadding: CGFloat = 16
        static let alphabetRailGridReservation: CGFloat = 46
    }
    #endif

    static func railSize(compact: Bool) -> CGFloat {
        #if os(tvOS)
        236
        #else
        compact ? Compact.railSize : railSize
        #endif
    }
    static func gridMin(compact: Bool) -> CGFloat {
        #if os(macOS)
        MacGrid.gridMin
        #elseif os(tvOS)
        220
        #else
        compact ? Compact.gridMin : gridMin
        #endif
    }
    static func gridMax(compact: Bool) -> CGFloat {
        #if os(macOS)
        MacGrid.gridMax
        #elseif os(tvOS)
        260
        #else
        compact ? Compact.gridMax : gridMax
        #endif
    }
    static func gridGutter(compact: Bool) -> CGFloat {
        #if os(macOS)
        MacGrid.gutter
        #else
        DS.gridGutter(compact: compact)
        #endif
    }
    static func gridRowSpacing(compact: Bool) -> CGFloat {
        #if os(macOS)
        MacGrid.rowSpacing
        #elseif os(tvOS)
        36
        #else
        compact ? DS.Space.lg : DS.Space.xxl
        #endif
    }

    static var gridVerticalPadding: CGFloat {
        #if os(macOS)
        MacGrid.verticalPadding
        #elseif os(tvOS)
        32
        #else
        DS.Space.xl
        #endif
    }

    #if os(macOS)
    static var macAlphabetRailGridReservation: CGFloat { MacGrid.alphabetRailGridReservation }
    #endif
}

/// Square artwork + title (+ optional subtitle) cell shared by the music rails and
/// grids — the music counterpart of `PosterCell`. Artist art renders circular
/// (the music-app idiom that visually separates people from records).
struct SquareArtCell: View {
    let item: MediaItem
    /// Explicit size from callers; nil means "grid default for this size class".
    var size: CGFloat?
    /// Optional second line (e.g. artist name on an album, year on a discography cell).
    var subtitle: String? = nil

    @Environment(\.labstreamCompactWidth) private var compactWidth

    private var resolvedSize: CGFloat {
        size ?? MusicArt.gridMin(compact: compactWidth)
    }

    private var usesMacGridMetrics: Bool {
        #if os(macOS)
        size == nil
        #else
        false
        #endif
    }

    private var artRadius: CGFloat {
        item.kind == .artist ? resolvedSize / 2 : DS.Radius.poster
    }

    private var textAlignment: HorizontalAlignment {
        item.kind == .artist ? .center : .leading
    }

    private var frameAlignment: Alignment {
        item.kind == .artist ? .center : .leading
    }

    var body: some View {
        VStack(alignment: textAlignment, spacing: usesMacGridMetrics ? DS.Space.xs : DS.Space.sm) {
            PosterImage(path: item.thumb, width: resolvedSize, height: resolvedSize,
                        cornerRadius: artRadius,
                        placeholderSymbol: item.kind == .artist ? "music.microphone" : "music.note")
                .posterHover()
                .tvFocusHighlight(cornerRadius: artRadius)

            VStack(alignment: textAlignment, spacing: 2) {
                Text(item.title)
                    .font(titleFont)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(subtitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: frameAlignment)
                }
            }
        }
        .frame(width: resolvedSize, alignment: frameAlignment)
        // NOTE: highlight comes from the wrapping link's `.cardLink()` — a custom
        // ButtonStyle here misroutes pinches to neighboring cards (DEVELOPMENT.md).
    }

    private var titleFont: Font {
        usesMacGridMetrics ? .subheadline.weight(.semibold) : .headline
    }

    private var subtitleFont: Font {
        usesMacGridMetrics ? .caption : .subheadline
    }
}
