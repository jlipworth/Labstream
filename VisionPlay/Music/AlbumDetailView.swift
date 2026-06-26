import SwiftUI
import PMSKit

/// Plexamp-signature album page: the cover art bleeds behind the whole screen as a
/// heavily-blurred backdrop, with the real cover, album credits, Play/Shuffle actions
/// and the track list in the foreground. Tracks come from the album's children
/// (`GET /library/metadata/{ratingKey}/children`), sorted disc-then-track.
struct AlbumDetailView: View {
    let album: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player

    @State private var tracks: [MediaItem] = []
    @State private var loadState: BrowseLoadState = .idle

    /// Hero cover size, matching the detail-screen poster width.
    private let coverSize: CGFloat = 300

    /// On an *album* item, `parentTitle` is the artist name (PMS hierarchy:
    /// artist → album → track).
    private var albumArtist: String? { album.parentTitle }

    /// The album's artist as a pushable item. Albums from hub rails sometimes omit
    /// `parentRatingKey`, so fall back to the loaded tracks' grandparent linkage.
    private var artistItem: MediaItem? {
        if let key = album.parentRatingKey, let title = albumArtist {
            return MediaItem(ratingKey: key, title: title, type: "artist",
                             thumb: album.parentThumb)
        }
        if let track = tracks.first, let key = track.grandparentRatingKey,
           let title = track.grandparentTitle {
            return MediaItem(ratingKey: key, title: title, type: "artist",
                             thumb: track.grandparentThumb)
        }
        return nil
    }

    var body: some View {
        ZStack {
            artBackdrop

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    header

                    switch loadState {
                    case .idle, .loading:
                        trackSkeleton
                    case .failed(let message):
                        ContentUnavailableView("Couldn’t load \(album.title)",
                                               systemImage: "exclamationmark.triangle",
                                               description: Text(message))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    case .loaded:
                        if tracks.isEmpty {
                            ContentUnavailableView("No tracks",
                                                   systemImage: "music.note",
                                                   description: Text("Nothing to show for \(album.title)."))
                                .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            trackList
                        }
                    }
                }
                .padding(.horizontal, DS.Space.xxl)
                .padding(.vertical, DS.Space.xl)
            }
        }
        .navigationTitle(album.title)
        .task { await load() }
    }

    // MARK: - Backdrop

    /// Blurred, dimmed wash of the album cover behind the content — the same
    /// decorative treatment as `DetailView`'s key-art backdrop. Never hit-testable.
    private var artBackdrop: some View {
        MusicArtBackdrop(art: album.thumb ?? album.art)
    }

    // MARK: - Header

    /// Cover + title/artist/year + Play / Shuffle actions.
    private var header: some View {
        HStack(alignment: .bottom, spacing: DS.Space.xxl) {
            PosterImage(path: album.thumb, width: coverSize, height: coverSize,
                        cornerRadius: DS.Radius.poster)
                .background(DS.posterShadow(RoundedRectangle(cornerRadius: DS.Radius.poster,
                                                             style: .continuous)))

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(album.title)
                    .font(.largeTitle.bold())
                if let artist = albumArtist, !artist.isEmpty {
                    // Tappable like Now Playing's "go to artist" — this view already
                    // lives in the music stack, so a plain value link pushes directly.
                    if let artistItem {
                        NavigationLink(value: artistItem) {
                            Text(artist)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, DS.Space.sm)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .padding(.leading, -DS.Space.sm) // keep text flush with the title
                    } else {
                        Text(artist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                if let year = album.year {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: DS.Space.lg) {
                    Button {
                        player.play(tracks: tracks, startingAt: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.xs)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        player.playAlbumShuffled(tracks: tracks)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.title3)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(tracks.isEmpty)
                .padding(.top, DS.Space.md)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Track list

    /// Tracks on a single material card, separated by hairlines — denser than the
    /// episode rows but the same visual weight.
    private var trackList: some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    player.play(tracks: tracks, startingAt: index)
                } label: {
                    TrackRow(track: track,
                             albumArtist: albumArtist,
                             isCurrent: player.current?.ratingKey == track.ratingKey)
                }
                .cardLink(cornerRadius: DS.Radius.chip)
                // Queue actions (#17 Phase 4). NOTE: contextMenu coexisting with
                // the row's hover chrome is flagged as a risk in MUSIC-DESIGN
                // §3.6 — if hover misbehaves live, fall back to a trailing `…`
                // Menu button.
                .contextMenu { TrackQueueMenu(track: track, player: player) }

                if index < tracks.count - 1 {
                    Divider().padding(.leading, DS.Space.xxl + DS.Space.lg)
                }
            }
        }
        .padding(.vertical, DS.Space.sm)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    /// Shimmering row placeholders keeping the card's footprint while tracks load.
    private var trackSkeleton: some View {
        VStack(spacing: DS.Space.md) {
            ForEach(0..<8, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(height: 40)
                    .overlay { ShimmerView() }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
            }
        }
    }

    private func load() async {
        // `.task` re-fires on pop-back/reappear; tracks don't change mid-session,
        // so load once and keep the view (and its scroll position) stable.
        if case .loaded = loadState { return }
        loadState = .loading
        do {
            // The provider returns tracks already in disc-then-track order for the
            // active backend (Plex children, MediaBrowser album items).
            tracks = try await appModel.musicProvider.albumTracks(album: album)
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One dense track row: number (or a tinted waveform glyph when it's the playing
/// track), title, track artist when it differs from the album artist, and duration.
private struct TrackRow: View {
    let track: MediaItem
    /// The album's artist; the row only shows the track's own artist when it differs
    /// (compilations / featured artists).
    let albumArtist: String?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            Group {
                if isCurrent {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                } else {
                    Text(track.index.map(String.init) ?? "–")
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
                // On a *track*, `grandparentTitle` is the artist (artist → album → track).
                if let artist = track.grandparentTitle, !artist.isEmpty, artist != albumArtist {
                    Text(artist)
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
        // Highlight comes from the wrapping button's `.cardLink(cornerRadius: .chip)` —
        // a custom ButtonStyle misroutes pinches to neighboring rows (DEVELOPMENT.md).
        // The outer inset keeps the row highlight clear of the card's corner curve.
        .padding(.horizontal, DS.Space.sm)
    }
}

