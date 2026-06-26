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
    @State private var loadState: HomeView.LoadState = .idle

    private var selectedLibrary: MusicLibrary? {
        libraries.first { $0.id == selectedLibraryID } ?? libraries.first
    }

    /// Reload when the backend or its server changes (switching Jellyfin ⇄ Emby).
    private var backendIdentity: String {
        let host = (appModel.jellyfinServerBaseURL ?? appModel.embyServerBaseURL)?.host ?? "nil"
        return "\(appModel.activeBackend.rawValue):\(host)"
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
            musicDestination(for: item, sectionKey: selectedLibrary?.id)
        }
        .task(id: backendIdentity) { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        if !force, case .loaded = loadState, !libraries.isEmpty { return }
        if case .loaded = loadState {} else { loadState = .loading }
        do {
            let libs = try await appModel.musicProvider.musicLibraries()
            libraries = libs
            if selectedLibraryID == nil { selectedLibraryID = libs.first?.id }
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One MediaBrowser music library: an Albums/Artists pivot. Albums lead (the most
/// reliable, art-rich listing); each pivot owns its own paged grid.
private struct MediaBrowserMusicLibraryView: View {
    let library: MusicLibrary

    private enum Pivot: String, CaseIterable, Identifiable {
        case albums = "Albums"
        case artists = "Artists"
        var id: String { rawValue }
    }

    @State private var pivot: Pivot = .albums

    var body: some View {
        VStack(spacing: 0) {
            Picker("Browse", selection: $pivot) {
                ForEach(Pivot.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(.top, DS.Space.md)
            .padding(.bottom, DS.Space.sm)

            switch pivot {
            case .albums:
                MediaBrowserMusicGrid(library: library, kind: .albums).id("albums")
            case .artists:
                MediaBrowserMusicGrid(library: library, kind: .artists).id("artists")
            }
        }
    }
}

/// A forward-paged adaptive grid of a MediaBrowser music library's albums or artists.
/// Loads a page at a time, appending as the last cell appears — simpler than the Plex
/// random-access grid, which it doesn't need (these listings are browsed top-down).
private struct MediaBrowserMusicGrid: View {
    enum Kind { case albums, artists }

    let library: MusicLibrary
    let kind: Kind

    @Environment(AppModel.self) private var appModel

    @State private var items: [MediaItem] = []
    @State private var total = 0
    @State private var loadState: HomeView.LoadState = .idle
    @State private var loadingMore = false

    private let pageSize = 120
    private let columns = [GridItem(.adaptive(minimum: MusicArt.gridMin, maximum: MusicArt.gridMax),
                                    spacing: DS.Space.xl)]

    /// Albums sort newest-first; artists alphabetically.
    private var sort: MusicBrowseSort { kind == .albums ? .recentlyAdded : .name }

    var body: some View {
        ScrollView {
            switch loadState {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .failed(let message):
                ContentUnavailableView("Couldn’t load \(library.title)",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
                    .frame(maxWidth: .infinity, minHeight: 360)
            case .loaded:
                if items.isEmpty {
                    ContentUnavailableView(kind == .albums ? "No Albums" : "No Artists",
                                           systemImage: "music.note",
                                           description: Text("Nothing to show in \(library.title)."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    grid
                }
            }
        }
        .task { await loadFirstPage() }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                NavigationLink(value: item) {
                    SquareArtCell(item: item, size: MusicArt.gridMin, subtitle: subtitle(item))
                }
                .cardLink()
                .onAppear {
                    // Page in more as the tail approaches.
                    if index >= items.count - 12 { Task { await loadMoreIfNeeded() } }
                }
            }
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.vertical, DS.Space.xl)
    }

    /// "Artist · 1973" on albums, dropping whichever half is missing; nil for artists.
    private func subtitle(_ item: MediaItem) -> String? {
        guard kind == .albums else { return nil }
        let parts = [item.parentTitle, item.year.map(String.init)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func loadFirstPage() async {
        if case .loaded = loadState { return }
        loadState = .loading
        do {
            let page = try await fetch(start: 0)
            items = page.items
            total = page.total
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }

    private func loadMoreIfNeeded() async {
        guard !loadingMore, items.count < total else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await fetch(start: items.count)
            // Guard against duplicate appends from overlapping onAppear triggers.
            let known = Set(items.map(\.ratingKey))
            items.append(contentsOf: page.items.filter { !known.contains($0.ratingKey) })
        } catch {
            // Non-fatal: keep what we have; a later scroll retries.
        }
    }

    private func fetch(start: Int) async throws -> MusicPage {
        switch kind {
        case .albums:
            return try await appModel.musicProvider.albums(libraryID: library.id, sort: sort,
                                                           start: start, size: pageSize)
        case .artists:
            return try await appModel.musicProvider.artists(libraryID: library.id, sort: sort,
                                                            start: start, size: pageSize)
        }
    }
}
