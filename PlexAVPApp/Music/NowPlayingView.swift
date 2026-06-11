import SwiftUI
import PMSKit

/// Full now-playing screen, presented as a sheet from `MiniPlayerBar`: blurred
/// cover-art backdrop, big centered artwork, scrubber, transport controls and the
/// Up Next queue. All state lives in `MusicPlayerController`; the only local state
/// is the in-flight scrub position so a drag never fights the playback clock.
struct NowPlayingView: View {
    @Environment(MusicPlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    /// While true, the slider shows `scrubSeconds` instead of the live elapsed time
    /// so the thumb tracks the user's finger; the seek fires once on release.
    @State private var isScrubbing = false
    @State private var scrubSeconds: Double = 0

    /// Hero artwork size — small enough that title, scrubber and transport all fit
    /// in the sheet without scrolling (420 pushed the controls below the fold; a
    /// GeometryReader-driven size broke the sheet's centering — keep this fixed).
    private let artSize: CGFloat = 300

    var body: some View {
        ZStack {
            artBackdrop

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
                    }
                }
                .padding(DS.Space.xxl)
                .frame(maxWidth: .infinity)
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

    // MARK: - Backdrop

    /// Blurred wash of the current artwork behind everything — same decorative
    /// treatment as the album page. Never hit-testable.
    @ViewBuilder
    private var artBackdrop: some View {
        if let art = artPath, !art.isEmpty {
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

    // MARK: - Metadata

    /// Track / artist / album, in descending visual weight. Artist and album are
    /// tappable (Plexamp's "go to artist" / "go to album"): the sheet dismisses and
    /// `RootView` routes the item into the Music tab's navigation stack.
    private var titleBlock: some View {
        VStack(spacing: DS.Space.xs) {
            Text(player.current?.title ?? "Nothing Playing")
                .font(.title2.bold())
                .lineLimit(1)
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
                .hoverEffect(.highlight)
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
                .hoverEffect(.highlight)
                .disabled(albumItem == nil)
            }
        }
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
        dismiss()
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

            HStack {
                Text(formatSeconds(isScrubbing ? scrubSeconds : player.elapsedSeconds))
                Spacer()
                Text(formatSeconds(player.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transport

    /// Shuffle · previous · play/pause · next · repeat.
    private var transportRow: some View {
        HStack(spacing: DS.Space.xxl) {
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
                    .font(.system(size: 72))
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
    private var upNext: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Up Next")
                .font(.title3.bold())

            VStack(spacing: 0) {
                // Index-keyed: shuffled queues can never hold duplicate items, but an
                // explicit positional identity keeps jump targets unambiguous.
                ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
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
                                Text(formatSeconds(Double(duration) / 1000))
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

                    if index < player.queue.count - 1 {
                        Divider().padding(.leading, DS.Space.xxl + DS.Space.md)
                    }
                }
            }
            .padding(.vertical, DS.Space.sm)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .frame(maxWidth: 520)
    }
}

/// Format a second count as `m:ss`, or `h:mm:ss` at an hour or more.
private func formatSeconds(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}
