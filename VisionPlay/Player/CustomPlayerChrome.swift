import AVFoundation
import PMSKit
import SwiftUI
import UIKit

/// Shared scrubber-clock tick used by both the windowed custom player and the Cinema scene.
///
/// Resolves the live duration from the player item (falling back to the catalog duration) and
/// pushes the controller's resume position into the scrub state unless the user is mid-drag.
@MainActor
func tickCustomScrubberClock(_ scrubState: inout PlaybackScrubState,
                             from controller: PlaybackController,
                             fallbackDurationMs: Int) {
    let duration = controller.player.currentItem?.duration
    let durationMs: Int
    if let duration, duration.seconds.isFinite, duration.seconds > 0 {
        durationMs = Int((duration.seconds * 1000).rounded())
    } else {
        durationMs = fallbackDurationMs
    }
    scrubState.updateDuration(durationMs)
    if !scrubState.isDragging {
        scrubState.updateLivePosition(controller.currentResumeMs)
    }
}

/// App-owned full-screen chrome for the custom player.
///
/// This deliberately carries the playback feature set that used to live in system surfaces: the
/// custom route must not regress just because it owns its transport. The chrome behaves like player chrome,
/// not permanent app UI: taps reveal it, playback auto-hides it, and modal menu/error/reconnect
/// states keep it visible while the viewer is acting on them.
struct CustomPlayerChrome: View {
    @Environment(CustomCinemaSessionStore.self) private var cinemaSession
    @Environment(RealityTheaterSessionStore.self) private var realityTheaterSession
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    let controller: PlaybackController
    let title: String
    @Binding var scrubState: PlaybackScrubState
    let trickPlayProvider: (any TrickPlayThumbnailProviding)?
    let onRetry: () -> Void
    let onClose: (() -> Void)?
    let allowsRealityTheater: Bool

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var selectedMenu: CustomPlayerMenuKind?
    @State private var menuState: PlayerMenuState
    @State private var trickPlayPreviewTask: Task<Void, Never>?
    @State private var trickPlayPreviewImage: UIImage?
    @State private var trickPlayPreviewTimeMs: Int?
    @State private var trickPlayPreviewLoading = false
    @State private var trickPlayImageCache = TrickPlayPreviewImageCache(limit: 32)

    init(controller: PlaybackController,
         title: String,
         scrubState: Binding<PlaybackScrubState>,
         trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
         onRetry: @escaping () -> Void,
         onClose: (() -> Void)?,
         allowsRealityTheater: Bool = false) {
        self.controller = controller
        self.title = title
        _scrubState = scrubState
        self.trickPlayProvider = trickPlayProvider
        self.onRetry = onRetry
        self.onClose = onClose
        self.allowsRealityTheater = allowsRealityTheater
        _menuState = State(initialValue: PlayerMenuState(selectedBitrateKbps: controller.maxVideoBitrateKbps))
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectedMenu != nil {
                        closeMenu()
                    } else {
                        revealChrome()
                    }
                }

            if shouldShowChrome {
                topChrome
                    .transition(.opacity)
            }

            transientStatusOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(40)
                .transition(.scale(scale: 0.96).combined(with: .opacity))

            offlineSubtitleOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 80)
                .padding(.bottom, chromeVisible ? 168 : 64)
                .animation(.easeInOut(duration: 0.2), value: chromeVisible)

            VStack {
                Spacer()

                if let marker = controller.skipMarker.active {
                    HStack {
                        Spacer()
                        Button {
                            controller.skipCurrentMarker()
                        } label: {
                            Label(marker.kind.label, systemImage: marker.kind.systemImage)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 34)
                    .padding(.bottom, 14)
                    .transition(.opacity)
                }

                if controller.upNext.isShown, let next = controller.upNext.nextItem {
                    upNextCard(next)
                        .padding(.horizontal, 34)
                        .padding(.bottom, 14)
                }

                if shouldShowChrome {
                    controls
                        .padding(.horizontal, 34)
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if let selectedMenu {
                GeometryReader { geo in
                    VStack {
                        Spacer()
                        CustomPlayerMenuPopover(menu: selectedMenu,
                                                controller: controller,
                                                menuState: menuState,
                                                widthOverride: adaptiveMenuWidth(for: selectedMenu,
                                                                                 available: geo.size.width),
                                                onClose: { closeMenu() })
                            .frame(maxWidth: .infinity, alignment: selectedMenu.popoverAlignment)
                            .padding(.horizontal, 54)
                            .padding(.bottom, 176)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: shouldShowChrome)
        .animation(.easeInOut(duration: 0.18), value: selectedMenu)
        .animation(.easeInOut(duration: 0.18), value: controller.skipMarker.active != nil)
        .onAppear { revealChrome() }
        .onDisappear {
            hideTask?.cancel()
            trickPlayPreviewTask?.cancel()
        }
        .onChange(of: controller.transport.isPaused) { _, _ in scheduleChromeHideIfNeeded() }
        .onChange(of: controller.transport.pauseRequested) { _, _ in scheduleChromeHideIfNeeded() }
        .onChange(of: controller.transportStatus.status) { _, _ in
            scheduleChromeHideIfNeeded()
        }
    }

    private var shouldShowChrome: Bool {
        chromeVisible || controller.transport.showsPausedControl || controller.transportStatus.keepsChromeVisible || selectedMenu != nil
    }

    @ViewBuilder private var offlineSubtitleOverlay: some View {
        if let text = controller.offlineSubtitleOverlay.text, !text.isEmpty {
            Text(text)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 8)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var transientStatusOverlay: some View {
        // The chrome renders the controller-owned transport status verbatim. It does not compose
        // buffering, retry, and failure booleans, so Cinema cannot show duplicate dialogs when HLS
        // delivery chatters between waiting and playing.
        if let status = controller.transportStatus.activeStatus {
            CustomTransportStatusOverlay(status: status,
                                         onRetry: {
                                             revealChrome()
                                             onRetry()
                                         },
                                         onClose: onClose,
                                         onTogglePause: {
                                             revealChrome(keepVisible: true)
                                             controller.togglePlayback()
                                         })
        }
    }

    private var topChrome: some View {
        VStack {
            HStack(spacing: 14) {
                if let onClose {
                    Button(action: {
                        revealChrome()
                        onClose()
                    }) {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .font(.title3.weight(.semibold))
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()
            }
            .padding(28)

            Spacer()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Give the title a little more room than before, but keep it capped so the
                    // fixed-size menu pills remain legible/tappable instead of getting squeezed.
                    .frame(minWidth: 220, maxWidth: 560, alignment: .leading)
                    .layoutPriority(1)
                    .accessibilityLabel(title)

                Spacer(minLength: 8)

                cinemaButton
                    .fixedSize(horizontal: true, vertical: false)

                realityTheaterDeveloperButton
                    .fixedSize(horizontal: true, vertical: false)

                menuStrip
                    .fixedSize(horizontal: true, vertical: false)
            }

            if scrubState.isDragging, trickPlayProvider != nil {
                trickPlayPreview
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 16) {
                Button(action: {
                    revealChrome()
                    controller.togglePlayback()
                    scheduleChromeHideIfNeeded()
                }) {
                    Image(systemName: controller.transport.showsPausedControl ? "play.fill" : "pause.fill")
                        .font(.title2.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)

                skipControls

                Text(format(ms: scrubState.displayedPositionMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)

                Slider(value: scrubberBinding, in: 0...1) { editing in
                    handleScrubEditingChanged(editing)
                }
                .disabled(scrubState.durationMs <= 0)

                Text(format(ms: scrubState.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }


    @ViewBuilder private var trickPlayPreview: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                if let trickPlayPreviewImage {
                    Image(uiImage: trickPlayPreviewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else if trickPlayPreviewLoading {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay { ShimmerView() }
                } else {
                    Image(systemName: "film")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 107)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
            }

            Text(format(ms: trickPlayPreviewTimeMs ?? scrubState.displayedPositionMs))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 16)
        .allowsHitTesting(false)
        .accessibilityLabel("Scrub preview")
    }

    private var skipControls: some View {
        HStack(spacing: 8) {
            skipButton(seconds: -30)
            skipButton(seconds: -10)
            skipButton(seconds: 10)
            skipButton(seconds: 30)
        }
    }

    private func skipButton(seconds: Int) -> some View {
        let isForward = seconds > 0
        let amount = abs(seconds)
        return Button {
            performRelativeSkip(seconds: seconds)
        } label: {
            Label(isForward ? "Forward \(amount) seconds" : "Back \(amount) seconds",
                  systemImage: isForward ? "goforward.\(amount)" : "gobackward.\(amount)")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(scrubState.durationMs <= 0)
        .accessibilityLabel(isForward ? "Skip forward \(amount) seconds" : "Skip back \(amount) seconds")
    }

    @ViewBuilder private var cinemaButton: some View {
        // Shipping Cinema uses the custom-player ImmersiveSpace. The separate RealityKit theater
        // prototype has its own feature/session boundary and remains gated until device-ready.
        if !CustomCinemaMode.isUserVisible {
            EmptyView()
        } else if cinemaSession.presentationState == .open {
            Button {
                revealChrome(keepVisible: true)
                Task { @MainActor in await toggleCinemaMode() }
            } label: {
                Label("Exit Cinema", systemImage: "rectangle.on.rectangle.slash")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 112)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!cinemaSession.hasActivePlayer || cinemaSession.presentationState == .inTransition)
        } else {
            Button {
                revealChrome(keepVisible: true)
                Task { @MainActor in await toggleCinemaMode() }
            } label: {
                Label("Cinema", systemImage: "theatermasks")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 82)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!cinemaSession.hasActivePlayer || cinemaSession.presentationState == .inTransition)
        }
    }


    @ViewBuilder private var realityTheaterDeveloperButton: some View {
        if allowsRealityTheater
            && (RealityTheaterFeature.isDeviceTestingEntryPointVisible
                || RealityTheaterFeature.isDeveloperEntryPointEnabled()
                || RealityTheaterFeature.isShippingEntryPointVisible) {
            Button {
                revealChrome(keepVisible: true)
                Task { @MainActor in await toggleRealityTheaterMode() }
            } label: {
                Label(realityTheaterSession.phase == .open ? "Exit Cinema" : "Cinema",
                      systemImage: realityTheaterSession.phase == .open
                      ? "rectangle.on.rectangle.slash" : "theatermasks.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: realityTheaterButtonMinWidth)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(realityTheaterSession.phase == .opening)
            .help("RealityKit cinema prototype for #12 headset testing")
        }
    }


    private var realityTheaterButtonMinWidth: CGFloat {
        realityTheaterSession.phase == .open ? 112 : CustomPlayerMenuKind.quality.minChromeWidth
    }

    private var menuStrip: some View {
        HStack(spacing: 8) {
            ForEach(availableMenus) { menu in
                Button {
                    openMenu(menu)
                } label: {
                    Label(menu.shortTitle, systemImage: menu.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: menu.minChromeWidth)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var availableMenus: [CustomPlayerMenuKind] {
        CustomPlayerMenuKind.allCases.filter { menu in
            switch menu {
            case .quality:
                return controller.supportsQualityReload
            case .subtitles, .audio, .chapters, .speed, .stats:
                return true
            }
        }
    }

    private func upNextCard(_ next: MediaItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Up Next")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(next.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("Playing in \(controller.upNext.countdown)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                revealChrome()
                controller.cancelUpNext()
            }
            .buttonStyle(.bordered)
            Button("Play Now") {
                revealChrome()
                controller.playNextNow()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var scrubberBinding: Binding<Double> {
        Binding {
            guard scrubState.durationMs > 0 else { return 0 }
            return Double(scrubState.displayedPositionMs) / Double(scrubState.durationMs)
        } set: { fraction in
            revealChrome(keepVisible: true)
            if !scrubState.isDragging {
                scrubState.beginDrag(livePositionMs: controller.currentResumeMs)
            }
            scrubState.updateDrag(fraction: fraction)
            updateTrickPlayPreview()
        }
    }

    private func handleScrubEditingChanged(_ editing: Bool) {
        if editing {
            revealChrome(keepVisible: true)
            scrubState.beginDrag(livePositionMs: controller.currentResumeMs)
            updateTrickPlayPreview()
        } else if let target = scrubState.commit() {
            controller.performUserSeek(toMs: target)
            clearTrickPlayPreview()
            revealChrome()
        } else {
            clearTrickPlayPreview()
            revealChrome()
        }
    }

    private func updateTrickPlayPreview() {
        guard let provider = trickPlayProvider,
              scrubState.isDragging,
              let targetMs = scrubState.draftPositionMs else {
            clearTrickPlayPreview()
            return
        }

        if let cached = trickPlayImageCache.nearestImage(to: targetMs, toleranceMs: 15_000) {
            trickPlayPreviewTask?.cancel()
            trickPlayPreviewImage = cached.image
            trickPlayPreviewTimeMs = cached.timeMs
            trickPlayPreviewLoading = false
            return
        }

        trickPlayPreviewLoading = true
        trickPlayPreviewTimeMs = targetMs
        trickPlayPreviewTask?.cancel()
        trickPlayPreviewTask = Task {
            let thumbnail = await provider.thumbnail(nearMs: targetMs)
            guard !Task.isCancelled else { return }
            let decoded = thumbnail.flatMap { UIImage(data: $0.imageData) }
            await MainActor.run {
                guard scrubState.isDragging, scrubState.draftPositionMs == targetMs else { return }
                trickPlayPreviewLoading = false
                guard let thumbnail, let decoded else { return }
                trickPlayImageCache.insert(decoded, for: thumbnail.timeMs)
                trickPlayPreviewImage = decoded
                trickPlayPreviewTimeMs = thumbnail.timeMs
            }
        }
    }

    private func clearTrickPlayPreview() {
        trickPlayPreviewTask?.cancel()
        trickPlayPreviewLoading = false
        trickPlayPreviewImage = nil
        trickPlayPreviewTimeMs = nil
    }

    private func performRelativeSkip(seconds: Int) {
        revealChrome(keepVisible: true)
        let target = controller.performRelativeUserSeek(bySeconds: seconds,
                                                        from: scrubState.displayedPositionMs,
                                                        durationMs: scrubState.durationMs)
        _ = scrubState.commit(toMs: target)
        revealChrome()
    }

    private func toggleCinemaMode() async {
        switch cinemaSession.presentationState {
        case .closed:
            cinemaSession.presentationState = .inTransition
            switch await openImmersiveSpace(id: CustomCinemaMode.immersiveSpaceID) {
            case .opened:
                // Detach the normal player window after the immersive surface is open so its
                // translucent pane does not sit in front of Cinema. The immersive Exit path
                // stops/clears playback before reopening the app, so there is nothing to preserve.
                onClose?()
                dismissWindow(id: CustomCinemaMode.mainWindowID)
            case .userCancelled, .error:
                fallthrough
            @unknown default:
                cinemaSession.presentationState = .closed
            }
        case .open:
            cinemaSession.prepareExit(returningTo: cinemaSession.item, autoPlay: false)
            // Just dismiss; the cinema scaffold's onDisappear owns the exit (stop the session, route
            // to the content detail page, reopen the window). It fires for every dismissal — this
            // button, a single Crown press, or a system collapse — so the exit path lives in one place.
            await dismissImmersiveSpace()
        case .inTransition:
            break
        }
    }


    private func toggleRealityTheaterMode() async {
        switch realityTheaterSession.phase {
        case .inactive, .prepared:
            realityTheaterSession.prepare(title: title,
                                          controller: controller,
                                          configuration: realityTheaterSession.configuration)
            realityTheaterSession.markOpening()
            switch await openImmersiveSpace(id: RealityTheaterFeature.immersiveSpaceID) {
            case .opened:
                break
            case .userCancelled, .error:
                fallthrough
            @unknown default:
                realityTheaterSession.markClosed()
            }
        case .open:
            realityTheaterSession.markOpening()
            await dismissImmersiveSpace()
        case .opening:
            break
        }
    }

    /// Chapters is a horizontal filmstrip; unlike the small fixed menus it should fill most of the
    /// player width and stay centered. A fixed 1120-pt width looked right in the windowed player but
    /// narrow and right-shifted on the much wider Cinema canvas, so size it to the available width
    /// (capped) to keep the same proportion in both. Returns nil for menus that keep a fixed size.
    private func adaptiveMenuWidth(for menu: CustomPlayerMenuKind, available: CGFloat) -> CGFloat? {
        guard menu == .chapters, available > 0 else { return nil }
        // Footprint outside the content: the popover's internal +44 frame and 54-pt padding each side.
        let chrome: CGFloat = 44 + 54 * 2
        return min(1680, max(720, available - chrome))
    }

    private func openMenu(_ menu: CustomPlayerMenuKind) {
        revealChrome(keepVisible: true)
        selectedMenu = menu
    }

    private func closeMenu() {
        selectedMenu = nil
        revealChrome()
    }

    private func revealChrome(keepVisible: Bool = false) {
        chromeVisible = true
        hideTask?.cancel()
        if !keepVisible {
            scheduleChromeHideIfNeeded()
        }
    }

    private func scheduleChromeHideIfNeeded() {
        hideTask?.cancel()
        guard !controller.transport.showsPausedControl,
              !controller.transportStatus.keepsChromeVisible,
              selectedMenu == nil else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  !controller.transport.showsPausedControl,
                  !controller.transportStatus.keepsChromeVisible,
                  selectedMenu == nil else { return }
            chromeVisible = false
        }
    }

    private func format(ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private enum CustomPlayerMenuKind: String, CaseIterable, Identifiable {
    case quality
    case subtitles
    case audio
    case chapters
    case speed
    case stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quality: "Quality"
        case .subtitles: "Subtitles"
        case .audio: "Audio"
        case .chapters: "Chapters"
        case .speed: "Speed"
        case .stats: "Stats"
        }
    }

    var shortTitle: String {
        switch self {
        case .quality: "Quality"
        case .subtitles: "Subs"
        case .audio: "Audio"
        case .chapters: "Chapters"
        case .speed: "Speed"
        case .stats: "Stats"
        }
    }

    var systemImage: String {
        switch self {
        case .quality: "slider.horizontal.3"
        case .subtitles: "captions.bubble"
        case .audio: "waveform"
        case .chapters: "list.bullet"
        case .speed: "speedometer"
        case .stats: "chart.bar.doc.horizontal"
        }
    }

    var minChromeWidth: CGFloat {
        switch self {
        case .quality, .subtitles, .audio, .speed, .stats: 72
        case .chapters: 94
        }
    }

    var popoverSize: CGSize {
        switch self {
        case .quality: CGSize(width: 340, height: 315)
        case .speed: CGSize(width: 300, height: 245)
        case .subtitles, .audio: CGSize(width: 390, height: 275)
        case .chapters: CGSize(width: 1_120, height: 228)
        case .stats: CGSize(width: 470, height: 330)
        }
    }

    var popoverAlignment: Alignment {
        switch self {
        case .quality, .subtitles, .audio, .chapters: .center
        case .speed, .stats: .trailing
        }
    }
}

private struct CustomPlayerMenuPopover: View {
    let menu: CustomPlayerMenuKind
    let controller: PlaybackController
    @Bindable var menuState: PlayerMenuState
    /// When set (Chapters), overrides the menu's fixed authored width so a horizontal filmstrip can
    /// fill the available player width instead of sitting narrow on the wider Cinema canvas.
    var widthOverride: CGFloat? = nil
    let onClose: () -> Void

    var body: some View {
        let base = menu.popoverSize
        let size = CGSize(width: widthOverride ?? base.width, height: base.height)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Label(menu.title, systemImage: menu.systemImage)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Label("Close menu", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
            }
            .frame(width: size.width)

            Divider()
                .opacity(0.35)
                .frame(width: size.width)

            menuContent
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .padding(22)
        .frame(width: size.width + 44, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(radius: 24)
    }

    @ViewBuilder private var menuContent: some View {
        switch menu {
        case .quality:
            QualityTabView(state: menuState) { kbps in
                controller.reload(bitrateKbps: kbps)
                menuState.selectedBitrateKbps = kbps
                PlaybackPreferences.setQualityKbps(kbps, forDefaultsKey: controller.qualityPreferenceDefaultsKey)
                onClose()
            }
        case .subtitles:
            SubtitlesTabView(
                load: { await controller.loadSubtitleTracks() },
                onSelect: { track in await controller.selectSubtitle(track) }
            )
        case .audio:
            if controller.supportsMetadataAudioSelection {
                AudioStreamsTabView(
                    load: { controller.loadAudioStreamChoices() },
                    onSelect: { choice in await controller.selectAudioStream(choice) }
                )
            } else {
                AudioTabView(
                    load: { await controller.loadAudioTracks() },
                    onSelect: { track in await controller.selectAudio(track) }
                )
            }
        case .chapters:
            ChaptersTabView(
                chapters: controller.chapters,
                currentMs: { controller.currentResumeMs },
                thumbnailURL: { controller.chapterThumbnailURL(for: $0) },
                onJump: { startMs in
                    controller.performUserSeek(toMs: startMs)
                    onClose()
                }
            )
        case .speed:
            SpeedTabView(state: controller.speedState) { rate in
                controller.setPlaybackSpeed(rate)
                onClose()
            }
        case .stats:
            StatsTabView(diagnostics: controller.diagnostics)
        }
    }
}

struct CustomTransportStatusOverlay: View {
    let status: PlaybackTransportStatus
    let onRetry: () -> Void
    let onClose: (() -> Void)?
    let onTogglePause: () -> Void

    private var title: String {
        switch status {
        case .none: ""
        case .buffering: "Buffering…"
        case .pausedBuffering: "Paused — buffering…"
        case .reconnecting: "Reconnecting…"
        case .failed: "Playback failed"
        }
    }

    private var detail: String? {
        switch status {
        case .none:
            nil
        case .buffering:
            "You can pause now and let the stream build buffer before playing."
        case .pausedBuffering:
            "Playback will stay paused once the stream is ready."
        case .reconnecting:
            nil
        case .failed(let message):
            message?.isEmpty == false ? message : nil
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            switch status {
            case .failed:
                Label(title, systemImage: "exclamationmark.triangle")
                    .font(.headline)
            default:
                ProgressView(title)
                    .controlSize(.large)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            switch status {
            case .buffering, .pausedBuffering:
                Button {
                    onTogglePause()
                } label: {
                    Label(isPausedBuffering ? "Play when ready" : "Pause while loading",
                          systemImage: isPausedBuffering ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .reconnecting:
                if let onClose {
                    Button(role: .cancel, action: onClose) {
                        Text("Close")
                            .frame(width: 150)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            case .failed:
                VStack(spacing: 8) {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    if let onClose {
                        Button(action: onClose) {
                            Text("Close")
                                .frame(minWidth: 160)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 2)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 18)
    }

    private var isPausedBuffering: Bool {
        if case .pausedBuffering = status { return true }
        return false
    }
}
