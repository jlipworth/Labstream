import SwiftUI
import AVKit
import PMSKit

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
///   • **Audio** — pick a soundtrack. STREAMING sessions read the track list from Plex part
///     metadata and switch via `audioStreamID` + transcode reload (`AudioStreamsTabView`, #3 —
///     PMS muxes only the active track into the HLS, so AVMediaSelection never lists
///     alternates); local files keep the audible `AVMediaSelectionGroup` path
///     (`AudioTabView`, soft switch, no reload).
///   • **Speed** — pick a playback rate (0.5×–2×). See `SpeedTabView`.
///
/// Stats for Nerds (#6) is an inline info-panel tab (`StatsTabView`) — the panel is SYSTEM
/// chrome, so it's the only stats surface that renders in the EXPANDED cinema experience
/// (no in-process overlay composites there).
@MainActor
final class PlayerControlSurface {

    private weak var playerVC: AVPlayerViewController?
    private let controller: PlaybackController
    /// Called when the user picks a new bitrate so the caller can persist it.
    private let onBitratePicked: (Int) -> Void
    /// Dismiss hook (the same one the failure overlay / `.fullScreenCover` use). Surfaced as a
    /// native `contextualActions` "Close" so it's reachable in the EXPANDED cinema experience,
    /// where the floated SwiftUI overlays don't render. In expanded the system ties the pill to
    /// its chrome; in windowed it's shown on a recent tap or while paused/failed — not
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

    /// Set right before the Close action's own expanded→embedded transition so the delegate
    /// can tell it apart from a SYSTEM-initiated collapse (the platter ✕ under the screen,
    /// or the chrome's shrink-to-window control — `TransitionContext` carries no initiator,
    /// so the two are indistinguishable). An unflagged completed collapse means the user hit
    /// one of those, and per #28 feedback that should close the player, not strand it
    /// embedded — so the delegate calls `onClose`.
    private var appInitiatedCollapse = false

    /// The info-panel tabs as last installed, kept for `dismissInfoPanel`'s rebuild fallback.
    private var infoTabs: [UIViewController] = []
    /// The Chapters tab host — the anchor `dismissInfoPanel` walks up from.
    private weak var chaptersTabVC: UIViewController?

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
        // The launching MediaItem may be a listing copy without chapters (tapping Play can
        // beat DetailView's async metadata refresh — seen live as a missing Chapters tab).
        // Backfill from PMS and rebuild the tab strip if chapters turn up.
        Task { @MainActor [weak self] in
            guard let self, await self.controller.loadChaptersIfNeeded() else { return }
            self.installInfoTabs()
        }
    }

    /// visionOS has no transport-bar/chrome visibility callback (`API_UNAVAILABLE(visionos)`),
    /// so this approximates one: NON-consuming tap recognizers fire on the same look-and-pinch
    /// that summons the system chrome, and bump `chrome.likelyVisible` for the chrome's ~5s
    /// auto-hide window. `applyContextualActions` reads it to show Close exactly when the user
    /// is interacting — without stealing the tap from AVKit (simultaneous recognition,
    /// `cancelsTouchesInView = false`).
    ///
    /// A recognizer on `playerVC.view` only sees taps in the EMBEDDED/windowed state — the
    /// expanded cinema experience hosts the player in a separate scene whose touches never reach
    /// that view (verified live). So the probe is re-anchored onto every in-process window after
    /// each experience transition (we are the `experienceController.delegate`), which covers the
    /// expanded scene's window once it exists.
    private func installChromeTapProbe() {
        guard let playerVC else { return }
        playerVC.experienceController.delegate = self
        reanchorTapProbe()
    }

    /// (Re)attach a `ChromeTapRecognizer` to the player view and every window of every connected
    /// scene, stripping stale ones first (idempotent). The recognizer is self-contained — its
    /// target is itself and the surface is captured weakly — so instances left behind on
    /// long-lived windows (the main app window hosts the `.fullScreenCover`) are inert no-ops
    /// after the surface deallocates, never dangling pointers.
    private func reanchorTapProbe() {
        var anchors: [UIView] = []
        if let view = playerVC?.viewIfLoaded { anchors.append(view) }
        anchors.append(contentsOf: UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows))
        for anchor in anchors {
            for case let stale as ChromeTapRecognizer in anchor.gestureRecognizers ?? [] {
                anchor.removeGestureRecognizer(stale)
            }
            let tap = ChromeTapRecognizer()
            tap.onTap = { [weak self] in self?.chrome.bump() }
            anchor.addGestureRecognizer(tap)
        }
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
                    // Close the ⓘ panel so the pick lands the user back on the video.
                    self?.dismissInfoPanel()
                })
            // Chapters has a known fixed content height (card + two text lines), so ask for
            // a panel just tall enough rather than the default with empty space below.
            let chaptersTab = makeTab(chapters, title: "Chapters", systemImage: "list.bullet",
                                      panelHeight: 220)
            chaptersTabVC = chaptersTab
            tabs.append(chaptersTab)
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

        // Audio is always offered (the audio mirror of Subtitles), but the SOURCE differs by
        // session kind (#3): a streaming session reads the track list from Plex part metadata —
        // PMS muxes only the active audio track into the HLS transcode, so the audible
        // AVMediaSelectionGroup never lists alternates there; switching PUTs the new
        // `audioStreamID` and rebuilds the transcode at the live playhead. Local-file playback
        // keeps the AVMediaSelection path (the downloaded container carries its tracks).
        if controller.isStreaming {
            let audio = AudioStreamsTabView(
                load: { [weak self] in self?.controller.loadAudioStreamChoices() ?? [] },
                onSelect: { [weak self] choice in await self?.controller.selectAudioStream(choice) }
            )
            tabs.append(makeTab(audio, title: "Audio", systemImage: "waveform"))
        } else {
            let audio = AudioTabView(
                load: { [weak self] in await self?.controller.loadAudioTracks() },
                onSelect: { [weak self] track in await self?.controller.selectAudio(track) }
            )
            tabs.append(makeTab(audio, title: "Audio", systemImage: "waveform"))
        }

        // Speed: pick a playback rate (0.5×–2×). Always offered (works for streaming and
        // local files); selecting one sets the AVPlayer rate and persists the choice.
        let speed = SpeedTabView(state: controller.speedState) { [weak self] rate in
            self?.controller.setPlaybackSpeed(rate)
        }
        tabs.append(makeTab(speed, title: "Speed", systemImage: "speedometer"))

        // Stats (#6): live diagnostics rendered INLINE in the panel. This is the only stats
        // surface that works in the EXPANDED cinema experience — no in-process overlay
        // composites there (floated SwiftUI, contentOverlayView, customOverlayViewController:
        // all tried/ruled out), but the ⓘ panel is SYSTEM chrome and renders in both modes.
        // The grid observes `controller.diagnostics`, so it updates live while the panel is up.
        let stats = StatsTabView(diagnostics: controller.diagnostics)
        tabs.append(makeTab(stats, title: "Stats", systemImage: "chart.bar.doc.horizontal"))

        infoTabs = tabs
        #if os(visionOS)
        playerVC.customInfoViewControllers = tabs
        #else
        if #available(tvOS 15.0, *) {
            playerVC.customInfoViewControllers = tabs
        }
        #endif
    }

    /// Best-effort programmatic close of the ⓘ info panel (no public API exists). First walk
    /// up from the Chapters tab to the nearest ancestor that is actually PRESENTED and dismiss
    /// that — `playerVC.presentedViewController` was nil here (verified live), so the panel's
    /// presentation root is somewhere inside AVKit's chrome, not on the player VC. If no
    /// presented ancestor exists either (the panel is likely an ornament, not a presentation),
    /// fall back to emptying `customInfoViewControllers` — removing every tab forces the
    /// ornament closed — and restoring them a beat later. (Re-assigning the SAME array did
    /// NOT collapse it, verified live.)
    private func dismissInfoPanel() {
        var chain: [String] = []
        var vc: UIViewController? = chaptersTabVC
        while let current = vc {
            chain.append(String(describing: type(of: current)))
            if let presenter = current.presentingViewController {
                NSLog("[VP] dismissInfoPanel: presented ancestor, dismissing via %@",
                      String(describing: type(of: presenter)))
                presenter.dismiss(animated: true)
                return
            }
            vc = current.parent
        }
        let window = chaptersTabVC?.viewIfLoaded?.window
        NSLog("[VP] dismissInfoPanel: ornament fallback (experience=%@ window=%@ chain=%@)",
              playerVC?.experienceController.experience == .expanded ? "expanded" : "embedded",
              window.map { String(describing: type(of: $0)) } ?? "nil",
              chain.joined(separator: " > "))
        // The panel is an in-process platter ornament window. Emptying the tab array closes
        // it in WINDOWED but is ignored in EXPANDED (verified live) — there, hiding the
        // backing window is the only in-process lever. `InfoTabHostingController` un-hides
        // it on the next tab appearance, so a reopened panel is never invisible.
        window?.isHidden = true
        playerVC?.customInfoViewControllers = []
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, let playerVC = self.playerVC else { return }
            playerVC.customInfoViewControllers = self.infoTabs
        }
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
    /// failure (Retry) ▸ an active Skip marker ▸ Up Next ("Play Next"). Close is appended in the
    /// expanded experience (`chrome.expandedSticky`, system-managed visibility), on a recent
    /// windowed tap (`chrome.likelyVisible`), or while paused/failed, so the exit is there
    /// exactly when the user is interacting (or stuck).
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
                    Task { @MainActor in
                        // Retry is now in flight and this controller is about to be
                        // discarded — clear the surfaced failure FIRST so the windowed
                        // `PlaybackErrorOverlay` (which observes it) doesn't flash a second
                        // "Retry" dialog during the collapse below (seen live, GH #8).
                        self.controller.playbackError.clear()
                        // Rebuilding while the EXPANDED cinema scene is up wedges it (GH #8,
                        // live: black, tap-dead player after Retry): the `.id()` bump
                        // dismantles the expanded VC and auto-expands a fresh one into the
                        // same system-owned scene mid-teardown. Mirror the Close path:
                        // collapse to embedded first — flagged so the delegate doesn't read
                        // it as a platter close — THEN rebuild; the fresh controller's
                        // autoExpand re-enters the cinema experience cleanly.
                        if let pvc = self.playerVC,
                           pvc.experienceController.experience != .embedded {
                            self.appInitiatedCollapse = true
                            _ = await pvc.experienceController.transition(to: .embedded)
                        }
                        onRetry(self.controller)
                    }
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

        // Close is offered while the user is interacting — not during hands-off playback —
        // via two mechanisms, because visionOS has no transport-bar-visibility callback
        // (`API_UNAVAILABLE(visionos)`):
        //   • EXPANDED: taps never reach our process there (system shell handles them), so
        //     Close stays permanently in the array (`expandedSticky`, set shortly after the
        //     expand transition) and the SYSTEM ties the pill to its own chrome visibility.
        //   • WINDOWED: the tap probe surfaces Close for the chrome's ~5s auto-hide window on
        //     the same tap that summons the chrome (`likelyVisible`).
        // Paused/failed keep it up regardless. Reading these `@Observable` properties here
        // also registers them with the observation tracking.
        let needsClose = chrome.expandedSticky
            || chrome.likelyVisible
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
                        self?.appInitiatedCollapse = true
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
    private func makeTab(_ rootView: some View, title: String, systemImage: String,
                         panelHeight: CGFloat = 300) -> UIViewController {
        let host = InfoTabHostingController(rootView: AnyView(rootView))
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
        // `panelHeight` lets a tab whose content has a known fixed height (Chapters) ask for
        // a shorter panel rather than floating in empty space.
        host.preferredContentSize = CGSize(width: 420, height: panelHeight)
        return host
    }
}

/// Host for every info-panel tab. Exists to undo `dismissInfoPanel`'s window-hide hack:
/// in the EXPANDED experience the panel is an in-process platter ornament
/// (`_MRUIPlatterOrnamentBackingWindow`, verified live) with no presentation to dismiss
/// and no public close API, so dismissal HIDES that window. If the system later reuses
/// the same backing window for the next panel open, the tab's appearance callback is the
/// reopen signal — un-hide it here so the panel is never invisibly "open".
private final class InfoTabHostingController: UIHostingController<AnyView> {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.window?.isHidden = false
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
                        .contentShape(Rectangle())
                        .padding(.vertical, DS.Space.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DS.Space.md)
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
struct ChapterCard: View {
    let chapter: Chapter
    let index: Int
    let isCurrent: Bool
    /// Prebuilt thumbnail URL (the Chapters tab is outside the SwiftUI environment
    /// `PosterImage` relies on, so the URL is vended by `PlaybackController` instead).
    let thumbnailURL: URL?
    var onTap: (Int) -> Void

    // Sized for the info panel's fixed height (#10): the panel is the same size for every
    // tab (system-controlled). 200×112 left a sea of empty space below the rail; 280×158
    // crowded it — 240×135 is the verified middle.
    private static let thumbWidth: CGFloat = 240
    private static let thumbHeight: CGFloat = 135  // 16:9

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
                    LazyHStack(alignment: .top, spacing: DS.Space.md) {
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
                    .padding(.vertical, DS.Space.md)
                }
                // contentMargins, not .padding on the lazy content — see the hit-region
                // gotcha in docs/DEVELOPMENT.md (padding shifts gaze/hit shapes).
                .contentMargins(.horizontal, DS.Space.md, for: .scrollContent)
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

// MARK: - Chrome heuristic

/// Approximates "the system chrome is visible" on visionOS, which provides no transport-bar
/// visibility callback (`API_UNAVAILABLE(visionos)`). A tap on the player view (the same gesture
/// that summons the chrome) bumps this; it auto-clears after the chrome's ~5s auto-hide window.
@Observable
@MainActor
final class ChromeHeuristic {
    private(set) var likelyVisible = false
    private var hideTimer: Timer?

    /// True while the player is in the EXPANDED cinema experience (after a short grace period).
    /// Taps there are handled entirely by the system shell and never enter our process (verified
    /// with window-level recognizers on every reachable window, including the private platter
    /// window), so no tap heuristic is possible. Instead Close stays permanently in the
    /// `contextualActions` array and the SYSTEM ties the pill to its own chrome visibility —
    /// after the first user interaction, contextual actions show/hide with the chrome.
    var expandedSticky = false

    /// Mark the chrome as likely visible for `seconds`, restarting the window on repeat taps.
    func bump(for seconds: TimeInterval = 5) {
        likelyVisible = true
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.likelyVisible = false }
        }
    }
}

/// Non-consuming tap recognizer that is its own target and delegate, so it carries no unretained
/// pointer to anything outside itself — UIKit target-action does NOT retain targets, and these
/// recognizers are installed on long-lived windows that outlive the control surface. The `onTap`
/// closure captures the surface weakly; a recognizer orphaned on the main window after the player
/// closes is a harmless no-op (and is stripped on the next `reanchorTapProbe`).
/// `shouldRecognizeSimultaneouslyWith` returns true so AVKit's own tap handling (chrome summon,
/// transport interaction) is never starved by the probe.
final class ChromeTapRecognizer: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fired))
        cancelsTouchesInView = false
        delegate = self
    }

    @objc private func fired() {
        if state == .ended { onTap?() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Experience transitions

/// Re-anchors the chrome tap probe whenever the player moves between the embedded window and the
/// expanded cinema scene — the destination window may not exist until the transition completes
/// (and can appear a beat later), hence the delayed re-runs, mirroring
/// `CinemaEnvironment.autoExpand`'s polling.
extension PlayerControlSurface: AVExperienceController.Delegate {

    /// How long after an expand transition reports `.finished` before Close joins the
    /// contextual actions. Empirical — see the comment at the use site.
    private static let expandedCloseGrace: Duration = .milliseconds(500)

    func experienceController(_ controller: AVExperienceController,
                              didChangeTransitionContext context: AVExperienceController.TransitionContext) {
        guard case .finished(let result) = context.status else { return }

        // Platter ✕ / shrink-to-window: the system collapses the expanded scene back to
        // embedded on its own. The cinema scene is system-owned, so its ✕ can only ever dock
        // the player back into our window — it cannot quit the app. The user expects "✕ under
        // the screen = done watching", so treat any collapse WE didn't initiate as a close.
        // `TransitionContext` has no initiator field (checked the XROS 26.5 swiftinterface),
        // so the chrome's shrink control is swept up in this too — accepted trade-off.
        if case .completed = result,
           context.fromExperience == .expanded, context.toExperience == .embedded,
           !appInitiatedCollapse {
            NSLog("[VP] system collapse (platter close) -> closing player")
            appInitiatedCollapse = false
            onClose?()
            return
        }
        appInitiatedCollapse = false

        reanchorTapProbe()
        if playerVC?.experienceController.experience == .expanded {
            // Add Close permanently after a short grace so it doesn't sit over the picture
            // during the open animation; from then on the system manages pill visibility
            // alongside its own chrome (taps in the expanded scene never reach our process,
            // so this is the only sync available there). The grace is empirical: the
            // transition's `.finished` fires before the expanded scene visually settles, and
            // there's no system signal for "settled" — too long and a tap inside the window
            // shows chrome with Close popping in late (verified live at 3s; 0.5s feels right).
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.expandedCloseGrace)
                guard let self, self.playerVC?.experienceController.experience == .expanded else { return }
                self.chrome.expandedSticky = true
            }
        } else {
            chrome.expandedSticky = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.reanchorTapProbe()
                try? await Task.sleep(for: .seconds(1))
                self?.reanchorTapProbe()
            }
        }
    }

    func experienceController(_ controller: AVExperienceController,
                              prepareForTransitionUsing context: AVExperienceController.TransitionContext) async {}

    func experienceController(_ controller: AVExperienceController,
                              didChangeAvailableExperiences availableExperiences: AVExperienceController.Experiences) {}
}
