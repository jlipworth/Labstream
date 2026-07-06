import SwiftUI
import PMSKit

/// Compact persistent playback bar, mounted as `RootView`'s bottom scene ornament so
/// music keeps playing (and stays controllable) while browsing. Renders nothing when
/// the queue is empty; tapping anywhere outside the transport buttons opens the full
/// `NowPlayingView` sheet.
struct MiniPlayerBar: View {
    @Environment(MusicPlayerController.self) private var player

    @State private var presentNowPlaying = false
    /// When true, the next NowPlaying presentation pre-scrolls to Up Next (the ☰
    /// queue button's behavior); reset on dismiss so a plain tap opens at the top.
    @State private var scrollToQueue = false

    /// Artwork size inside the bar (64-pt visionOS ornament; the iOS 26 tab-view
    /// bottom accessory is shorter, so its art is smaller).
    #if os(visionOS)
    private let artSize: CGFloat = 44
    #else
    private let artSize: CGFloat = 34
    #endif

    var body: some View {
        // The sheet must hang off a node that stays in the hierarchy while the bar
        // itself is gone — scene ornaments float ABOVE window sheets, so leaving the
        // bar visible under NowPlayingView reads as a dead duplicate control.
        ZStack {
            if let current = player.current, !presentNowPlaying {
                bar(for: current)
            }
        }
        .sheet(isPresented: $presentNowPlaying, onDismiss: { scrollToQueue = false }) {
            #if os(iOS)
            // Mobile: standard resizable sheet with system drag-to-dismiss. The fixed
            // 620×700 platter and explicit close/stop overlays below are visionOS
            // affordances (its sheets have no system dismiss control); stop stays on
            // the bar's ✕ here.
            NowPlayingView(scrollToQueue: scrollToQueue)
                .presentationDragIndicator(.visible)
            #else
            NowPlayingView(scrollToQueue: scrollToQueue)
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
                // Stop ends the session outright (vs ✕, which just tucks the sheet
                // away and leaves the music playing behind the mini bar).
                .overlay(alignment: .topLeading) {
                    Button {
                        player.stop()
                        presentNowPlaying = false
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.body.weight(.semibold))
                            .padding(DS.Space.md)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .padding(DS.Space.lg)
                    .accessibilityLabel("Stop music")
                }
                .presentationSizing(.fitted)
            #endif
        }
    }

    @ViewBuilder
    private func bar(for current: MediaItem) -> some View {
        #if os(visionOS)
        barContent(for: current)
            .padding(.horizontal, DS.Space.lg)
            .frame(height: 64)
            .frame(maxWidth: 560)
            // Passive progress hairline along the bottom edge — explicitly NOT a
            // scrub target (a 3-pt drag violates the 60-pt rule; scrubbing lives in
            // the sheet — MUSIC-DESIGN §4.1). Inset past the glass corner radius so
            // it never pokes outside the platter shape.
            .overlay(alignment: .bottom) { progressHairline }
            // Ornament content gets its platter look from glassBackgroundEffect —
            // material backgrounds render flat and z-fight the window edge here.
            .labstreamGlassBackground(in: RoundedRectangle(cornerRadius: DS.Radius.card,
                                                           style: .continuous))
            // Whole bar opens Now Playing; the explicit Buttons above still win the tap.
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .onTapGesture { presentNowPlaying = true }
            .hoverEffect(.highlight)
        #else
        // Inside the iOS 26 tab-view bottom accessory: the system supplies the Liquid
        // Glass capsule, so the bar renders bare content — no platter of its own.
        barContent(for: current)
            .padding(.horizontal, DS.Space.md)
            .overlay(alignment: .bottom) { progressHairline }
            .contentShape(Rectangle())
            .onTapGesture { presentNowPlaying = true }
        #endif
    }

    private func barContent(for current: MediaItem) -> some View {
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

                // The compact iOS accessory keeps only play/pause · next · stop
                // (Apple Music accessory density); previous and the queue shortcut
                // live in the Now Playing sheet there.
                #if os(visionOS)
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                #endif

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

                // Queue shortcut: same sheet as a bar tap, pre-scrolled to Up Next.
                #if os(visionOS)
                Button {
                    scrollToQueue = true
                    presentNowPlaying = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Queue")
                #endif

                // "Turn the music off": full teardown — clears the queue, so the bar
                // (current == nil) removes itself.
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, DS.Space.sm)
                .accessibilityLabel("Stop music")
            }
    }

    /// 3-pt elapsed-time sliver pinned to the bar's bottom edge. Purely decorative:
    /// never hit-testable, no thumb, no drag.
    private var progressHairline: some View {
        GeometryReader { geo in
            let duration = player.durationSeconds
            let fraction = duration > 0
                ? min(1, max(0, player.elapsedSeconds / duration))
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(.tint)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
        .padding(.horizontal, DS.Radius.card)
        .allowsHitTesting(false)
    }
}
