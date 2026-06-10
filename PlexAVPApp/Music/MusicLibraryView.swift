import SwiftUI
import PlexKit

/// Music tab root: the Plexamp-style entry point for the server's music libraries
/// (`artist`-type sections). One music section renders inline; multiple sections get
/// a picker; zero sections shows a friendly empty state.
///
/// This view also owns the music navigation routing: artist and album items pushed
/// from anywhere in this stack resolve to `ArtistDetailView` / `AlbumDetailView`.
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
                    MusicSectionBrowseView(section: section)
                        .id(section.key) // reset scroll/load when switching libraries
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
            switch item.type {
            case "artist": ArtistDetailView(artist: item)
            case "album": AlbumDetailView(album: item)
            default: EmptyView()
            }
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

// MARK: - Section browse

/// Browse for one music section: a "Recently Added" horizontal rail of albums above
/// an adaptive grid of every artist in the library.
private struct MusicSectionBrowseView: View {
    let section: PlexSection

    @Environment(AppModel.self) private var appModel

    @State private var recentAlbums: [MediaItem] = []
    @State private var artists: [MediaItem] = []
    @State private var loadState: HomeView.LoadState = .idle

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
                if recentAlbums.isEmpty && artists.isEmpty {
                    ContentUnavailableView("Empty library",
                                           systemImage: "music.note",
                                           description: Text("No music in \(section.title)."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxxl) {
                        if !recentAlbums.isEmpty { recentRail }
                        if !artists.isEmpty { artistGrid }
                    }
                    .padding(.vertical, DS.Space.xl)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    /// Horizontal rail of the most recently added albums (display capped at 20).
    private var recentRail: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Recently Added")
                .font(.title2.bold())
                .padding(.horizontal, DS.Space.xxl)

            ScrollView(.horizontal) {
                LazyHStack(spacing: DS.Space.xl) {
                    ForEach(recentAlbums.prefix(20)) { album in
                        NavigationLink(value: album) {
                            SquareArtCell(item: album,
                                          size: MusicArt.railSize,
                                          subtitle: album.parentTitle)
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

    /// Every artist in the library as an adaptive grid of square cells.
    private var artistGrid: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Artists")
                .font(.title2.bold())
                .padding(.horizontal, DS.Space.xxl)

            LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
                ForEach(artists) { artist in
                    NavigationLink(value: artist) {
                        SquareArtCell(item: artist, size: MusicArt.gridMin)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, DS.Space.xxl)
        }
    }

    private func load() async {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let recentReq = MusicRequest.recentlyAddedAlbums(server: server, token: token,
                                                         identity: appModel.identity,
                                                         sectionKey: section.key)
        let artistsReq = MusicRequest.artists(server: server, token: token,
                                              identity: appModel.identity,
                                              sectionKey: section.key)
        do {
            async let recentResp = appModel.client.send(recentReq, as: MetadataResponse.self)
            async let artistsResp = appModel.client.send(artistsReq, as: MetadataResponse.self)
            recentAlbums = try await recentResp.mediaContainer.metadata
            artists = try await artistsResp.mediaContainer.metadata
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
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
    /// Album cell size in the "Recently Added" rail.
    static let railSize: CGFloat = 184
    /// Adaptive grid bounds for artist/album cells.
    static let gridMin: CGFloat = 168
    static let gridMax: CGFloat = 208
}

/// Square artwork + title (+ optional subtitle) cell shared by the music rail and
/// grids — the music counterpart of `PosterCell`.
struct SquareArtCell: View {
    let item: MediaItem
    var size: CGFloat = MusicArt.gridMin
    /// Optional second line (e.g. artist name on an album, year on a discography cell).
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            PosterImage(path: item.thumb, width: size, height: size,
                        cornerRadius: DS.Radius.poster)
                .gazeHighlight()
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
