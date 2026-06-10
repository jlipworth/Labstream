import SwiftUI
import PlexKit

/// Compact persistent playback bar, overlaid at the bottom of `RootView` so music
/// keeps playing (and stays controllable) while browsing. Renders nothing when the
/// queue is empty; tapping anywhere outside the transport buttons opens the full
/// `NowPlayingView` sheet.
struct MiniPlayerBar: View {
    @Environment(MusicPlayerController.self) private var player

    @State private var presentNowPlaying = false

    /// Artwork size inside the ~64-pt bar.
    private let artSize: CGFloat = 44

    var body: some View {
        if let current = player.current {
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
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
            // Whole bar opens Now Playing; the explicit Buttons above still win the tap.
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .onTapGesture { presentNowPlaying = true }
            .hoverEffect(.highlight)
            // Float clear of the window edge.
            .padding(.horizontal, DS.Space.xxl)
            .padding(.bottom, DS.Space.lg)
            .sheet(isPresented: $presentNowPlaying) {
                NowPlayingView()
            }
        } else {
            EmptyView()
        }
    }
}
