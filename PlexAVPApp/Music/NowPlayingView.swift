import SwiftUI
import PlexKit

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

    /// Hero artwork size.
    private let artSize: CGFloat = 420

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
                    transportRow

                    if !player.queue.isEmpty {
                        upNext
                    }
                }
                .padding(DS.Space.xxl)
                .frame(maxWidth: .infinity)
            }
        }
        // visionOS sheets have no system dismiss affordance, so every sheet needs an
        // explicit close control (same rule as DownloadOptionsSheet).
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .padding(DS.Space.md)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .padding(DS.Space.lg)
            .accessibilityLabel("Close")
        }
    }

    /// The current track's artwork path: its own thumb, else the album cover.
    private var artPath: String? {
        player.current?.thumb ?? player.current?.parentThumb
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

    /// Track / artist / album, in descending visual weight.
    private var titleBlock: some View {
        VStack(spacing: DS.Space.xs) {
            Text(player.current?.title ?? "Nothing Playing")
                .font(.title2.bold())
                .lineLimit(1)
            // On a track, grandparentTitle == artist and parentTitle == album.
            if let artist = player.current?.grandparentTitle {
                Text(artist)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let albumTitle = player.current?.parentTitle {
                Text(albumTitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
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
        .frame(maxWidth: artSize)
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
                    }
                    .buttonStyle(.plain)

                    if index < player.queue.count - 1 {
                        Divider().padding(.leading, DS.Space.xxl + DS.Space.md)
                    }
                }
            }
            .padding(.vertical, DS.Space.sm)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .frame(maxWidth: artSize + DS.Space.xxxl * 2)
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
