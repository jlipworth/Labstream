import SwiftUI
import PMSKit

/// Playlist page — a structural clone of `AlbumDetailView` minus the year header and
/// disc sort (MUSIC-DESIGN §3.4): blurred composite-art backdrop, title and
/// track-count/duration credits, Play / Shuffle, and the ordered track list. Items
/// come through the duplicate-preserving `PlaylistPagingModel` and PLAYLIST ORDER IS
/// PRESERVED — no client-side sorting or identity de-duplication. Per-row 44-pt art because artwork varies across a
/// playlist (unlike an album, where the cover is the header). Read-only in v1.
struct PlaylistDetailView: View {
    let playlist: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(MusicPlayerController.self) private var player

    @State private var model = PlaylistPagingModel()

    @Environment(\.labstreamCompactWidth) private var compactWidth

    /// Hero art size, matching the album detail header (220 on compact).
    private var coverSize: CGFloat { compactWidth ? 220 : 300 }

    private var source: PlaylistPagingSource {
        PlaylistPagingSource(playlist: playlist, appModel: appModel)
    }

    private var tracks: [MediaItem] { model.items }

    #if os(iOS)
    /// Readable-measure cap for the header + track list in regular width (iPad). Mirrors
    /// `DetailView.readableMetadataWidth`; keeps rows from stretching edge-to-edge on a wide
    /// landscape iPad. visionOS keeps its uncapped fixed-window layout.
    private static let readableContentWidth: CGFloat = 800
    #endif

    var body: some View {
        ZStack {
            artBackdrop

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    header

                    switch model.loadState {
                    case .idle, .loading:
                        trackSkeleton
                    case .failed(let message):
                        ContentUnavailableView {
                            Label("Couldn’t load \(playlist.title)",
                                  systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Retry") { Task { await load(force: true) } }
                        }
                            .frame(maxWidth: .infinity, minHeight: 240)
                    case .loaded:
                        if tracks.isEmpty {
                            ContentUnavailableView("No tracks",
                                                   systemImage: "music.note.list",
                                                   description: Text("Nothing to show for \(playlist.title)."))
                                .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            trackList
                            pagingStatus
                        }
                    }
                }
                .padding(.horizontal, DS.pagePadding(compact: compactWidth))
                .padding(.vertical, DS.Space.xl)
                #if os(iOS)
                // Cap the header + track list to a readable measure on regular-width iOS
                // (13" landscape iPad would otherwise stretch rows edge-to-edge, floating the
                // duration far from the title) and center it. Compact and visionOS stay full width.
                .frame(maxWidth: compactWidth ? .infinity : Self.readableContentWidth)
                .frame(maxWidth: .infinity)
                #endif
            }
        }
        .navigationTitle(playlist.title)
        .task(id: source.identity) { await load() }
        .refreshable { await load(force: true) }
    }

    // MARK: - Backdrop

    /// Blurred, dimmed wash of the composite art behind the content — same decorative
    /// treatment as `AlbumDetailView`. Never hit-testable.
    private var artBackdrop: some View {
        MusicArtBackdrop(art: playlist.musicArtPath)
    }

    // MARK: - Header

    /// Composite art + title + "N tracks · duration" + Play / Shuffle actions.
    /// Compact widths stack the art above the metadata. Regular widths prefer the
    /// side-by-side layout but fall back to the stacked one when the window is too
    /// narrow to seat both without crushing the metadata column — an iPad 50/50
    /// Split View pane is regular size class yet only ~507 pt wide, below the
    /// ~580 pt the hero + fixed action row needs. `ViewThatFits` picks side-by-side
    /// whenever it fits (so visionOS wide windows keep it) and stacks otherwise.
    @ViewBuilder
    private var header: some View {
        if compactWidth {
            stackedHeader
        } else {
            // iOS-only ViewThatFits: it measures the side-by-side variant's IDEAL
            // width, which includes the unwrapped single-line title, so a long
            // playlist title would flip visionOS to the stacked fallback where it
            // previously just wrapped. Only iPad panes get too narrow for the hero.
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

    /// Hero beside the metadata column — the canonical wide layout.
    private var sideBySideHeader: some View {
        HStack(alignment: .bottom, spacing: DS.Space.xxl) {
            headerCover(fillWidth: false)
            headerMetadata
            Spacer(minLength: 0)
        }
    }

    /// Hero centered above the metadata column — compact, and the narrow-regular fallback.
    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            headerCover(fillWidth: true)
            headerMetadata
        }
    }

    private func headerCover(fillWidth: Bool) -> some View {
        PosterImage(path: playlist.musicArtPath, width: coverSize, height: coverSize,
                    cornerRadius: DS.Radius.poster)
            .background(DS.posterShadow(RoundedRectangle(cornerRadius: DS.Radius.poster,
                                                         style: .continuous)))
            .frame(maxWidth: fillWidth ? .infinity : nil)
    }

    private var headerMetadata: some View {
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
            // The old unpaged loader always produced a complete queue. Keep that semantic:
            // page zero may render early, but transport controls stay disabled until every
            // positional row (including duplicates) is present.
            .disabled(tracks.isEmpty || !model.isComplete)
            .padding(.top, DS.Space.md)
        }
    }

    /// "42 tracks · 2 hr 5 min" — counts the loaded items when present (truth), the
    /// playlist row's `leafCount`/`duration` before they arrive; drops missing halves.
    private var credits: String? {
        let count = model.reportedTotal ?? playlist.leafCount ?? (tracks.isEmpty ? nil : tracks.count)
        let totalMs = model.isComplete && !tracks.isEmpty
            ? tracks.compactMap(\.duration).reduce(0, +)
            : playlist.duration
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
                .disabled(!model.isComplete)
                // Queue actions (#17 Phase 4): playlist items are FULL tracks
                // (Media/Part present), so the shared menu applies directly.
                .contextMenu { TrackQueueMenu(track: track, player: player) }

                if index < tracks.count - 1 {
                    // Align the hairline to where PlaylistTrackRow's text starts:
                    // outer inset (sm) + inner padding (lg) + 44-pt art + art→text spacing (lg).
                    Divider().padding(.leading, DS.Space.sm + DS.Space.lg + 44 + DS.Space.lg)
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

    @ViewBuilder
    private var pagingStatus: some View {
        if model.isLoadingNext {
            ProgressView("Loading playlist…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.lg)
        } else if let message = model.nextError {
            VStack(spacing: DS.Space.sm) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task {
                        await model.retryNext(source: source)
                        await model.loadRemaining(source: source)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.lg)
        }
    }

    private func load(force: Bool = false) async {
        await model.loadInitial(source: source, force: force)
        guard case .loaded = model.loadState else { return }
        await model.loadRemaining(source: source)
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
