import SwiftUI
import PMSKit

/// Music tab root for the MediaBrowser backends (Jellyfin / Emby) (#111). Mirrors the
/// Plex `MusicLibraryView` shell — one library renders inline, several get a picker,
/// none shows an empty state — but browses through the shared `MusicProvider` and an
/// Albums/Artists pivot of paged grids. Album/artist taps resolve through the same
/// `musicDestination(for:sectionKey:)` the Plex stack uses, so the detail screens and
/// playback are shared.
struct MediaBrowserMusicView: View {
    @Environment(AppModel.self) private var appModel

    @State private var libraries: [MusicLibrary] = []
    @State private var selectedLibraryID: String?
    @State private var loadState: BrowseLoadState = .idle
    /// The `backendIdentity` the currently-loaded `libraries` belong to. Mirrors
    /// `MusicLibraryView.loadedIdentity`: without it, the `.task(id: backendIdentity)` reload
    /// fires on a backend switch but `load()` early-returns (still `.loaded`) and keeps showing
    /// the previous backend's libraries.
    @State private var loadedIdentity: String?

    private var selectedLibrary: MusicLibrary? {
        libraries.first { $0.id == selectedLibraryID } ?? libraries.first
    }

    /// Reload when the backend or its server changes (switching Jellyfin ⇄ Emby).
    private var backendIdentity: String {
        appModel.activeBrowseSessionKey
    }

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
                if libraries.isEmpty {
                    ContentUnavailableView("No Music Libraries",
                                           systemImage: "music.note",
                                           description: Text("This server has no music libraries."))
                } else if let library = selectedLibrary {
                    MediaBrowserMusicLibraryView(library: library)
                        .id(library.id) // reset pivot/scroll when switching libraries
                }
            }
        }
        .navigationTitle("Music")
        .toolbar {
            if libraries.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Library", selection: $selectedLibraryID) {
                        ForEach(libraries) { library in
                            Text(library.title).tag(Optional(library.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .navigationDestination(for: MediaItem.self) { item in
            // Playlists route to the MediaBrowser-specific detail (the shared
            // `musicDestination` maps `.playlist` to the Plex playlist view); albums and
            // artists keep the shared, provider-backed destinations (#111).
            if item.kind == .playlist {
                MediaBrowserPlaylistDetailView(playlist: item)
            } else {
                musicDestination(for: item, sectionKey: selectedLibrary?.id)
            }
        }
        .task(id: backendIdentity) { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        let activeIdentity = backendIdentity
        if !force, loadedIdentity == activeIdentity, case .loaded = loadState, !libraries.isEmpty { return }
        let identityChanged = loadedIdentity != activeIdentity
        if identityChanged { loadState = .loading }
        else if case .loaded = loadState {} else { loadState = .loading }
        do {
            let libs = try await appModel.musicProvider.musicLibraries()
            // A newer backend switch may have superseded this fetch while it was in flight; its own
            // `.task(id:)` reload will deliver the correct libraries, so drop this stale result.
            guard backendIdentity == activeIdentity else { return }
            libraries = libs
            // Reset the selection when the backend changed — the previous backend's library id is
            // meaningless for the new server.
            if selectedLibraryID == nil || identityChanged { selectedLibraryID = libs.first?.id }
            loadedIdentity = activeIdentity
            loadState = .loaded
        } catch {
            guard backendIdentity == activeIdentity else { return }
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One MediaBrowser music library: a Home/Artists/Albums/Playlists pivot, mirroring the
/// Plex music tab's structure (#111). Home leads with horizontal rails; each pivot owns
/// its own load state and scroll position.
private struct MediaBrowserMusicLibraryView: View {
    let library: MusicLibrary

    private enum Pivot: String, CaseIterable, Identifiable {
        case home = "Home"
        case artists = "Artists"
        case albums = "Albums"
        case playlists = "Playlists"
        var id: String { rawValue }
    }

    @State private var pivot: Pivot = .home

    var body: some View {
        VStack(spacing: 0) {
            Picker("Browse", selection: $pivot) {
                ForEach(Pivot.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            .padding(.top, DS.Space.md)
            .padding(.bottom, DS.Space.sm)

            switch pivot {
            case .home:
                MediaBrowserMusicHome(library: library).id("home")
            case .artists:
                MusicPagedGrid(libraryID: library.id, libraryTitle: library.title, kind: .artists)
                    .id("artists")
            case .albums:
                MusicPagedGrid(libraryID: library.id, libraryTitle: library.title, kind: .albums)
                    .id("albums")
            case .playlists:
                MediaBrowserMusicPlaylists().id("playlists")
            }
        }
    }
}

// MARK: - Home pivot (#111)

/// MediaBrowser music Home: horizontal rails of Recently Added albums, Recently Played
/// tracks, and Favorite albums (#111). Empty rails are hidden by the provider; a Home with
/// no rails at all shows a friendly empty state. Album cells navigate to the album detail;
/// track cells play the rail starting at the tap, through the shared `MusicPlayerController`.
private struct MediaBrowserMusicHome: View {
    let library: MusicLibrary

    @Environment(AppModel.self) private var appModel

    @State private var rails: [MusicHomeRail] = []
    @State private var loadState: BrowseLoadState = .idle

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .failed(let message):
                ContentUnavailableView("Couldn’t load Home",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .loaded:
                if rails.isEmpty {
                    ContentUnavailableView("Nothing here yet",
                                           systemImage: "music.note",
                                           description: Text("Recently added, recently played, and favorites will appear here."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                        ForEach(rails) { rail in
                            switch rail.style {
                            case .albums:
                                // Album rails navigate to the (provider-backed) album detail.
                                MusicRail(title: rail.title, items: rail.items)
                            case .tracks:
                                // Track rails play on tap through the shared player.
                                MediaBrowserMusicTrackRail(title: rail.title, tracks: rail.items)
                            }
                        }
                    }
                    .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        if !force, case .loaded = loadState { return }
        if case .loaded = loadState {} else { loadState = .loading }
        do {
            rails = try await MediaBrowserMusicProvider(appModel: appModel)
                .musicHomeRails(libraryID: library.id)
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// Horizontal rail of tracks that PLAY on tap (Recently Played) — the MediaBrowser twin of
/// the Plex `MusicTrackRail`, but MediaBrowser tracks are already full items (no metadata
/// re-fetch needed), so a tap plays the rail directly through `MusicPlayerController` (#111).
private struct MediaBrowserMusicTrackRail: View {
    let title: String
    let tracks: [MediaItem]

    @Environment(MusicPlayerController.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal, DS.Space.xxl)

            ScrollView(.horizontal) {
                LazyHStack(spacing: DS.Space.xl) {
                    ForEach(Array(tracks.prefix(20).enumerated()), id: \.element.id) { index, track in
                        Button {
                            player.play(tracks: Array(tracks.prefix(20)), startingAt: index)
                        } label: {
                            SquareArtCell(item: track,
                                          size: MusicArt.railSize,
                                          subtitle: track.grandparentTitle)
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

// MARK: - Playlists pivot (#111)

/// Audio playlists as card rows (mirrors the Plex Playlists pivot): composite art, title,
/// "N tracks". Rows push the MediaBrowser playlist detail via a value link (#111).
private struct MediaBrowserMusicPlaylists: View {
    @Environment(AppModel.self) private var appModel

    @State private var playlists: [MediaItem] = []
    @State private var loadState: BrowseLoadState = .idle

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 360)
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
        .refreshable { await load(force: true) }
    }

    /// One material card of playlist rows, hairline-separated — the same treatment as the
    /// Plex Playlists pivot.
    private var playlistList: some View {
        VStack(spacing: 0) {
            ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                NavigationLink(value: playlist) {
                    MediaBrowserPlaylistRow(playlist: playlist)
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
        if !force, case .loaded = loadState { return }
        if case .loaded = loadState {} else { loadState = .loading }
        do {
            playlists = try await MediaBrowserMusicProvider(appModel: appModel).musicPlaylists()
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One playlist row: 56-pt composite art, title, "N tracks" (when the server reported a
/// child count). Mirrors the Plex `PlaylistRow`.
private struct MediaBrowserPlaylistRow: View {
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
        .padding(.horizontal, DS.Space.sm)
    }
}

// The Albums/Artists grids now use the shared `MusicPagedGrid` (#111) — random-access
// paging + A–Z rail + sort menu — so the old forward-paged `MediaBrowserMusicGrid` is gone.
