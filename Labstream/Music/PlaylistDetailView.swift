import SwiftUI
import PMSKit

/// Playlist page — a structural clone of `AlbumDetailView` minus the year header and
/// disc sort (MUSIC-DESIGN §3.4): blurred composite-art backdrop, title and
/// track-count/duration credits, Play / Shuffle, and the ordered track list. Items
/// come through `MusicProvider.playlistTracks` and PLAYLIST ORDER IS PRESERVED —
/// no client-side sorting. Per-row 44-pt art because artwork varies across a
/// playlist (unlike an album, where the cover is the header). Read-only in v1.
struct PlaylistDetailView: View {
    let playlist: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player

    @State private var tracks: [MediaItem] = []
    @State private var loadState: BrowseLoadState = .idle

    /// Hero art size, matching the album detail header.
    private let coverSize: CGFloat = 300

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

    // MARK: - Backdrop

    /// Blurred, dimmed wash of the composite art behind the content — same decorative
    /// treatment as `AlbumDetailView`. Never hit-testable.
    private var artBackdrop: some View {
        MusicArtBackdrop(art: playlist.musicArtPath)
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

    /// "42 tracks · 2 hr 5 min" — counts the loaded items when present (truth), the
    /// playlist row's `leafCount`/`duration` before they arrive; drops missing halves.
    private var credits: String? {
        let count = tracks.isEmpty ? playlist.leafCount : tracks.count
        let totalMs = tracks.isEmpty
            ? playlist.duration
            : tracks.compactMap(\.duration).reduce(0, +)
        var parts: [String] = []
        if let count { parts.append(count == 1 ? "1 track" : "\(count) tracks") }
        if let totalMs, totalMs > 0 { parts.append(formatPlaylistDuration(milliseconds: totalMs)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Track list

    /// Tracks on a single material card in PLAYLIST ORDER, separated by hairlines —
    /// same card as the album list, but rows carry 44-pt art instead of numbers.
    private var trackList: some View {
        VStack(spacing: 0) {
            // Position-keyed: a playlist may contain the SAME track twice, so the
            // ratingKey is not a unique row identity here (unlike an album).
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    player.play(tracks: tracks, startingAt: index)
                } label: {
                    PlaylistTrackRow(track: track,
                                     isCurrent: player.current?.ratingKey == track.ratingKey)
                }
                .cardLink(cornerRadius: DS.Radius.chip)
                // Queue actions (#17 Phase 4): playlist items are FULL tracks
                // (Media/Part present), so the shared menu applies directly.
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
        loadState = .loading
        do {
            tracks = try await appModel.musicProvider.playlistTracks(playlist: playlist)
            loadState = .loaded
        } catch {
            loadState = .failed(friendlyMessage(error))
        }
    }
}

/// One playlist track row: 44-pt album art (artwork varies across a playlist),
/// title — tinted with a leading waveform glyph when it's the playing track —
/// "artist · album" subtitle, and duration.
private struct PlaylistTrackRow: View {
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
                if !subtitle.isEmpty {
                    Text(subtitle)
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

            if isCurrent {
                Image(systemName: "waveform")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .contentShape(Rectangle())
        // Highlight comes from the wrapping button's `.cardLink(cornerRadius: .chip)` —
        // a custom ButtonStyle misroutes pinches to neighboring rows (DEVELOPMENT.md).
        // The outer inset keeps the row highlight clear of the card's corner curve.
        .padding(.horizontal, DS.Space.sm)
    }

    /// "artist · album" — `originalTitle` (compilation performer) wins over
    /// `grandparentTitle`; drops whichever half is missing.
    private var subtitle: String {
        let artist = [track.originalTitle, track.grandparentTitle]
            .compactMap { $0 }.first { !$0.isEmpty }
        return [artist, track.parentTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Header total as "2 hr 5 min" / "23 min" — coarse on purpose (Apple Music style);
/// per-row durations stay exact. Shared with the MediaBrowser playlist detail (#111).
func formatPlaylistDuration(milliseconds: Int) -> String {
    let totalMinutes = max(1, milliseconds / 60_000)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min"
}
