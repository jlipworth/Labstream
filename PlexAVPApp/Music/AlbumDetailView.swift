import SwiftUI
import PlexKit

/// Plexamp-signature album page: the cover art bleeds behind the whole screen as a
/// heavily-blurred backdrop, with the real cover, album credits, Play/Shuffle actions
/// and the track list in the foreground. Tracks come from the album's children
/// (`GET /library/metadata/{ratingKey}/children`), sorted disc-then-track.
struct AlbumDetailView: View {
    let album: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player

    @State private var tracks: [MediaItem] = []
    @State private var loadState: HomeView.LoadState = .idle

    /// Hero cover size, matching the detail-screen poster width.
    private let coverSize: CGFloat = 300

    /// On an *album* item, `parentTitle` is the artist name (PMS hierarchy:
    /// artist → album → track).
    private var albumArtist: String? { album.parentTitle }

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
    @ViewBuilder
    private var artBackdrop: some View {
        if let art = album.thumb ?? album.art, !art.isEmpty {
            PosterImage(path: art, width: 900, height: 600, cornerRadius: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 60)
                .opacity(0.30)
                .overlay(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
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
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
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
                .buttonStyle(.plain)

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
        guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
            loadState = .failed("No server selected.")
            return
        }
        loadState = .loading
        let req = BrowseAPI.children(server: server, token: token,
                                     identity: appModel.identity, ratingKey: album.ratingKey)
        do {
            let resp = try await appModel.client.send(req, as: MetadataResponse.self)
            // Multi-disc albums: order by disc (`parentIndex`) then track (`index`).
            tracks = resp.mediaContainer.metadata.sorted {
                ($0.parentIndex ?? 1, $0.index ?? 0) < ($1.parentIndex ?? 1, $1.index ?? 0)
            }
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
    }
}

/// Format a track duration as `m:ss`, or `h:mm:ss` at an hour or more.
private func formatTrackDuration(milliseconds: Int) -> String {
    let total = milliseconds / 1000
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}
