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
///   • **Quality** — pick a bitrate cap (granular Mbps ladder + "Maximum (original)") with a
///     resolution hint; selecting one reloads the stream at the new cap and seeks back to the
///     live playhead. Persisted to `@AppStorage("maxVideoBitrateKbps")`. Streaming sessions only.
///   • **Chapters** — jump between Plex chapter markers. visionOS's AVKit does NOT expose
///     `AVNavigationMarkersGroup` / `AVPlayerItem.navigationMarkerGroups` (tvOS/iOS only),
///     so there are no native scrubber chapter ticks; instead each row seeks the playhead
///     directly to the chapter's start. Shown only when chapters exist.
///   • **Subtitles** — pick a soft subtitle rendition (or "Off") from the HLS legible
///     `AVMediaSelectionGroup`. The transcode requests `subtitles=auto`, so PMS muxes the
///     selected/forced subtitle tracks into the stream as selectable renditions, which we
///     switch between with `playerItem.select(_:in:)` — no reload required. See
///     `SubtitlesTabView`.
///   • **Audio** — pick a soundtrack/language rendition from the HLS audible
///     `AVMediaSelectionGroup`, the audio mirror of Subtitles (no "Off" row — a video always
///     plays some soundtrack). Switched with `playerItem.select(_:in:)`; no reload. We surface
///     this ourselves (rather than relying on AVKit's built-in audio submenu) so the picker
///     shows resolved language names and persists the choice across items. See `AudioTabView`.
///   • **Speed** — pick a playback rate (0.5×–2×). See `SpeedTabView`.
///   • **Stats** — a launcher that toggles the floating "Stats for Nerds" diagnostics overlay
///     (rendered over the video by `PlayerView`, not inline in this panel). See `StatsTabView`.
@MainActor
final class PlayerControlSurface {

    private weak var playerVC: AVPlayerViewController?
    private let controller: PlaybackController
    /// Called when the user picks a new bitrate so the caller can persist it.
    private let onBitratePicked: (Int) -> Void
    /// Dismiss hook (the same one the failure overlay / `.fullScreenCover` use). Surfaced as a
    /// native `contextualActions` "Close" so it's reachable in the EXPANDED cinema experience,
    /// where the floated SwiftUI overlays don't render. Shown on a recent tap (the chrome
    /// heuristic) or while paused/failed — not
    /// during normal playback (see `applyContextualActions`).
    private let onClose: (() -> Void)?
    /// Failure-recovery hook: rebuilds the player from the live playhead (a `.id()` bump in
    /// `PlayerView`). Wired to the expanded-mode "Retry" contextual action — `controller.retry()`
    /// alone inherits AVKit's wedged control layer, so recovery must rebuild. Receives the
    /// controller so it doesn't depend on PlayerView's not-yet-published `@State`.
    private let onRetry: ((PlaybackController) -> Void)?

    /// Shared selection state the SwiftUI tabs bind to.
    private let menuState: PlayerMenuState

    /// Heuristic "the system chrome is probably visible" signal — bumped by the tap probe
    /// below, auto-clears after the chrome's own auto-hide window. See `installChromeTapProbe`.
    private let chrome = ChromeHeuristic()
    private let tapProbe = TapProbe()

    init(playerVC: AVPlayerViewController,
         controller: PlaybackController,
         onBitratePicked: @escaping (Int) -> Void,
         onClose: (() -> Void)? = nil,
         onRetry: ((PlaybackController) -> Void)? = nil) {
        self.playerVC = playerVC
        self.controller = controller
        self.onBitratePicked = onBitratePicked
        self.onClose = onClose
        self.onRetry = onRetry
        self.menuState = PlayerMenuState(selectedBitrateKbps: controller.maxVideoBitrateKbps)
        installInfoTabs()
        installChromeTapProbe()
        rebuildContextualActions()
    }

    /// visionOS has no transport-bar/chrome visibility callback (`API_UNAVAILABLE(visionos)`),
    /// so this approximates one: a NON-consuming tap recognizer on the player view fires on the
    /// same look-and-pinch that summons the system chrome, and bumps `chrome.likelyVisible` for
    /// the chrome's ~5s auto-hide window. `applyContextualActions` reads it to show Close
    /// exactly when the user is interacting — without stealing the tap from AVKit (simultaneous
    /// recognition, `cancelsTouchesInView = false`).
    private func installChromeTapProbe() {
        guard let playerVC else { return }
        tapProbe.onTap = { [weak self] in self?.chrome.bump() }
        let tap = UITapGestureRecognizer(target: tapProbe, action: #selector(TapProbe.fired(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = tapProbe
        playerVC.view.addGestureRecognizer(tap)
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
            let chapters = ChaptersTabView(
                chapters: controller.chapters,
                currentMs: { [weak self] in self?.controller.currentResumeMs ?? 0 },
                thumbnailURL: { [weak self] in self?.controller.chapterThumbnailURL(for: $0) },
                onJump: { [weak self] startMs in
                    let target = CMTime(value: CMTimeValue(startMs), timescale: 1000)
                    self?.controller.player.seek(to: target,
                                                 toleranceBefore: .zero,
                                                 toleranceAfter: .zero)
                })
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

        // Audio is always offered (the audio mirror of Subtitles): the audible renditions load
        // asynchronously and can change after a Quality reload swaps the AVPlayerItem, so the tab
        // refreshes on appear and shows a graceful empty state when there's nothing to choose.
        let audio = AudioTabView(
            load: { [weak self] in await self?.controller.loadAudioTracks() },
            onSelect: { [weak self] track in await self?.controller.selectAudio(track) }
        )
        tabs.append(makeTab(audio, title: "Audio", systemImage: "waveform"))

        // Speed: pick a playback rate (0.5×–2×). Always offered (works for streaming and
        // local files); selecting one sets the AVPlayer rate and persists the choice.
        let speed = SpeedTabView(state: controller.speedState) { [weak self] rate in
            self?.controller.setPlaybackSpeed(rate)
        }
        tabs.append(makeTab(speed, title: "Speed", systemImage: "speedometer"))

        // Stats: a launcher that toggles the floating diagnostics overlay (#7). The numbers are
        // rendered over the VIDEO by PlayerView, not inline here, so they stay visible while
        // watching instead of vanishing when the ⓘ panel closes.
        let stats = StatsTabView(state: controller.statsOverlay)
        tabs.append(makeTab(stats, title: "Stats", systemImage: "chart.bar.doc.horizontal"))

        #if os(visionOS)
        playerVC.customInfoViewControllers = tabs
        #else
        if #available(tvOS 15.0, *) {
            playerVC.customInfoViewControllers = tabs
        }
        #endif
    }

    // MARK: - Expanded-mode contextual actions (#23)
    //
    // `PlayerView` floats the failure (Retry/Close), Skip Intro/Credits and Up Next affordances as
    // SwiftUI siblings of the player — they composite over the video ONLY in the inline/windowed
    // state. In the visionOS Expanded cinema experience the system owns the window scene and those
    // siblings vanish, so a stall/failure (or an available Skip / Up Next) there would be a dead
    // end. `AVPlayerViewController.contextualActions` (`visionos(1.0)`) is the AVKit-native slot
    // for controls "displayed during playback" (the same mechanism Apple cites for "Skip Intro");
    // the SYSTEM player renders them, so they follow the player into the expanded/docked cinema
    // experience and stay tappable. We mirror the controller's observable failure/skip/up-next
    // state into that array, with Close always present as the exit.
    //
    // This surface is the SINGLE owner of `contextualActions` (PlayerView no longer sets a Close
    // action directly), so the dynamic action and Close never clobber each other.

    /// Re-derive `contextualActions` now and re-arm observation so any change to the tracked
    /// failure / skip-marker / up-next state re-runs this. `withObservationTracking` fires its
    /// `onChange` once per arming, so we recurse to re-arm — no polling, no extra player observers.
    private func rebuildContextualActions() {
        withObservationTracking {
            applyContextualActions()
        } onChange: { [weak self] in
            // `onChange` fires from the tracked mutation's context; hop to the main actor (where
            // the player + state live) before rebuilding.
            Task { @MainActor [weak self] in self?.rebuildContextualActions() }
        }
    }

    /// Snapshot the observable state and set `contextualActions` to the matching controls. Reading
    /// `playbackError.isFailed`, `skipMarker.active`, `upNext.isShown`/`nextItem` and
    /// `transport.isPaused` here is what registers them with the enclosing
    /// `withObservationTracking`. Priority for the leading, state-driven action: a surfaced
    /// failure (Retry) ▸ an active Skip marker ▸ Up Next ("Play Next"). Close is appended on a
    /// recent tap (`chrome.likelyVisible`) or while paused/failed, so the exit is there exactly
    /// when the user is interacting (or stuck).
    private func applyContextualActions() {
        guard let playerVC else { return }

        // While the INLINE failure dialog is up, hide AVKit's own transport controls. We pause on
        // failure (PlaybackController.surfaceFailure) so a recovering network can't auto-resume
        // playback behind the dialog — but pausing auto-reveals the transport, and on visionOS the
        // system chrome renders ABOVE our SwiftUI error overlay, so the skip/play buttons pop in
        // front of the dialog. Hiding controls clears them; the SwiftUI overlay still offers
        // Retry/Close. We ONLY hide in the embedded/inline state: in the EXPANDED cinema
        // experience there is no SwiftUI dialog and the Retry/Close contextualActions ARE the
        // transport, so hiding controls there would strand the user with no exit.
        let failedInline = controller.playbackError.isFailed
            && playerVC.experienceController.experience == .embedded
        playerVC.showsPlaybackControls = !failedInline

        var actions: [UIAction] = []

        if controller.playbackError.isFailed {
            if let onRetry {
                actions.append(UIAction(title: "Retry",
                                        image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in onRetry(self.controller) }
                })
            }
        } else if let marker = controller.skipMarker.active {
            actions.append(UIAction(title: marker.kind.label,
                                    image: UIImage(systemName: marker.kind.systemImage)) { [weak self] _ in
                Task { @MainActor in self?.controller.skipCurrentMarker() }
            })
        } else if controller.upNext.isShown, controller.upNext.nextItem != nil {
            actions.append(UIAction(title: "Play Next",
                                    image: UIImage(systemName: "play.fill")) { [weak self] _ in
                Task { @MainActor in self?.controller.playNextNow() }
            })
        }

        // Close is offered while the user is INTERACTING — a recent tap (the chrome heuristic),
        // paused, or failed — not during hands-off playback. The system renders contextualActions
        // persistently over the video (until the first tap ties them to the chrome), so an
        // always-present Close pill sat over the picture from the moment the player opened.
        // visionOS has no transport-bar-visibility callback to sync with
        // (`API_UNAVAILABLE(visionos)`), so the tap probe approximates it: the same single tap
        // that summons the system chrome also surfaces Close for the chrome's auto-hide window.
        // Paused/failed keep it up indefinitely. Reading these `@Observable` properties here
        // also registers them with the observation tracking.
        let needsClose = chrome.likelyVisible
            || controller.transport.isPaused
            || controller.playbackError.isFailed
        if let onClose, needsClose {
            actions.append(UIAction(title: "Close",
                                    image: UIImage(systemName: "xmark")) { [weak self] _ in
                Task { @MainActor in
                    // In the Expanded / Immersive cinema experience the system hosts the player in
                    // a SEPARATE full-screen scene (see `AVPlayerViewController` "expanded" docs).
                    // Yanking our `.fullScreenCover` host without first collapsing that scene leaves
                    // the cinema environment on screen with an empty app window (just the tab
                    // ornament) — issue #28. Transition back to `.embedded` first so the system
                    // docks the player into our window, THEN dismiss the cover.
                    //
                    // Pause immediately so the player isn't visibly *playing* during the system's
                    // ~1s expanded->embedded collapse animation — it freezes on the current frame
                    // and reads as "closing" rather than a second window still playing in the
                    // background. The real teardown (`stop()`, which flushes a final timeline) still
                    // runs when the cover is dismantled.
                    self?.playerVC?.player?.pause()
                    if let pvc = self?.playerVC, pvc.experienceController.experience != .embedded {
                        _ = await pvc.experienceController.transition(to: .embedded)
                    }
                    onClose()
                }
            })
        }

        playerVC.contextualActions = actions
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

/// Quality info-panel tab: a granular ladder of bitrate caps with a checkmark on the active one.
private struct QualityTabView: View {
    @Bindable var state: PlayerMenuState
    var onPick: (Int) -> Void

    /// One row in the quality ladder. `kbps == 0` is the "Maximum (original)" sentinel (no cap);
    /// `resolution` is the rough target PMS encodes to at that ceiling (empty for Maximum).
    private struct Option: Identifiable {
        let kbps: Int
        let resolution: String
        var id: Int { kbps }
    }

    /// Bitrate-cap ladder, aligned to Plex's web quality presets so each cap maps to a sensible
    /// resolution. All prior selectable caps (2/4/8/12/20 Mbps + Maximum) are retained — so a
    /// previously-persisted choice still resolves a checkmark — plus 3/10/40 Mbps for finer steps.
    private let options: [Option] = [
        Option(kbps: 2000,  resolution: "720p"),
        Option(kbps: 3000,  resolution: "720p"),
        Option(kbps: 4000,  resolution: "720p"),
        Option(kbps: 8000,  resolution: "1080p"),
        Option(kbps: 10000, resolution: "1080p"),
        Option(kbps: 12000, resolution: "1080p"),
        Option(kbps: 20000, resolution: "1080p"),
        Option(kbps: 40000, resolution: "4K"),
        Option(kbps: 0,     resolution: ""),
    ]

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
                        .contentShape(Rectangle())
                        .padding(.vertical, DS.Space.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DS.Space.md)
        }
    }

    /// "Maximum (original)" for the no-cap sentinel; otherwise "<N> Mbps · <resolution>", e.g.
    /// "8 Mbps · 1080p". Fractional Mbps (none in the current ladder) render without trailing
    /// zeros via `%g`.
    private func label(_ option: Option) -> String {
        guard option.kbps > 0 else { return "Maximum (original)" }
        let mbps = Double(option.kbps) / 1000
        let mbpsText = mbps == mbps.rounded()
            ? String(format: "%.0f", mbps)
            : String(format: "%g", mbps)
        return "\(mbpsText) Mbps · \(option.resolution)"
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

/// One chapter in the horizontal scroller: a 16:9 thumbnail with the chapter
/// title and start timecode stacked below. The current chapter is ringed in the
/// accent color; non-current cards are slightly dimmed. Tapping seeks the
/// playhead to the chapter start. Disabled when the chapter has no start offset.
private struct ChapterCard: View {
    let chapter: Chapter
    let index: Int
    let isCurrent: Bool
    /// Prebuilt thumbnail URL (the Chapters tab is outside the SwiftUI environment
    /// `PosterImage` relies on, so the URL is vended by `PlaybackController` instead).
    let thumbnailURL: URL?
    var onTap: (Int) -> Void

    private static let thumbWidth: CGFloat = 200
    private static let thumbHeight: CGFloat = 112  // 16:9

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
        .buttonStyle(.plain)
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
private struct ChaptersTabView: View {
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
                    LazyHStack(alignment: .top, spacing: DS.Space.md) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                            ChapterCard(chapter: chapter,
                                        index: index,
                                        isCurrent: index == currentIndex,
                                        thumbnailURL: thumbnailURL(chapter.thumb),
                                        onTap: onJump)
                                .id(index)
                        }
                    }
                    .padding(DS.Space.md)
                }
                .onAppear {
                    currentIndex = chapters.indexOfChapter(at: currentMs())
                    if let target = currentIndex {
                        // Defer: scrollTo can no-op against a LazyHStack whose target
                        // cell isn't realized yet on the same runloop tick as onAppear.
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
        // ScrollView + VStack, NOT List — see QualityTabView for why: a `List` doesn't engage
        // scroll inside the visionOS AVKit info panel, so content with many subtitle languages
        // would clip the bottom rows (and the "Off" row stays first). Matches the
        // Quality/Speed/Audio tabs.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Subtitles")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, DS.Space.sm)
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
private struct AudioTabView: View {
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
                Text("Audio")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, DS.Space.sm)
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

/// Stats info-panel tab (#7): a launcher for the floating "Stats for Nerds" overlay. Rather than
/// render the diagnostics inline in the ⓘ panel (where they vanish the moment the panel closes),
/// this tab toggles a persistent on-video overlay (`StatsOverlay` in `PlayerView`) so the numbers
/// stay visible while watching — the Emby-style treatment (#7). Binds to the controller's
/// `@Observable` `StatsOverlayState` so the button label reflects the current shown/hidden state.
private struct StatsTabView: View {
    @Bindable var state: StatsOverlayState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text("Stats for Nerds")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Show live playback diagnostics as an overlay on the video.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    state.toggle()
                } label: {
                    Label(state.isShown ? "Hide Stats Overlay" : "Show Stats Overlay",
                          systemImage: state.isShown ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Chrome heuristic

/// Approximates "the system chrome is visible" on visionOS, which provides no transport-bar
/// visibility callback (`API_UNAVAILABLE(visionos)`). A tap on the player view (the same gesture
/// that summons the chrome) bumps this; it auto-clears after the chrome's ~5s auto-hide window.
@Observable
@MainActor
final class ChromeHeuristic {
    private(set) var likelyVisible = false
    private var hideTimer: Timer?

    /// Mark the chrome as likely visible for `seconds`, restarting the window on repeat taps.
    func bump(for seconds: TimeInterval = 5) {
        likelyVisible = true
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.likelyVisible = false }
        }
    }
}

/// Objective-C target + delegate for the non-consuming tap recognizer on the player view.
/// `shouldRecognizeSimultaneouslyWith` returns true so AVKit's own tap handling (chrome
/// summon, transport interaction) is never starved by our probe.
@MainActor
final class TapProbe: NSObject, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?

    @objc func fired(_ gesture: UITapGestureRecognizer) {
        onTap?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
