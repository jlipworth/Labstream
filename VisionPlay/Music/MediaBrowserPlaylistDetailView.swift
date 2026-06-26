import SwiftUI
import PMSKit

/// Playlist page for the MediaBrowser backends (Jellyfin / Emby) (#111). A structural
/// clone of the Plex `PlaylistDetailView` — blurred composite-art backdrop, title +
/// "N tracks · duration" credits, Play / Shuffle, and the ordered track list — but the
/// tracks come from the shared `MusicProvider` (`/Playlists/{id}/Items`, playlist order
/// preserved) and play through the same backend-aware `MusicPlayerController` path.
///
/// A separate view (rather than reusing the Plex `PlaylistDetailView`) because that view
/// loads via Plex's `PlaylistRequest`/`serverBaseURL`; here the provider abstracts the
/// backend. Read-only, matching the Plex playlist detail.
struct MediaBrowserPlaylistDetailView: View {
    let playlist: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player

    @State private var tracks: [MediaItem] = []
    @State private var loadState: HomeView.LoadState = .idle

    /// Hero art size, matching the album/playlist detail header.
    private let coverSize: CGFloat = 300

    var body: some View {
        ZStack {
            MusicArtBackdrop(art: playlist.musicArtPath)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    header

                    switch loadState {
                    case .idle, .loading:
                        trackSkeleton
                    case .failed(let message):
                        ContentUnavailableView("Couldn’t load \(playlist.title)",
                                               systemImage: "exclamationmark.triangle",
                                               description: Text(message))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    case .loaded:
                        if tracks.isEmpty {
                            ContentUnavailableView("No tracks",
                                                   systemImage: "music.note.list",
                                                   description: Text("Nothing to show for \(playlist.title)."))
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
        .navigationTitle(playlist.title)
        .task { await load() }
    }

    // MARK: - Header

    /// Composite art + title + "N tracks · duration" + Play / Shuffle actions.
    private var header: some View {
        HStack(alignment: .bottom, spacing: DS.Space.xxl) {
            PosterImage(path: playlist.musicArtPath, width: coverSize, height: coverSize,
                        cornerRadius: DS.Radius.poster)
                .background(DS.posterShadow(RoundedRectangle(cornerRadius: DS.Radius.poster,
                                                             style: .continuous)))

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(playlist.title)
                    .font(.largeTitle.bold())
                if let credits {
                    Text(credits)
                        .font(.title3)
                        .foregroundStyle(.secondary)
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

    /// "42 tracks · 2 hr 5 min" — counts the loaded items (truth), the playlist row's
    /// `leafCount` before they arrive; drops missing halves.
    private var credits: String? {
        let count = tracks.isEmpty ? playlist.leafCount : tracks.count
        let totalMs = tracks.isEmpty ? nil : tracks.compactMap(\.duration).reduce(0, +)
        var parts: [String] = []
        if let count { parts.append(count == 1 ? "1 track" : "\(count) tracks") }
        if let totalMs, totalMs > 0 { parts.append(formatPlaylistDuration(milliseconds: totalMs)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Track list

    /// Tracks on a single material card in PLAYLIST ORDER, separated by hairlines — same
    /// card as the album list, but rows carry 44-pt art instead of numbers.
    private var trackList: some View {
        VStack(spacing: 0) {
            // Position-keyed: a playlist may contain the SAME track twice, so the
            // ratingKey is not a unique row identity here.
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    player.play(tracks: tracks, startingAt: index)
                } label: {
                    MediaBrowserPlaylistTrackRow(track: track,
                                                 isCurrent: player.current?.ratingKey == track.ratingKey)
                }
                .cardLink(cornerRadius: DS.Radius.chip)
                .contextMenu { TrackQueueMenu(track: track, player: player) }

                if index < tracks.count - 1 {
                    Divider().padding(.leading, DS.Space.xxl + DS.Space.lg + 44)
                }
            }
        }
        .padding(.vertical, DS.Space.sm)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    /// Shimmering row placeholders keeping the card's footprint while items load.
    private var trackSkeleton: some View {
        VStack(spacing: DS.Space.md) {
            ForEach(0..<8, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(height: 52)
                    .overlay { ShimmerView() }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
            }
        }
    }

    private func load() async {
        if case .loaded = loadState { return }
        loadState = .loading
        do {
            // Provider returns the tracks in playlist order; never re-sort.
            tracks = try await MediaBrowserMusicProvider(appModel: appModel)
                .playlistTracks(playlist: playlist)
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One playlist track row: 44-pt album art (artwork varies across a playlist), title —
/// tinted with a leading waveform glyph when it's the playing track — "artist" subtitle,
/// and duration. Mirrors the Plex `PlaylistTrackRow`.
private struct MediaBrowserPlaylistTrackRow: View {
    let track: MediaItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            PosterImage(path: track.musicArtPath, width: 44, height: 44,
                        cornerRadius: DS.Radius.chip)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                // On a track, `grandparentTitle` is the album-artist.
                if let artist = track.grandparentTitle, !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Space.md)

            if isCurrent {
                Image(systemName: "waveform")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
            }
            if let duration = track.duration {
                Text(formatTrackDuration(milliseconds: duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .contentShape(Rectangle())
        .padding(.horizontal, DS.Space.sm)
    }
}
