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

    @Environment(\.labstreamCompactWidth) private var compactWidth

    /// Hero cover size, matching the detail-screen poster width (220 on compact,
    /// mirroring `DetailView`'s compact poster).
    private var coverSize: CGFloat { compactWidth ? 220 : 300 }

    #if os(iOS)
    /// Readable-measure cap for the track list and header text column in regular width
    /// (iPad), mirroring `DetailView.readableMetadataWidth`. Without it the track rows
    /// stretch edge-to-edge on a 13" iPad and the duration label floats ~1200 pt from the
    /// title. Compact widths (iPhone, narrow split) stay full-bleed; visionOS keeps its
    /// fixed-window layout uncapped.
    private static let readableContentWidth: CGFloat = 680
    #endif

    /// The readable-width cap applied to the header metadata column and the track list:
    /// the readable measure on regular-width iOS, `nil` (uncapped) on compact iOS and on
    /// visionOS. Leading-aligned so the capped block stays flush left, not centered.
    private var contentMaxWidth: CGFloat? {
        #if os(iOS)
        compactWidth ? nil : Self.readableContentWidth
        #else
        nil
        #endif
    }

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
                .padding(.horizontal, DS.pagePadding(compact: compactWidth))
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

    /// Cover + title/artist/year + Play / Shuffle actions. Side-by-side on regular width;
    /// compact phones stack the cover (centered) above the metadata — the 300-pt cover +
    /// large-title text row cannot fit a 390-pt screen. On regular width, `ViewThatFits`
    /// keeps the side-by-side layout while it fits (visionOS wide windows, full-screen
    /// iPad) and falls back to the same stacked layout when the pane is too tight — e.g.
    /// a ~507-pt iPad Split View column, which is a REGULAR size class but too narrow for
    /// the 300-pt cover beside the metadata + buttons.
    @ViewBuilder
    private var header: some View {
        if compactWidth {
            stackedHeader
        } else {
            // iOS-only ViewThatFits: it measures the side-by-side variant's IDEAL
            // width, which includes the unwrapped single-line title, so a long album
            // title would flip visionOS to the stacked fallback where it previously
            // just wrapped. Only iPad panes actually get too narrow to seat the hero.
            #if os(iOS)
            ViewThatFits(in: .horizontal) {
                sideBySideHeader
                stackedHeader
            }
            #else
            sideBySideHeader
            #endif
        }
    }

    /// Cover beside the metadata column (canonical wide layout).
    private var sideBySideHeader: some View {
        HStack(alignment: .bottom, spacing: DS.Space.xxl) {
            headerCover(centered: false)
            headerMetadata
            Spacer(minLength: 0)
        }
    }

    /// Cover centered above the metadata column — the compact idiom, reused as the
    /// regular-width `ViewThatFits` fallback for a too-narrow Split View pane.
    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            headerCover(centered: true)
            headerMetadata
        }
    }

    private func headerCover(centered: Bool) -> some View {
        PosterImage(path: album.thumb, width: coverSize, height: coverSize,
                    cornerRadius: DS.Radius.poster)
            .background(DS.posterShadow(RoundedRectangle(cornerRadius: DS.Radius.poster,
                                                         style: .continuous)))
            .frame(maxWidth: centered ? .infinity : nil)
    }

    private var headerMetadata: some View {
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
                .labstreamGlassProminentButtonStyle()

                Button {
                    player.playAlbumShuffled(tracks: tracks)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.title3)
                }
                .labstreamGlassButtonStyle()
            }
            .disabled(tracks.isEmpty)
            .padding(.top, DS.Space.md)
        }
        // Cap the metadata column to a readable measure on regular-width iPad so the title
        // and actions don't stretch across a 13" landscape pane (no-op on compact/visionOS).
        .frame(maxWidth: contentMaxWidth, alignment: .leading)
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
        // Cap the card to a readable measure on regular-width iPad so rows don't stretch
        // ~1370 pt (no-op on compact/visionOS). Leading-aligned within the page column.
        .frame(maxWidth: contentMaxWidth, alignment: .leading)
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

