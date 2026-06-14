import AVFoundation
import PMSKit
import SwiftUI

/// Shared, observable selection state for the player info tabs (e.g. the active bitrate
/// cap so the Quality tab shows the right checkmark even after a programmatic reload).
@Observable
@MainActor
final class PlayerMenuState {
    var selectedBitrateKbps: Int
    init(selectedBitrateKbps: Int) {
        self.selectedBitrateKbps = selectedBitrateKbps
    }
}

/// Quality info-panel tab: a granular ladder of bitrate caps with a checkmark on the active one.
struct QualityTabView: View {
    @Bindable var state: PlayerMenuState
    var onPick: (Int) -> Void

    /// Bitrate-cap ladder + labels live in `StreamingQuality` (#21), shared with the Settings
    /// "Streaming quality" default picker so the two surfaces can never drift apart.
    private let options = StreamingQuality.ladder

    var body: some View {
        // ScrollView + VStack, NOT List: a `List` does not engage scroll inside the visionOS
        // AVKit info-panel hosting controller, so the bottom options (notably "Maximum")
        // were unreachable. A plain ScrollView is the lower-level scrollable primitive and
        // scrolls reliably in this embedded context.
        ScrollView {
            // No in-view header: the info panel's chrome already titles the tab,
            // so one here read as a duplicate (same for every tab below).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options) { option in
                    Button {
                        onPick(option.kbps)
                    } label: {
                        HStack {
                            Text(label(option))
                            Spacer()
                            if option.kbps == state.selectedBitrateKbps {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.vertical, DS.Space.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ option: StreamingQuality.Option) -> String {
        StreamingQuality.label(kbps: option.kbps)
    }
}

/// Speed info-panel tab (R5): a list of playback rates with a checkmark on the active one.
/// Mirrors `QualityTabView`. Selecting a rate sets the AVPlayer rate (and persists it); the
/// checkmark binds to the controller's `PlaybackSpeedState` so it stays correct after a
/// programmatic reapply (e.g. when a Quality reload re-pushes the saved speed).
struct SpeedTabView: View {
    @Bindable var state: PlaybackSpeedState
    var onPick: (Float) -> Void

    private let options: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        // ScrollView + VStack, NOT List — see QualityTabView for why (List doesn't scroll in
        // the visionOS AVKit info panel).
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options, id: \.self) { rate in
                    Button {
                        onPick(rate)
                    } label: {
                        HStack {
                            Text(label(rate))
                            Spacer()
                            if rate == state.speed {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.vertical, DS.Space.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ rate: Float) -> String {
        rate == 1.0 ? "Normal (1×)"
                    : (rate.truncatingRemainder(dividingBy: 1) == 0
                       ? String(format: "%.0f×", rate)
                       : String(format: "%g×", rate))
    }
}

/// One chapter in the horizontal scroller: a 16:9 thumbnail with the chapter
/// title and start timecode stacked below. The current chapter is ringed in the
/// accent color; non-current cards are slightly dimmed. Tapping seeks the
/// playhead to the chapter start. Disabled when the chapter has no start offset.
struct ChapterCard: View {
    let chapter: Chapter
    let index: Int
    let isCurrent: Bool
    /// Prebuilt thumbnail URL (the Chapters tab is outside the SwiftUI environment
    /// `PosterImage` relies on, so the URL is vended by `PlaybackController` instead).
    let thumbnailURL: URL?
    var onTap: (Int) -> Void

    // Large enough for the custom-player Chapters popover to feel like the old AVP rail while
    // still fitting the system info-panel path. The custom popover is intentionally wide so
    // several chapters remain visible during horizontal scrolling.
    private static let thumbWidth: CGFloat = 286
    private static let thumbHeight: CGFloat = 161  // 16:9-ish, rounded for whole pixels

    var body: some View {
        Button {
            if let startMs = chapter.startTimeOffset { onTap(startMs) }
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                thumbnail
                    .frame(width: Self.thumbWidth, height: Self.thumbHeight)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.poster, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: isCurrent ? 3 : 0)
                    )

                Text(chapter.tag ?? "Chapter \(index + 1)")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let startMs = chapter.startTimeOffset {
                    Text(Self.timecode(startMs))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.thumbWidth, alignment: .leading)
            .opacity(isCurrent ? 1.0 : 0.7)
            .contentShape(Rectangle())
        }
        // Same treatment as browse cards: built-in style via `.cardLink()` — a custom
        // ButtonStyle misregisters the gaze region and misroutes pinches (DEVELOPMENT.md).
        .cardLink()
        .disabled(chapter.startTimeOffset == nil)
    }

    /// 16:9 chapter thumbnail: a shimmering skeleton while loading, a fade-in on
    /// success, and a film-glyph fallback when there's no art (or it fails). Echoes
    /// `PosterImage`'s loading treatment but takes a prebuilt URL (see `thumbnailURL`)
    /// rather than reading the server URL + token from the SwiftUI environment.
    @ViewBuilder private var thumbnail: some View {
        if let thumbnailURL {
            AsyncImage(url: thumbnailURL,
                       transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                case .empty:
                    Rectangle().fill(.regularMaterial).overlay { ShimmerView() }
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    /// Neutral fallback when a chapter has no thumbnail (or it fails to load).
    private var placeholder: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay {
                Image(systemName: "film")
                    .font(.system(size: Self.thumbHeight * 0.3))
                    .foregroundStyle(.secondary)
            }
    }

    /// Milliseconds → `m:ss` (or `h:mm:ss`).
    static func timecode(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// Chapters info-panel tab: a Plex-style horizontal thumbnail rail. Tapping a
/// card seeks the playhead to that chapter's start. On appear we read the live
/// playhead once (`currentMs`), highlight the chapter it sits in, and auto-scroll
/// that card to center. The panel is transient, so a one-shot read is enough — we
/// deliberately do not observe the playhead continuously.
struct ChaptersTabView: View {
    let chapters: [Chapter]
    /// Reads the live playhead in milliseconds at appear time.
    var currentMs: () -> Int
    /// Builds a transcoded thumbnail URL for a chapter's `thumb` key. Threaded in
    /// from the controller because these info tabs are hosted outside the SwiftUI
    /// environment that would otherwise vend the server URL + token.
    var thumbnailURL: (String?) -> URL?
    var onJump: (Int) -> Void

    @State private var currentIndex: Int?

    var body: some View {
        if chapters.isEmpty {
            Text("No chapters")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // Use an eager stack instead of LazyHStack here. Chapter counts are small,
                    // and the custom popover's horizontal rail otherwise only realizes the
                    // initially visible cards; AsyncImage then starts/cancels later thumbnail
                    // requests as the user scrolls, leaving film placeholders for offscreen
                    // chapters that Plex can actually render.
                    HStack(alignment: .top, spacing: DS.Space.md) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                            ChapterCard(chapter: chapter,
                                        index: index,
                                        isCurrent: index == currentIndex,
                                        thumbnailURL: thumbnailURL(chapter.thumb),
                                        onTap: { startMs in
                                            // Immediate in-panel feedback: ring + center the
                                            // picked card (the panel may stay up — programmatic
                                            // dismissal is best-effort, see `dismissInfoPanel`).
                                            currentIndex = index
                                            withAnimation {
                                                proxy.scrollTo(index, anchor: .center)
                                            }
                                            onJump(startMs)
                                        })
                                .id(index)
                        }
                    }
                    .padding(.vertical, DS.Space.sm)
                }
                // contentMargins, not .padding on the lazy content — see the hit-region
                // gotcha in docs/DEVELOPMENT.md (padding shifts gaze/hit shapes).
                .contentMargins(.horizontal, DS.Space.md, for: .scrollContent)
                .onAppear {
                    currentIndex = chapters.indexOfChapter(at: currentMs())
                    if let target = currentIndex {
                        // Defer until the rail has completed layout for the first frame.
                        DispatchQueue.main.async {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

/// Subtitles info-panel tab: pick a soft subtitle rendition (or "Off") from the HLS
/// legible `AVMediaSelectionGroup`.
///
/// WHY soft renditions (and not Plex metadata / burn-in): the transcode requests
/// `subtitles=auto`, so PMS delivers the subtitle tracks muxed into the HLS as selectable
/// legible renditions. Switching between them is instantaneous via `playerItem.select(_:in:)`
/// — no transcode reload and no playhead snapshot, unlike the Quality tab. Burn-in (which
/// WOULD need a reload) is deliberately not wired here because the Plex `Part` model does
/// not currently decode subtitle `Stream` elements, so there's no clean source of stream
/// ids to burn; the soft picker covers the common case the official players surface inline.
///
/// The track list is loaded asynchronously (`load`) on appear because legible options only
/// become known once AVFoundation parses the HLS master playlist — and the list can change
/// after a Quality reload swaps the underlying `AVPlayerItem`. When the legible group is
/// empty we show a graceful "No subtitle tracks" state.
struct SubtitlesTabView: View {
    /// Returns the available tracks and the id of the active one, or `nil` when the HLS
    /// carries no legible group at all.
    ///
    /// Both closures are `@MainActor`: a `SubtitleTrack` carries a non-`Sendable`
    /// `AVMediaSelectionOption`, so it must never cross actor boundaries. Keeping the
    /// picker entirely on the main actor (where the `AVPlayerItem` lives anyway) sidesteps
    /// the data race the compiler would otherwise flag.
    let load: @MainActor () async -> (tracks: [PlaybackController.SubtitleTrack], selectedID: Int)??
    let onSelect: @MainActor (PlaybackController.SubtitleTrack) async -> Void

    @State private var tracks: [PlaybackController.SubtitleTrack] = []
    @State private var selectedID: Int = -1
    @State private var didLoad = false

    var body: some View {
        // ScrollView + VStack, NOT List — see QualityTabView for why: a `List` doesn't engage
        // scroll inside the visionOS AVKit info panel, so content with many subtitle languages
        // would clip the bottom rows (and the "Off" row stays first). Matches the
        // Quality/Speed/Audio tabs.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !didLoad {
                    HStack {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, DS.Space.sm)
                } else if tracks.isEmpty {
                    Text("No subtitle tracks")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, DS.Space.sm)
                } else {
                    ForEach(tracks) { track in
                        Button {
                            // Optimistically reflect the pick, then apply it; re-sync from
                            // the player afterward in case the selection didn't take.
                            selectedID = track.id
                            Task {
                                await onSelect(track)
                                await refresh()
                            }
                        } label: {
                            HStack {
                                Text(track.displayName)
                                Spacer()
                                if track.id == selectedID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, DS.Space.sm)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            // Load once on appear. `.task` is cancelled/re-run if the view identity
            // changes, which is exactly when a reloaded item should be re-read.
            await refresh()
            didLoad = true
        }
    }

    /// Pull the current track list + active selection from the player.
    private func refresh() async {
        // `load` is doubly-optional: the outer `?` is the weak-self capture, the inner is
        // "no legible group". Flatten both to a single optional result.
        if let result = await load(), let (tracks, selectedID) = result {
            self.tracks = tracks
            self.selectedID = selectedID
        } else {
            self.tracks = []
            self.selectedID = -1
        }
    }
}

/// Audio info-panel tab (#3): pick a soundtrack/language rendition from the HLS audible
/// `AVMediaSelectionGroup`. The audio mirror of `SubtitlesTabView` — same async-load-on-appear
/// pattern (audible options only become known once AVFoundation parses the HLS, and the list can
/// change after a Quality reload swaps the `AVPlayerItem`) — but with NO "Off" row (a video
/// always plays some soundtrack) so the active id defaults to the first track, not -1. When the
/// HLS carries fewer than two audible renditions there's nothing to choose, so we show a
/// graceful "No alternate audio tracks" state.
struct AudioTabView: View {
    /// Returns the available tracks and the id of the active one, or `nil` when the HLS carries
    /// fewer than two audible renditions.
    ///
    /// Both closures are `@MainActor`: an `AudioTrack` carries a non-`Sendable`
    /// `AVMediaSelectionOption`, so it must never cross actor boundaries — see `SubtitlesTabView`.
    let load: @MainActor () async -> (tracks: [PlaybackController.AudioTrack], selectedID: Int)??
    let onSelect: @MainActor (PlaybackController.AudioTrack) async -> Void

    @State private var tracks: [PlaybackController.AudioTrack] = []
    @State private var selectedID: Int = 0
    @State private var didLoad = false

    var body: some View {
        // ScrollView + VStack, NOT List — see QualityTabView for why: a `List` doesn't engage
        // scroll inside the visionOS AVKit info panel, so a release with many dub languages
        // (8+ audible renditions) would clip the bottom rows out of reach. Matches the
        // Quality/Speed tabs.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !didLoad {
                    HStack {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, DS.Space.sm)
                } else if tracks.isEmpty {
                    Text("No alternate audio tracks")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, DS.Space.sm)
                } else {
                    ForEach(tracks) { track in
                        Button {
                            // Optimistically reflect the pick, then apply it; re-sync from
                            // the player afterward in case the selection didn't take.
                            selectedID = track.id
                            Task {
                                await onSelect(track)
                                await refresh()
                            }
                        } label: {
                            HStack {
                                Text(track.displayName)
                                Spacer()
                                if track.id == selectedID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, DS.Space.sm)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            // Load once on appear. `.task` is cancelled/re-run if the view identity changes,
            // which is exactly when a reloaded item should be re-read.
            await refresh()
            didLoad = true
        }
    }

    /// Pull the current track list + active selection from the player.
    private func refresh() async {
        // `load` is doubly-optional: the outer `?` is the weak-self capture, the inner is "no
        // audible group / single track". Flatten both to a single optional result.
        if let result = await load(), let (tracks, selectedID) = result {
            self.tracks = tracks
            self.selectedID = selectedID
        } else {
            self.tracks = []
            self.selectedID = 0
        }
    }
}

/// Audio info-panel tab for STREAMING sessions (#3): pick a soundtrack from the item's Plex part
/// metadata (`Stream`, streamType=2) rather than the HLS audible group — PMS muxes only the
/// active audio track into the transcode, so AVMediaSelection never lists alternates there.
/// Always lists at least the active track (checkmarked), so a single-track title shows "English ✓"
/// instead of a confusing empty state. Selecting a different track persists it server-side and
/// rebuilds the transcode at the live playhead (a brief rebuffer, like a Quality switch).
struct AudioStreamsTabView: View {
    /// Reads the current track list from the item metadata (synchronous, pure).
    let load: @MainActor () -> [PlaybackController.AudioStreamChoice]
    /// Applies a pick: PUTs the selection on the part + reloads the transcode.
    let onSelect: @MainActor (PlaybackController.AudioStreamChoice) async -> Void

    @State private var choices: [PlaybackController.AudioStreamChoice] = []
    @State private var didLoad = false
    /// Optimistic checkmark target while the PUT + reload is in flight.
    @State private var pendingID: Int?

    var body: some View {
        // ScrollView + VStack, NOT List — see QualityTabView for why: a `List` doesn't engage
        // scroll inside the visionOS AVKit info panel, so a release with many dub languages
        // would clip the bottom rows out of reach. Matches the Quality/Speed tabs.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if didLoad && choices.isEmpty {
                    Text("No audio track metadata")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, DS.Space.sm)
                } else {
                    ForEach(choices) { choice in
                        Button {
                            guard !choice.isSelected else { return }
                            pendingID = choice.id
                            Task {
                                await onSelect(choice)
                                choices = load()
                                pendingID = nil
                            }
                        } label: {
                            HStack {
                                Text(choice.displayName)
                                Spacer()
                                if (pendingID ?? activeID) == choice.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, DS.Space.sm)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            choices = load()
            didLoad = true
        }
    }

    private var activeID: Int? { choices.first { $0.isSelected }?.id }
}

/// Stats info-panel tab (#6): the live "Stats for Nerds" diagnostics grid, rendered inline.
/// The ⓘ panel is system chrome, so this is the ONLY stats surface that displays in the
/// EXPANDED cinema experience — every floated/overlay approach was tried and ruled out
/// (floated SwiftUI sibling: windowed-only; `contentOverlayView`: never composited on
/// visionOS, verified live; `customOverlayViewController`: tvOS-only). No header row —
/// the system panel already titles the tab.
struct StatsTabView: View {
    let diagnostics: PlaybackDiagnostics

    var body: some View {
        ScrollView {
            StatsForNerdsView(diagnostics: diagnostics, showsHeader: false)
                .padding(DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
