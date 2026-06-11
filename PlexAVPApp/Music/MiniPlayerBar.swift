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
                // Fixed content size + .fitted: the default sheet (and .form —
                // live-tested, no effect on visionOS) tracks the wide window and
                // leaves acres of glass either side of the 300pt art column.
                // ⚠️ Height is capped by the sheet: 760 exceeded it and the overflow
                // was CLIPPED top-and-bottom (live: art and the close button vanished,
                // leaving no way to dismiss). 700 must stay under the grant.
                .frame(width: 620, height: 700)
                // visionOS sheets have no system dismiss affordance, so every sheet
                // needs an explicit close control. It MUST hang off this exact frame:
                // inside NowPlayingView the overlay anchors to the oversized backdrop
                // and gets clipped out of the fitted sheet (live-verified).
                .overlay(alignment: .topTrailing) {
                    Button {
                        presentNowPlaying = false
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
                .presentationSizing(.fitted)
        }
    }

    private func bar(for current: MediaItem) -> some View {
        HStack(spacing: DS.Space.md) {
                PosterImage(path: current.musicArtPath,
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
