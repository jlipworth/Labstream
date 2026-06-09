import SwiftUI
import AVKit
import PlexKit

/// Builds and owns the coherent in-player control surface layered on top of the native
/// `AVPlayerViewController`, matching the official Plex / Emby players.
///
/// On visionOS the idiomatic, dock-safe affordance is `customInfoViewControllers`: each
/// supplied view controller becomes a **tab** in the player's info panel (the panel that
/// already hosts the native Subtitles/Audio media-selection UI). `transportBarCustomMenuItems`
/// is tvOS-only and unavailable on visionOS, so we deliberately use the info-panel tabs
/// instead — this keeps the stock transport bar and cinema-environment docking intact.
///
/// Tabs provided here:
///   • **Quality** — pick a bitrate cap (2/4/8/12/20 Mbps + Maximum); selecting one reloads
///     the stream at the new cap and seeks back to the live playhead. Persisted to
///     `@AppStorage("maxVideoBitrateKbps")`. Streaming sessions only.
///   • **Chapters** — jump between Plex chapter markers. visionOS's AVKit does NOT expose
///     `AVNavigationMarkersGroup` / `AVPlayerItem.navigationMarkerGroups` (tvOS/iOS only),
///     so there are no native scrubber chapter ticks; instead each row seeks the playhead
///     directly to the chapter's start. Shown only when chapters exist.
///   • **Subtitles** — pick a soft subtitle rendition (or "Off") from the HLS legible
///     `AVMediaSelectionGroup`. The transcode requests `subtitles=auto`, so PMS muxes the
///     selected/forced subtitle tracks into the stream as selectable renditions, which we
///     switch between with `playerItem.select(_:in:)` — no reload required. See
///     `SubtitlesTabView`.
///   • **Stats** — the live "Stats for Nerds" diagnostics panel.
///
/// **Audio** is intentionally NOT reimplemented: `AVPlayerViewController` surfaces the
/// audible `AVMediaSelectionGroup` carried by the HLS automatically in the same info panel.
@MainActor
final class PlayerControlSurface {

    private weak var playerVC: AVPlayerViewController?
    private let controller: PlaybackController
    /// Called when the user picks a new bitrate so the caller can persist it.
    private let onBitratePicked: (Int) -> Void

    /// Shared selection state the SwiftUI tabs bind to.
    private let menuState: PlayerMenuState

    init(playerVC: AVPlayerViewController,
         controller: PlaybackController,
         onBitratePicked: @escaping (Int) -> Void) {
        self.playerVC = playerVC
        self.controller = controller
        self.onBitratePicked = onBitratePicked
        self.menuState = PlayerMenuState(selectedBitrateKbps: controller.maxVideoBitrateKbps)
        installInfoTabs()
    }

    private func installInfoTabs() {
        guard let playerVC else { return }
        var tabs: [UIViewController] = []

        if controller.isStreaming {
            let quality = QualityTabView(state: menuState) { [weak self] kbps in
                guard let self else { return }
                self.controller.reload(bitrateKbps: kbps)
                self.menuState.selectedBitrateKbps = kbps
                self.onBitratePicked(kbps)
            }
            tabs.append(makeTab(quality, title: "Quality", systemImage: "slider.horizontal.3"))
        }

        if !controller.chapters.isEmpty {
            let chapters = ChaptersTabView(chapters: controller.chapters) { [weak self] startMs in
                let target = CMTime(value: CMTimeValue(startMs), timescale: 1000)
                self?.controller.player.seek(to: target,
                                             toleranceBefore: .zero,
                                             toleranceAfter: .zero)
            }
            tabs.append(makeTab(chapters, title: "Chapters", systemImage: "list.bullet"))
        }

        // Subtitles is always offered: the legible renditions load asynchronously (and can
        // change after a Quality reload swaps the AVPlayerItem), so the tab refreshes its
        // track list on appear and renders a graceful empty state when none exist, rather
        // than the surface guessing availability up front.
        let subtitles = SubtitlesTabView(
            load: { [weak self] in await self?.controller.loadSubtitleTracks() },
            onSelect: { [weak self] track in await self?.controller.selectSubtitle(track) }
        )
        tabs.append(makeTab(subtitles, title: "Subtitles", systemImage: "captions.bubble"))

        // Speed: pick a playback rate (0.5×–2×). Always offered (works for streaming and
        // local files); selecting one sets the AVPlayer rate and persists the choice.
        let speed = SpeedTabView(state: controller.speedState) { [weak self] rate in
            self?.controller.setPlaybackSpeed(rate)
        }
        tabs.append(makeTab(speed, title: "Speed", systemImage: "speedometer"))

        let stats = StatsForNerdsView(diagnostics: controller.diagnostics, onClose: nil)
        tabs.append(makeTab(stats, title: "Stats", systemImage: "chart.bar.doc.horizontal"))

        #if os(visionOS)
        playerVC.customInfoViewControllers = tabs
        #else
        if #available(tvOS 15.0, *) {
            playerVC.customInfoViewControllers = tabs
        }
        #endif
    }

    /// Wrap a SwiftUI view in a hosting controller configured as an info-panel tab. The
    /// tab title is taken from the view controller's `title`; `preferredContentSize` sizes
    /// the panel.
    private func makeTab(_ rootView: some View, title: String, systemImage: String) -> UIViewController {
        let host = UIHostingController(rootView: AnyView(rootView))
        host.title = title
        host.tabBarItem = UITabBarItem(title: title,
                                       image: UIImage(systemName: systemImage),
                                       tag: 0)
        host.view.backgroundColor = .clear
        // Keep the hosted view SHORTER than the visionOS ⓘ-panel viewport. If it's taller
        // than the panel, the system clips the overflow instead of scrolling and the List —
        // sized to fit its rows within that too-tall frame — never engages its own scroll, so
        // the bottom rows (e.g. the Quality "Maximum" option) become unreachable. A shorter
        // frame fits inside the panel and forces the List to scroll internally for overflow.
        host.preferredContentSize = CGSize(width: 420, height: 300)
        return host
    }
}

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

/// Quality info-panel tab: a list of bitrate caps with a checkmark on the active one.
private struct QualityTabView: View {
    @Bindable var state: PlayerMenuState
    var onPick: (Int) -> Void

    /// `0` is the "Maximum / Original" sentinel (no cap).
    private let options: [Int] = [2000, 4000, 8000, 12000, 20000, 0]

    var body: some View {
        // ScrollView + VStack, NOT List: a `List` does not engage scroll inside the visionOS
        // AVKit info-panel hosting controller, so the bottom options (notably "Maximum")
        // were unreachable. A plain ScrollView is the lower-level scrollable primitive and
        // scrolls reliably in this embedded context.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Streaming quality")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, DS.Space.sm)
                ForEach(options, id: \.self) { kbps in
                    Button {
                        onPick(kbps)
                    } label: {
                        HStack {
                            Text(label(kbps))
                            Spacer()
                            if kbps == state.selectedBitrateKbps {
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
            .padding(DS.Space.md)
        }
    }

    private func label(_ kbps: Int) -> String {
        kbps <= 0 ? "Maximum" : "\(kbps / 1000) Mbps"
    }
}

/// Speed info-panel tab (R5): a list of playback rates with a checkmark on the active one.
/// Mirrors `QualityTabView`. Selecting a rate sets the AVPlayer rate (and persists it); the
/// checkmark binds to the controller's `PlaybackSpeedState` so it stays correct after a
/// programmatic reapply (e.g. when a Quality reload re-pushes the saved speed).
private struct SpeedTabView: View {
    @Bindable var state: PlaybackSpeedState
    var onPick: (Float) -> Void

    private let options: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        // ScrollView + VStack, NOT List — see QualityTabView for why (List doesn't scroll in
        // the visionOS AVKit info panel).
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Playback speed")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, DS.Space.sm)
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
                        .contentShape(Rectangle())
                        .padding(.vertical, DS.Space.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DS.Space.md)
        }
    }

    private func label(_ rate: Float) -> String {
        rate == 1.0 ? "Normal (1×)"
                    : (rate.truncatingRemainder(dividingBy: 1) == 0
                       ? String(format: "%.0f×", rate)
                       : String(format: "%g×", rate))
    }
}

/// Chapters info-panel tab: tap a chapter to jump the playhead to its start.
private struct ChaptersTabView: View {
    let chapters: [Chapter]
    var onJump: (Int) -> Void

    var body: some View {
        List {
            Section("Chapters") {
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        if let startMs = chapter.startTimeOffset { onJump(startMs) }
                    } label: {
                        HStack {
                            Text(chapter.tag ?? "Chapter \(index + 1)")
                            Spacer()
                            if let startMs = chapter.startTimeOffset {
                                Text(timecode(startMs))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(chapter.startTimeOffset == nil)
                }
            }
        }
    }

    private func timecode(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
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
private struct SubtitlesTabView: View {
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
        List {
            Section("Subtitles") {
                if !didLoad {
                    HStack {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                } else if tracks.isEmpty {
                    Text("No subtitle tracks")
                        .foregroundStyle(.secondary)
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
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
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
