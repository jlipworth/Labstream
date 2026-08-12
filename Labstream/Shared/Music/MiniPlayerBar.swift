import SwiftUI
import PMSKit

/// Shared presentation state lets the visionOS backdrop and the explicit X take the
/// exact same dismissal path. RootView owns this value because the mini player lives
/// in a scene ornament outside the main window hierarchy.
struct NowPlayingPresentationState: Equatable {
    var isPresented = false
    var scrollToQueue = false

    mutating func present(scrollToQueue: Bool = false) {
        self.scrollToQueue = scrollToQueue
        isPresented = true
    }

    mutating func dismiss() {
        isPresented = false
        scrollToQueue = false
    }
}

#if os(visionOS)
/// Window-owned Now Playing platter. Unlike a system sheet, its sibling backdrop is
/// an actual hit target, so tapping the dimmed surround can dismiss deterministically.
struct VisionNowPlayingPanel: View {
    @Environment(MusicPlayerController.self) private var player

    let scrollToQueue: Bool
    let onDismiss: () -> Void

    var body: some View {
        NowPlayingView(scrollToQueue: scrollToQueue, onRequestDismiss: onDismiss)
            // 700 stays within the existing window grant while retaining the full
            // queue and transport layout used by the former fitted sheet.
            .frame(width: 620, height: 700)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card,
                                        style: .continuous))
            .labstreamGlassBackground(in: RoundedRectangle(cornerRadius: DS.Radius.card,
                                                            style: .continuous))
            // Player-level dismissal follows Labstream's visionOS video-player
            // convention: Close is the leading navigation/cancellation affordance.
            .overlay(alignment: .topLeading) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .padding(DS.Space.md)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .frame(minWidth: 60, minHeight: 60)
                .padding(DS.Space.lg)
                .accessibilityLabel("Close")
            }
            // Stop is a playback action, not navigation, so it occupies the
            // trailing utility-action position rather than displacing Close.
            .overlay(alignment: .topTrailing) {
                Button {
                    player.stop()
                    onDismiss()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.body.weight(.semibold))
                        .padding(DS.Space.md)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .frame(minWidth: 60, minHeight: 60)
                .padding(DS.Space.lg)
                .accessibilityLabel("Stop music")
            }
    }
}
#endif

/// Compact persistent playback bar, mounted as `RootView`'s bottom scene ornament so
/// music keeps playing (and stays controllable) while browsing. Renders nothing when
/// the queue is empty; tapping anywhere outside the transport buttons opens the full
/// `NowPlayingView` presentation.
struct MiniPlayerBar: View {
    @Environment(MusicPlayerController.self) private var player
    @Environment(\.labstreamCompactWidth) private var compactWidth

    @Binding private var presentation: NowPlayingPresentationState
    #if os(macOS)
    @State private var macIsScrubbing = false
    @State private var macScrubSeconds: Double = 0
    #endif

    init(presentation: Binding<NowPlayingPresentationState>) {
        _presentation = presentation
    }

    /// Artwork size inside the bar (64-pt visionOS ornament; the iOS 26 tab-view
    /// bottom accessory is shorter, so its art is smaller).
    #if os(visionOS)
    private let artSize: CGFloat = 44
    #else
    private let artSize: CGFloat = 34
    #endif

    var body: some View {
        #if os(visionOS)
        barBody
        #else
        // The sheet must hang off a node that stays in the hierarchy while the bar
        // itself is gone — leaving the bar visible under NowPlayingView reads as a
        // dead duplicate control.
        barBody
        .sheet(isPresented: $presentation.isPresented,
               onDismiss: { presentation.dismiss() }) {
            #if os(iOS)
            NowPlayingView(scrollToQueue: presentation.scrollToQueue)
                .presentationDragIndicator(.visible)
            #else
            nowPlayingPanel
                .presentationSizing(.fitted)
            #endif
        }
        #endif
    }

    private var barBody: some View {
        ZStack {
            if let current = player.current, !presentation.isPresented {
                bar(for: current)
            }
        }
    }

    #if os(macOS) || os(tvOS)
    private var nowPlayingPanel: some View {
        NowPlayingView(scrollToQueue: presentation.scrollToQueue)
            .frame(width: 620, height: 700)
            .overlay(alignment: .topTrailing) { closeButton }
            .overlay(alignment: .topLeading) { stopButton }
    }
    #endif

    private var closeButton: some View {
        Button { presentation.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .padding(DS.Space.md)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .padding(DS.Space.lg)
        .accessibilityLabel("Close")
    }

    private var stopButton: some View {
        Button {
            player.stop()
            presentation.dismiss()
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

    @ViewBuilder
    private func bar(for current: MediaItem) -> some View {
        #if os(macOS)
        nativeMacBar(for: current)
        #elseif os(visionOS)
        barContent(for: current)
            .padding(.horizontal, DS.Space.lg)
            .frame(height: 64)
            .frame(maxWidth: 560)
            // Passive progress hairline along the bottom edge — explicitly NOT a
            // scrub target (a 3-pt drag violates the 60-pt rule; scrubbing lives in
            // Now Playing — MUSIC-DESIGN §4.1). Inset past the glass corner radius so
            // it never pokes outside the platter shape.
            .overlay(alignment: .bottom) { progressHairline }
            // Ornament content gets its platter look from glassBackgroundEffect —
            // material backgrounds render flat and z-fight the window edge here.
            .labstreamGlassBackground(in: RoundedRectangle(cornerRadius: DS.Radius.card,
                                                           style: .continuous))
            // Whole bar opens Now Playing; the explicit Buttons above still win the tap.
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .onTapGesture { presentation.present() }
            .hoverEffect(.highlight)
        #else
        // Inside the iOS 26 tab-view bottom accessory: the system supplies the Liquid
        // Glass capsule, so the bar renders bare content — no platter of its own.
        barContent(for: current)
            .padding(.horizontal, DS.Space.md)
            .overlay(alignment: .bottom) { progressHairline }
            .contentShape(Rectangle())
            .onTapGesture { presentation.present() }
        #endif
    }

    #if os(macOS)
    /// A compact AppKit-native control card rather than the old full-width dark strip. It keeps
    /// metadata and transport in separate visual groups, exposes a real scrubber, and compresses
    /// by dropping album text before it ever clips primary controls.
    private func nativeMacBar(for current: MediaItem) -> some View {
        HStack(spacing: 12) {
            Button { presentation.present() } label: {
                PosterImage(path: current.musicArtPath,
                            width: 52, height: 52,
                            cornerRadius: 7)
            }
            .buttonStyle(.plain)
            .help("Open Now Playing")
            .accessibilityLabel("Open Now Playing")

            VStack(alignment: .leading, spacing: 5) {
                Button { presentation.present() } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(macMetadataLine(current))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Now Playing")

                Slider(value: Binding(
                    get: { macIsScrubbing ? macScrubSeconds : player.elapsedSeconds },
                    set: { macScrubSeconds = $0 }
                ), in: 0...max(player.durationSeconds, 1), onEditingChanged: { editing in
                    if editing {
                        macScrubSeconds = player.elapsedSeconds
                        macIsScrubbing = true
                    } else {
                        player.seek(to: macScrubSeconds)
                        macIsScrubbing = false
                    }
                })
                .controlSize(.small)
                .accessibilityLabel("Playback position")
                .accessibilityValue(macTimeValue)
                .help("Scrub track")
            }
            .frame(minWidth: 180, idealWidth: 280, maxWidth: 360)

            Divider().frame(height: 38)

            HStack(spacing: 2) {
                macTransportButton("Previous track", systemImage: "backward.fill",
                                   shortcut: .leftArrow) { player.previous() }
                macTransportButton(player.isPlaying ? "Pause" : "Play",
                                   systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                                   shortcut: .space) { player.togglePlayPause() }
                macTransportButton("Next track", systemImage: "forward.fill",
                                   shortcut: .rightArrow) { player.next() }
            }

            Button { presentation.present(scrollToQueue: true) } label: {
                Label("Queue", systemImage: "list.bullet")
                    .labelStyle(.iconOnly)
                    .overlay(alignment: .topTrailing) {
                        if player.queue.count > 1 {
                            Text(String(player.queue.count))
                                .font(.system(size: 8, weight: .bold))
                                .padding(2)
                                .foregroundStyle(.white)
                                .background(.tint, in: Circle())
                                .offset(x: 6, y: -6)
                        }
                    }
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Show Queue (\(player.queue.count) tracks)")
            .accessibilityLabel("Queue, \(player.queue.count) tracks")

            Button { presentation.present() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Open Now Playing")
            .accessibilityLabel("Open Now Playing")

            Button { player.stop() } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Stop Music and Dismiss")
            .accessibilityLabel("Stop music and dismiss mini-player")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 760)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
    }

    private func macMetadataLine(_ current: MediaItem) -> String {
        let values = [current.grandparentTitle, current.parentTitle]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return values.isEmpty ? "Unknown artist" : values.joined(separator: " · ")
    }

    private var macTimeValue: String {
        let current = Int(macIsScrubbing ? macScrubSeconds : player.elapsedSeconds)
        let duration = Int(player.durationSeconds)
        return "\(current / 60):\(String(format: "%02d", current % 60)) of \(duration / 60):\(String(format: "%02d", duration % 60))"
    }

    private func macTransportButton(_ label: String,
                                    systemImage: String,
                                    shortcut: KeyEquivalent,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(shortcut, modifiers: [])
        .help(label)
        .accessibilityLabel(label)
    }
    #endif

    private func barContent(for current: MediaItem) -> some View {
        HStack(spacing: DS.Space.md) {
                PosterImage(path: current.musicArtPath,
                            width: artSize, height: artSize,
                            cornerRadius: DS.Radius.chip)

                VStack(alignment: .leading, spacing: 1) {
                    Text(current.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    // Regular-width music chrome has room for album context; the
                    // compact iPhone accessory deliberately stays at two terse lines.
                    if let subtitle = trackSubtitle(current) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                #if !os(visionOS)
                if showsExpandedContext, let queueContext {
                    Text(queueContext)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: 180, alignment: .leading)
                }
                #endif

                Spacer(minLength: DS.Space.lg)

                // The compact iOS accessory keeps only play/pause · next · stop
                // (Apple Music accessory density); previous and the queue shortcut
                // live in the Now Playing sheet there.
                #if os(visionOS)
                previousButton
                #else
                if showsExpandedContext { previousButton }
                #endif

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(minWidth: Self.transportHit, minHeight: Self.transportHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(minWidth: Self.transportHit, minHeight: Self.transportHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Queue shortcut: same presentation as a bar tap, pre-scrolled to Up Next.
                #if os(visionOS)
                queueButton
                #else
                if showsExpandedContext {
                    queueButton
                    moreMenu(for: current)
                }
                #endif

                // "Turn the music off": full teardown — clears the queue, so the bar
                // (current == nil) removes itself.
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: Self.transportHit, minHeight: Self.transportHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, DS.Space.sm)
                .accessibilityLabel("Stop music")
            }
    }

    /// Mac and regular-width iPad get richer glanceable chrome. Compact iPhone
    /// keeps the system accessory density, and visionOS remains unchanged.
    private var showsExpandedContext: Bool {
        #if os(visionOS)
        false
        #else
        !compactWidth
        #endif
    }

    private func trackSubtitle(_ current: MediaItem) -> String? {
        let artist = current.grandparentTitle
        guard showsExpandedContext, let album = current.parentTitle, !album.isEmpty else {
            return artist
        }
        return [artist, album].compactMap { $0 }.joined(separator: " · ")
    }

    /// Derived from the controller's authoritative `upNextTrack`, so the label honors
    /// repeat and shuffle instead of naïvely reading the next display-order row.
    private var queueContext: String? {
        guard player.queue.count > 1 else { return nil }
        // Repeat-one replays in place — name it honestly rather than a false "Up next".
        if player.repeatMode == .one {
            return player.current.map { "Repeating: \($0.title)" }
        }
        if let next = player.upNextTrack {
            return "Up next: \(next.title)"
        }
        // Nothing follows (queue end, repeat off): fall back to the count summary.
        return "\(player.queue.count) tracks"
    }

    private var previousButton: some View {
        Button { player.previous() } label: {
            Image(systemName: "backward.fill")
                .font(.title3)
                .frame(minWidth: Self.transportHit, minHeight: Self.transportHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Previous track")
    }

    private var queueButton: some View {
        Button {
            presentation.present(scrollToQueue: true)
        } label: {
            Image(systemName: "list.bullet")
                .font(.title3)
                .overlay(alignment: .topTrailing) {
                    if showsExpandedContext, player.queue.count > 1 {
                        Text(String(player.queue.count))
                            .font(.system(size: 8, weight: .bold))
                            .padding(2)
                            .background(.tint, in: Circle())
                            .foregroundStyle(.white)
                            .offset(x: 7, y: -7)
                    }
                }
                .frame(minWidth: Self.transportHit, minHeight: Self.transportHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Queue, \(player.queue.count) tracks")
    }

    private func moreMenu(for current: MediaItem) -> some View {
        Menu {
            if let artist = artistItem(for: current) {
                Button { navigate(to: artist) } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }
            if let album = albumItem(for: current) {
                Button { navigate(to: album) } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
            Divider()
            Button { player.toggleShuffle() } label: {
                Label(player.shuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On",
                      systemImage: "shuffle")
            }
            Button { player.cycleRepeatMode() } label: {
                Label(repeatMenuTitle, systemImage: repeatMenuIcon)
            }
            if player.queue.count > 1 {
                Button { player.clearUpcoming() } label: {
                    Label("Clear Upcoming", systemImage: "text.badge.minus")
                }
            }
            Divider()
            Button(role: .destructive) { player.stop() } label: {
                Label("Stop Music", systemImage: "stop.fill")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .frame(minWidth: Self.transportHit, minHeight: Self.transportHit)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More music controls")
    }

    private var repeatMenuTitle: String {
        switch player.repeatMode {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }

    private var repeatMenuIcon: String {
        player.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private func artistItem(for track: MediaItem) -> MediaItem? {
        guard let key = track.grandparentRatingKey,
              let title = track.grandparentTitle else { return nil }
        return MediaItem(ratingKey: key, title: title, type: "artist",
                         thumb: track.grandparentThumb)
    }

    private func albumItem(for track: MediaItem) -> MediaItem? {
        guard let key = track.parentRatingKey,
              let title = track.parentTitle else { return nil }
        return MediaItem(ratingKey: key, title: title, type: "album",
                         thumb: track.parentThumb)
    }

    private func navigate(to item: MediaItem) {
        player.navigationRequest = item
    }

    /// Minimum hit side for the bar's transport buttons. On touch platforms the bare
    /// title3/footnote glyphs are far under the 44-pt HIG minimum and near-misses fall
    /// through to the whole-bar tap (opening Now Playing instead); visionOS keeps the
    /// ornament's density — gaze targeting doesn't need the padding.
    #if os(visionOS)
    private static let transportHit: CGFloat = 0
    #else
    private static let transportHit: CGFloat = 44
    #endif

    /// 3-pt elapsed-time sliver pinned to the bar's bottom edge. Purely decorative:
    /// never hit-testable, no thumb, no drag.
    private var progressHairline: some View {
        GeometryReader { geo in
            let duration = player.durationSeconds
            let fraction = duration > 0
                ? min(1, max(0, player.elapsedSeconds / duration))
                : 0
            ZStack(alignment: .leading) {
                // .primary, not .white: over the bar's light material in light
                // mode a white track is invisible; .primary adapts (white on dark).
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(.tint)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
        .padding(.horizontal, DS.Radius.card)
        .allowsHitTesting(false)
    }
}
