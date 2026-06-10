import SwiftUI
import PlexKit

/// An artist's discography: a compact header (portrait + name + bio) above an
/// adaptive grid of their albums. Albums come from the section search
/// `…/all?type=9&artist.id={rk}` (the plexapi/Plex Web shape) — the children
/// endpoint under-lists, proven live: size=0 for an artist owning two albums,
/// and appears-on albums missing for others. Children remains only as the
/// fallback when no `sectionKey` is in hand (cross-section search results).
struct ArtistDetailView: View {
    let artist: MediaItem
    /// Music section the artist was browsed from; nil → children fallback.
    var sectionKey: String? = nil

    @Environment(AppModel.self) private var appModel

    @State private var albums: [MediaItem] = []
    @State private var loadState: HomeView.LoadState = .idle

    private let columns = [GridItem(.adaptive(minimum: MusicArt.gridMin, maximum: MusicArt.gridMax),
                                    spacing: DS.Space.xl)]

    /// Header portrait size — larger than a grid cell, smaller than an album hero.
    private let portraitSize: CGFloat = 160

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                header

                switch loadState {
                case .idle, .loading:
                    albumSkeleton
                case .failed(let message):
                    ContentUnavailableView("Couldn’t load \(artist.title)",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                        .frame(maxWidth: .infinity, minHeight: 360)
                case .loaded:
                    if albums.isEmpty {
                        ContentUnavailableView("No albums",
                                               systemImage: "music.note",
                                               description: Text("Nothing to show for \(artist.title)."))
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        albumGrid
                    }
                }
            }
            .padding(.vertical, DS.Space.xl)
        }
        .navigationTitle(artist.title)
        .task { await load() }
    }

    /// Portrait + name + short bio.
    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.xl) {
            PosterImage(path: artist.thumb, width: portraitSize, height: portraitSize,
                        cornerRadius: DS.Radius.poster)

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(artist.title)
                    .font(.largeTitle.bold())
                if let summary = artist.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.xxl)
    }

    private var albumGrid: some View {
        LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
            ForEach(albums) { album in
                NavigationLink(value: album) {
                    SquareArtCell(item: album,
                                  size: MusicArt.gridMin,
                                  subtitle: album.year.map(String.init))
                }
                .buttonStyle(.card)
            }
        }
        .padding(.horizontal, DS.Space.xxl)
    }

    /// Shimmering square placeholders keeping the grid's gutters while albums load.
    private var albumSkeleton: some View {
        LazyVGrid(columns: columns, spacing: DS.Space.xxl) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: MusicArt.gridMin, height: MusicArt.gridMin)
                    .overlay { ShimmerView() }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
            }
        }
        .padding(.horizontal, DS.Space.xxl)
    }

    private func load() async {
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let req: PlexRequest
        if let sectionKey {
            req = MusicRequest.artistAlbums(server: server, token: token,
                                            identity: appModel.identity,
                                            sectionKey: sectionKey,
                                            artistRatingKey: artist.ratingKey)
        } else {
            req = BrowseAPI.children(server: server, token: token,
                                     identity: appModel.identity, ratingKey: artist.ratingKey)
        }
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            albums = resp.mediaContainer.metadata
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}
