import SwiftUI
import PlexKit

/// Compact persistent playback bar, mounted as `RootView`'s bottom scene ornament so
/// music keeps playing (and stays controllable) while browsing. Renders nothing when
/// the queue is empty; tapping anywhere outside the transport buttons opens the full
/// `NowPlayingView` sheet.
struct MiniPlayerBar: View {
    @Environment(MusicPlayerController.self) private var player

    @State private var presentNowPlaying = false

    /// Artwork size inside the ~64-pt bar.
    private let artSize: CGFloat = 44

    var body: some View {
        let _ = NSLog("[VP] MiniPlayerBar body: current=%@", player.current?.title ?? "nil")
        // The sheet must hang off a node that stays in the hierarchy while the bar
        // itself is gone — scene ornaments float ABOVE window sheets, so leaving the
        // bar visible under NowPlayingView reads as a dead duplicate control.
        ZStack {
            if let current = player.current, !presentNowPlaying {
                bar(for: current)
            }
        }
        .sheet(isPresented: $presentNowPlaying) {
            NowPlayingView()
        }
    }

    private func bar(for current: MediaItem) -> some View {
        HStack(spacing: DS.Space.md) {
                PosterImage(path: current.thumb ?? current.parentThumb,
                            width: artSize, height: artSize,
                            cornerRadius: DS.Radius.chip)

                VStack(alignment: .leading, spacing: 1) {
                    Text(current.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    // On a track, grandparentTitle is the artist.
                    if let artist = current.grandparentTitle {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: DS.Space.lg)

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.Space.lg)
            .frame(height: 64)
            .frame(maxWidth: 480)
            // Ornament content gets its platter look from glassBackgroundEffect —
            // material backgrounds render flat and z-fight the window edge here.
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: DS.Radius.card,
                                                        style: .continuous))
            // Whole bar opens Now Playing; the explicit Buttons above still win the tap.
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .onTapGesture { presentNowPlaying = true }
            .hoverEffect(.highlight)
    }
}
