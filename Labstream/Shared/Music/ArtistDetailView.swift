import SwiftUI
import PMSKit

/// An artist's page, Plexamp-style: header (portrait + name + bio) above shelves in
/// Plexamp's order — Popular tracks, Albums, the PMS-categorized release shelves
/// (Singles & EPs / Soundtracks / Compilations / Live / …), Appears On, and Similar
/// Artists.
///
/// Sourcing (all proven against a live PMS — see MUSIC-DESIGN §6):
/// - Own discography: `…/all?type=9&artist.id={rk}` — NOT `/children`, which
///   under-lists (returned size=0 for an artist owning two albums).
/// - Categorized shelves + Similar Artists: `/library/metadata/{rk}/related` hubs
///   (`artist.albums.singles` "Singles & EPs", `.compilation`, `artist.similar`, …).
/// - Appears On: `…/all?type=9&track.originalTitle={name}` — compilation tracks
///   carry the performing artist as TEXT, unlinked to the artist node; exact-match
///   only ("Artist feat. X" credits are missed — PMS has no contains operator).
/// - Popular: plexapi's `popularTracks` query (ratingCount:desc, compilations/live
///   excluded); rows come back with Media/Part, so they play directly.
struct ArtistDetailView: View {
    let artist: MediaItem
    /// Music section the artist was browsed from; nil → children fallback
    /// (cross-section search results), which renders a single Albums shelf.
    var sectionKey: String? = nil

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player

    @State private var popular: [MediaItem] = []
    /// Own albums not already on a categorized shelf (the LPs, typically).
    @State private var albums: [MediaItem] = []
    /// PMS-categorized release shelves (Singles & EPs / Compilations / …), server order.
    /// Empty for MediaBrowser backends, which only surface the flat Albums shelf.
    @State private var categorized: [ArtistShelf] = []
    @State private var appearsOn: [MediaItem] = []
    @State private var similar: [MediaItem] = []
    @State private var loadState: BrowseLoadState = .idle
    /// Play/Shuffle Artist in flight (the allLeaves fetch) — disables both buttons.
    @State private var isStartingPlayback = false
    @State private var playError: String?

    @Environment(\.labstreamCompactWidth) private var compactWidth

    /// Header portrait size — larger than a grid cell, smaller than an album hero.
    /// Compact shrinks it so the name/buttons column keeps usable width beside it.
    private var portraitSize: CGFloat { compactWidth ? 110 : 160 }

    /// Readable-measure cap for the bio so it doesn't stretch to ~1000-pt lines on wide
    /// iPad/visionOS windows (mirrors DetailView's readable metadata column).
    private static let readableBioWidth: CGFloat = 640

    private var isEmpty: Bool {
        popular.isEmpty && albums.isEmpty && categorized.isEmpty
            && appearsOn.isEmpty && similar.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xxl) {
                header

                switch loadState {
                case .idle, .loading:
                    shelfSkeleton
                case .failed(let message):
                    ContentUnavailableView("Couldn’t load \(artist.title)",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                        .frame(maxWidth: .infinity, minHeight: 360)
                case .loaded:
                    if isEmpty {
                        ContentUnavailableView("No albums",
                                               systemImage: "music.note",
                                               description: Text("Nothing to show for \(artist.title)."))
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        shelves
                    }
                }
            }
            .padding(.vertical, DS.Space.xl)
        }
        .navigationTitle(artist.title)
        .task { await load() }
    }

    /// Portrait + name + short bio. Side-by-side on regular width; compact stacks the
    /// portrait above a full-width name/buttons column — the Play/Shuffle pair can't fit
    /// the ~224-pt column left beside the portrait on a phone.
    private var header: some View {
        let layout = compactWidth
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.lg))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DS.Space.xl))
        return layout {
            PosterImage(path: artist.thumb, width: portraitSize, height: portraitSize,
                        cornerRadius: DS.Radius.poster)

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(artist.title)
                    .font(compactWidth ? .title.bold() : .largeTitle.bold())
                if let summary = artist.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        // Cap the bio to a readable measure so it doesn't stretch to
                        // ~1000 pt on wide iPad/visionOS windows (mirrors DetailView's
                        // readable metadata column).
                        .frame(maxWidth: Self.readableBioWidth, alignment: .leading)
                }

                // Play/Shuffle the whole discography via `allLeaves` (MUSIC-DESIGN
                // §3.5) — same button treatment as the album header. Radio is v2
                // (Pass-gated, probe-only — §6).
                HStack(spacing: DS.Space.lg) {
                    Button {
                        Task { await playDiscography(shuffled: false) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.title3.weight(.semibold))
                    }
                    .labstreamGlassProminentButtonStyle()

                    Button {
                        Task { await playDiscography(shuffled: true) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.title3)
                    }
                    .labstreamGlassButtonStyle()
                }
                .disabled(isStartingPlayback)
                .padding(.top, DS.Space.md)

                if let playError {
                    Label(playError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.pagePadding(compact: compactWidth))
    }

    /// Fetch every track under the artist in one flat list and play it (in album
    /// order, or shuffled). One request, zero controller changes.
    private func playDiscography(shuffled: Bool) async {
        isStartingPlayback = true
        playError = nil
        defer { isStartingPlayback = false }
        do {
            let tracks = try await appModel.musicProvider.discographyTracks(artist: artist)
            guard !tracks.isEmpty else {
                playError = "No tracks to play."
                return
            }
            if shuffled {
                player.playAlbumShuffled(tracks: tracks)
            } else {
                player.play(tracks: tracks, startingAt: 0)
            }
        } catch {
            playError = friendlyMessage(error)
        }
    }

    @ViewBuilder
    private var shelves: some View {
        if !popular.isEmpty { popularList }
        if !albums.isEmpty { MusicRail(title: "Albums", items: albums) }
        ForEach(categorized) { shelf in
            MusicRail(title: shelf.title, items: shelf.items)
        }
        if !appearsOn.isEmpty { MusicRail(title: "Appears On", items: appearsOn) }
        if !similar.isEmpty { MusicRail(title: "Similar Artists", items: similar) }
    }

    /// Top tracks on a material card, ranked; tap plays the popular list from there.
    private var popularList: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Popular")
                .font(.title2.bold())

            VStack(spacing: 0) {
                ForEach(Array(popular.enumerated()), id: \.element.id) { index, track in
                    Button {
                        player.play(tracks: popular, startingAt: index)
                    } label: {
                        PopularTrackRow(rank: index + 1, track: track,
                                        isCurrent: player.current?.ratingKey == track.ratingKey)
                    }
                    .cardLink(cornerRadius: DS.Radius.chip)
                    // Queue actions (#17 Phase 4); §3.6 contextMenu-on-row-chrome caveat.
                    .contextMenu { TrackQueueMenu(track: track, player: player) }

                    if index < popular.count - 1 {
                        Divider().padding(.leading, DS.Space.xxl + DS.Space.lg)
                    }
                }
            }
            .padding(.vertical, DS.Space.sm)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .padding(.horizontal, DS.pagePadding(compact: compactWidth))
    }

    /// Shimmering shelf placeholders while everything loads.
    private var shelfSkeleton: some View {
        HStack(spacing: compactWidth ? DS.Space.md : DS.Space.xl) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: MusicArt.railSize(compact: compactWidth),
                           height: MusicArt.railSize(compact: compactWidth))
                    .overlay { ShimmerView() }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
            }
        }
        .padding(.horizontal, DS.pagePadding(compact: compactWidth))
    }

    private func load() async {
        // `.task` re-fires when popping back from a pushed album; reloading then
        // resets the scroll position the user is returning to. Load once.
        if case .loaded = loadState { return }
        loadState = .loading
        do {
            // The provider fills the Plex-specific shelves (popular / categorized /
            // appears-on / similar) for Plex and leaves them empty for MediaBrowser,
            // so the view renders whatever it's handed — no backend branching here.
            let content = try await appModel.musicProvider.artistDetail(artist: artist,
                                                                        libraryID: sectionKey)
            popular = content.popular
            albums = content.albums
            categorized = content.categorized
            appearsOn = content.appearsOn
            similar = content.similar
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One ranked popular-track row: rank (or a tinted waveform when playing), title,
/// and duration. Sibling of `AlbumDetailView`'s TrackRow, with rank instead of
/// track number and no per-row artist (it's always this artist's page).
private struct PopularTrackRow: View {
    let rank: Int
    let track: MediaItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            Group {
                if isCurrent {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                } else {
                    Text(String(rank))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.monospacedDigit())
            .frame(width: DS.Space.xxl, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                // On a track, `parentTitle` is the album.
                if let album = track.parentTitle, !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Space.md)

            if let duration = track.duration {
                Text(formatTrackDuration(milliseconds: duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm + 2)
        .contentShape(Rectangle())
        // Same treatment as the album track rows: highlight from the wrapping button's
        // `.cardLink(cornerRadius: .chip)`; custom styles misroute pinches (DEVELOPMENT.md).
        .padding(.horizontal, DS.Space.sm)
    }
}

