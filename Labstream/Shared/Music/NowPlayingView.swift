import SwiftUI
import PMSKit

/// Full now-playing screen, presented as a sheet from `MiniPlayerBar`: blurred
/// cover-art backdrop, big centered artwork, scrubber, transport controls and the
/// Up Next queue. All state lives in `MusicPlayerController`; the only local state
/// is the in-flight scrub position so a drag never fights the playback clock.
struct NowPlayingView: View {
    /// When true, the presentation opens pre-scrolled to the Up Next card (the mini bar's
    /// ☰ queue button); default presentation opens at the top as before.
    var scrollToQueue: Bool = false
    /// App-owned visionOS presentation supplies its own dismissal action; system
    /// sheets continue to use the environment dismissal when this is nil.
    var onRequestDismiss: (() -> Void)? = nil

    @Environment(MusicPlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.labstreamCompactWidth) private var compactWidth

    /// While true, the slider shows `scrubSeconds` instead of the live elapsed time
    /// so the thumb tracks the user's finger; the seek fires once on release.
    @State private var isScrubbing = false
    @State private var scrubSeconds: Double = 0

    /// First queue index the Up Next card displays. Trails `player.currentIndex`
    /// by ~1.5s: as playback advances, the played rows pop off the front so the
    /// playing track is always the top row; rewinding prepends them back.
    @State private var displayStart = 0
    /// Queue index of the row pinned at the top of the card's scroll window;
    /// tracks user scrolling and is SET on each front-pop to re-anchor the
    /// playing row at the top.
    @State private var queueTopRow: Int?
    /// In-flight delayed front-pop. The delay is deliberate: an accidental
    /// "next" can be undone with "previous" before the list moves; any further
    /// index change cancels the pending update and re-arms it.
    @State private var followTask: Task<Void, Never>?

    /// Hero artwork size — small enough that title, scrubber and transport all fit
    /// in the sheet without scrolling (420 pushed the controls below the fold; a
    /// GeometryReader-driven size broke the sheet's centering, so this stays a fixed
    /// value rather than measuring). 300 pt overflows a 390-pt phone sheet with the
    /// content padding, so compact width drops to the 220-pt hero.
    private var artSize: CGFloat { DS.Poster.detailWidth(compact: compactWidth) }

    var body: some View {
        ZStack {
            artBackdrop

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: DS.Space.xl) {
                        errorBanner

                        PosterImage(path: artPath, width: artSize, height: artSize,
                                    cornerRadius: DS.Radius.poster)
                            .background(DS.posterShadow(RoundedRectangle(cornerRadius: DS.Radius.poster,
                                                                         style: .continuous)))

                        titleBlock
                        scrubber
                            .frame(maxWidth: 420)
                        transportRow

                        if !player.queue.isEmpty {
                            upNext
                                .id(upNextAnchorID)
                        }
                    }
                    // Compact tightens the horizontal inset to the phone page padding;
                    // the 32-pt regular inset burns too much of a 390-pt sheet column.
                    .padding(.horizontal, compactWidth ? DS.pagePadding(compact: true) : DS.Space.xxl)
                    .padding(.vertical, DS.Space.xxl)
                    .frame(maxWidth: .infinity)
                }
                .onAppear {
                    // The ☰ queue button's pre-scroll (MUSIC-DESIGN §4.1). Unanimated:
                    // an animated scroll during sheet presentation visibly fights the
                    // presentation transition.
                    if scrollToQueue, !player.queue.isEmpty {
                        proxy.scrollTo(upNextAnchorID, anchor: .top)
                    }
                }
            }
        }
        // NOTE: the close X lives in `MiniPlayerBar`'s sheet wrapper, NOT here — an
        // overlay on this ZStack anchors to the 900pt-wide backdrop's bounds, which
        // overflow the 620pt fitted sheet, so the button lands in the clipped margin
        // (live bug: the X silently vanished and the sheet was undismissable).
    }

    /// Album-first art (track thumbs 404 on some PMS builds — see `musicArtPath`).
    private var artPath: String? {
        player.current?.musicArtPath
    }

    /// ScrollViewReader anchor for the Up Next card (queue-button pre-scroll).
    private let upNextAnchorID = "upNext"

    // MARK: - Backdrop

    /// Blurred wash of the current artwork behind everything — same decorative
    /// treatment as the album page. Never hit-testable.
    private var artBackdrop: some View {
        MusicArtBackdrop(art: artPath)
    }

    // MARK: - Metadata

    /// Track / artist / album, in descending visual weight. Artist and album are
    /// tappable (Plexamp's "go to artist" / "go to album"): the sheet dismisses and
    /// `RootView` routes the item into the Music tab's navigation stack.
    private var titleBlock: some View {
        VStack(spacing: DS.Space.xs) {
            Text(player.current?.title ?? "Nothing Playing")
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            // On a track, grandparentTitle == artist and parentTitle == album.
            if let artist = player.current?.grandparentTitle {
                Button {
                    goTo(artistItem)
                } label: {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, DS.Space.sm)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                #if !os(macOS)
                .hoverEffect(.highlight)
                #endif
                .disabled(artistItem == nil)
            }
            if let albumTitle = player.current?.parentTitle {
                Button {
                    goTo(albumItem)
                } label: {
                    Text(albumTitle)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, DS.Space.sm)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                #if !os(macOS)
                .hoverEffect(.highlight)
                #endif
                .disabled(albumItem == nil)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    /// The playing track's artist as a navigable item, when PMS linked one.
    private var artistItem: MediaItem? {
        guard let track = player.current,
              let key = track.grandparentRatingKey,
              let title = track.grandparentTitle else { return nil }
        return MediaItem(ratingKey: key, title: title, type: "artist",
                         thumb: track.grandparentThumb)
    }

    /// The playing track's album as a navigable item.
    private var albumItem: MediaItem? {
        guard let track = player.current,
              let key = track.parentRatingKey,
              let title = track.parentTitle else { return nil }
        return MediaItem(ratingKey: key, title: title, type: "album",
                         thumb: track.parentThumb)
    }

    private func goTo(_ item: MediaItem?) {
        guard let item else { return }
        player.navigationRequest = item
        if let onRequestDismiss {
            onRequestDismiss()
        } else {
            dismiss()
        }
    }

    /// Compact warning when the controller surfaces a playback error.
    @ViewBuilder
    private var errorBanner: some View {
        if let message = player.playbackErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.yellow)
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.sm)
                .background(.thinMaterial, in: Capsule())
        }
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        VStack(spacing: DS.Space.xs) {
            #if os(tvOS)
            ProgressView(value: isScrubbing ? scrubSeconds : player.elapsedSeconds,
                         total: max(player.durationSeconds, 1))
            #else
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubSeconds : player.elapsedSeconds },
                    set: { scrubSeconds = $0 }
                ),
                in: 0...max(player.durationSeconds, 1)
            ) { editing in
                if editing {
                    scrubSeconds = player.elapsedSeconds
                    isScrubbing = true
                } else {
                    player.seek(to: scrubSeconds)
                    isScrubbing = false
                }
            }
            .disabled(player.current == nil)
            #endif

            HStack {
                Text(formatTrackDuration(seconds: isScrubbing ? scrubSeconds : player.elapsedSeconds))
                Spacer()
                Text(formatTrackDuration(seconds: player.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transport

    /// Shuffle · previous · play/pause · next · repeat.
    private var transportRow: some View {
        HStack(spacing: compactWidth ? DS.Space.lg : DS.Space.xxl) {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(player.shuffleEnabled ? AnyShapeStyle(.tint)
                                                           : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: compactWidth ? 56 : 72))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)

            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: repeatIcon)
                    .font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary)
                                                               : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
        }
        .disabled(player.current == nil)
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off, .all: "repeat"
        case .one: "repeat.1"
        }
    }

    // MARK: - Up Next

    /// The play queue; the current row is highlighted and any row jumps playback.
    /// Per-row long-press menu offers Move Up / Move Down / Remove (#17 Phase 4 —
    /// the design's documented fallback to `List.onMove`, whose drag handles need
    /// a real `List` and are flagged finicky under gaze input); the header's
    /// Clear button drops everything but the current track.
    private var upNext: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Text("Up Next")
                    .font(.title3.bold())
                Spacer()
                if player.queue.count > 1 {
                    Button {
                        player.clearUpcoming()
                    } label: {
                        Text("Clear")
                            .font(.subheadline)
                            .padding(.horizontal, DS.Space.xs)
                    }
                    .labstreamGlassButtonStyle()
                    .accessibilityLabel("Clear queue")
                }
            }

            // The card shows queue[displayStart...] only — played tracks pop off
            // the front (Plexamp-style "Up Next"), they don't accumulate above the
            // highlight. Scrolling the sheet to "follow" the row was wrong twice
            // over (live): it moved the whole screen, and the dead rows stayed.
            ScrollView {
                queueRows
            }
            .frame(height: queueWindowHeight)
            .scrollBounceBehavior(.basedOnSize)
            // Declarative re-anchor: a pop shrinks the content ABOVE the viewport,
            // so a scrolled list leapt to arbitrary rows and the playing track
            // vanished (live: "there is no anchor"). ScrollViewReader.scrollTo in
            // the same transaction resolved against stale layout (live: still
            // jumped) — scrollPosition commits with the content change instead.
            .scrollPosition(id: $queueTopRow, anchor: .top)
            .onAppear {
                // Open already trimmed to the playing track — no pop animation
                // during sheet presentation.
                displayStart = player.currentIndex ?? 0
            }
            // Trail playback: pop played rows / prepend rewound ones after a
            // grace period, so an accidental "next" can be undone with
            // "previous" before the list moves.
            .onChange(of: player.currentIndex) { _, newIndex in
                followTask?.cancel()
                guard let index = newIndex else { return }
                followTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.5)) {
                        displayStart = index
                        queueTopRow = index
                    }
                }
            }
            .onDisappear { followTask?.cancel() }
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .frame(maxWidth: 520)
    }

    /// Height of the queue's scroll window: caps at ~6.5 rows so a long queue
    /// visibly scrolls (the half row signals there's more), but shrinks to fit
    /// what's left to play so the card carries no dead glass.
    private var queueWindowHeight: CGFloat {
        let rowHeight: CGFloat = 52   // two text lines + vertical padding + divider
        let visibleCount = max(1, player.queue.count - displayStart)
        return min(rowHeight * 6.5, CGFloat(visibleCount) * rowHeight + DS.Space.sm * 2)
    }

    private var queueRows: some View {
            VStack(spacing: 0) {
                // Index-keyed: shuffled queues can never hold duplicate items, but an
                // explicit positional identity keeps jump targets unambiguous. The
                // dropFirst is the front-pop: indices stay ABSOLUTE queue offsets,
                // so jump/move/remove are untouched by the trimming.
                ForEach(Array(player.queue.enumerated().dropFirst(displayStart)),
                        id: \.offset) { index, track in
                    let isCurrent = index == player.currentIndex
                    Button {
                        player.jump(to: index)
                    } label: {
                        HStack(spacing: DS.Space.md) {
                            Image(systemName: isCurrent ? "waveform" : "music.note")
                                .font(.caption)
                                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint)
                                                           : AnyShapeStyle(.tertiary))
                                .frame(width: DS.Space.xl)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title)
                                    .font(.subheadline)
                                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint)
                                                               : AnyShapeStyle(.primary))
                                    .lineLimit(1)
                                if let artist = track.grandparentTitle {
                                    Text(artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: DS.Space.md)
                            if let duration = track.duration {
                                Text(formatTrackDuration(seconds: Double(duration) / 1000))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.sm)
                        .contentShape(Rectangle())
                        .padding(.horizontal, DS.Space.sm)
                    }
                    // Built-in style via `.cardLink()` — a custom ButtonStyle misregisters
                    // the gaze region and misroutes pinches to a NEIGHBORING row
                    // (DEVELOPMENT.md); the chip-radius contentShape tames its highlight.
                    .cardLink(cornerRadius: DS.Radius.chip)
                    // Int identity feeds scrollPosition's re-anchor (pins the
                    // playing row to the top of the card after a front-pop).
                    .id(index)
                    .contextMenu {
                        Button {
                            player.move(fromOffsets: IndexSet(integer: index),
                                        toOffset: index - 1)
                        } label: {
                            Label("Move Up", systemImage: "arrow.up")
                        }
                        // Can't move above the visible top — the rows before
                        // displayStart are played-and-popped, not reorder targets.
                        .disabled(index <= displayStart)

                        Button {
                            // onMove semantics: one row down = original offset + 2.
                            player.move(fromOffsets: IndexSet(integer: index),
                                        toOffset: index + 2)
                        } label: {
                            Label("Move Down", systemImage: "arrow.down")
                        }
                        .disabled(index == player.queue.count - 1)

                        Button(role: .destructive) {
                            player.remove(at: index)
                        } label: {
                            Label("Remove from Queue", systemImage: "trash")
                        }
                    }

                    if index < player.queue.count - 1 {
                        Divider().padding(.leading, DS.Space.xxl + DS.Space.md)
                    }
                }
            }
            .padding(.vertical, DS.Space.sm)
            // Exposes the rows' Int ids to `scrollPosition` for the re-anchor.
            .scrollTargetLayout()
    }
}
