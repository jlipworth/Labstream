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

/// App-owned fullscreen chrome for the experimental player.
///
/// This deliberately mirrors the AVKit info-panel feature set: the custom route must not be a
/// feature regression just because it owns its transport. The chrome behaves like player chrome,
/// not permanent app UI: taps reveal it, playback auto-hides it, and modal menu/error/reconnect
/// states keep it visible while the viewer is acting on them.
struct CustomPlayerChrome: View {
    @Environment(CustomCinemaSessionStore.self) private var cinemaSession
    @Environment(RealityTheaterSessionStore.self) private var realityTheaterSession
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    let controller: PlaybackController
    let title: String
    @Binding var scrubState: PlaybackScrubState
    let trickPlayProvider: (any TrickPlayThumbnailProviding)?
    let isReconnecting: Bool
    let onRetry: () -> Void
    let onClose: (() -> Void)?
    let allowsRealityTheater: Bool

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var selectedMenu: CustomPlayerMenuKind?
    @State private var menuState: PlayerMenuState
    @State private var bandwidthToast: BandwidthMismatchToastModel?
    @State private var bandwidthToastTask: Task<Void, Never>?
    @State private var lastBandwidthToastDate: Date?
    @State private var trickPlayPreviewTask: Task<Void, Never>?
    @State private var trickPlayPreviewImage: UIImage?
    @State private var trickPlayPreviewTimeMs: Int?
    @State private var trickPlayPreviewLoading = false
    @State private var trickPlayImageCache = TrickPlayPreviewImageCache(limit: 32)

    init(controller: PlaybackController,
         title: String,
         scrubState: Binding<PlaybackScrubState>,
         trickPlayProvider: (any TrickPlayThumbnailProviding)? = nil,
         isReconnecting: Bool,
         onRetry: @escaping () -> Void,
         onClose: (() -> Void)?,
         allowsRealityTheater: Bool = false) {
        self.controller = controller
        self.title = title
        _scrubState = scrubState
        self.trickPlayProvider = trickPlayProvider
        self.isReconnecting = isReconnecting
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

            if isReconnecting, controller.playbackError.isFailed != true {
                CustomReconnectingOverlay(onClose: onClose)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(40)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }

            VStack {
                Spacer()

                if let bandwidthToast {
                    BandwidthMismatchToast(message: bandwidthToast.message)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if controller.playbackError.isFailed {
                    failureCard
                        .padding(.bottom, 18)
                } else if controller.buffering.isBuffering, !isReconnecting {
                    // One status at a time: the reconnecting overlay already owns the screen
                    // while a reconnect is in flight, so don't stack a buffering card under it.
                    bufferingCard
                        .padding(.bottom, 18)
                }

                if let marker = controller.skipMarker.active, shouldShowChrome {
                    HStack {
                        Spacer()
                        Button {
                            revealChrome()
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
                VStack {
                    Spacer()
                    CustomPlayerMenuPopover(menu: selectedMenu,
                                            controller: controller,
                                            menuState: menuState,
                                            onClose: { closeMenu() })
                        .frame(maxWidth: .infinity, alignment: selectedMenu.popoverAlignment)
                        .padding(.horizontal, 54)
                        .padding(.bottom, 176)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: shouldShowChrome)
        .animation(.easeInOut(duration: 0.18), value: selectedMenu)
        .onAppear { revealChrome() }
        .onDisappear {
            hideTask?.cancel()
            bandwidthToastTask?.cancel()
            trickPlayPreviewTask?.cancel()
        }
        .onChange(of: controller.transport.isPaused) { _, _ in scheduleChromeHideIfNeeded() }
        .onChange(of: controller.playbackError.isFailed) { _, _ in
            scheduleChromeHideIfNeeded()
            considerBandwidthToast()
        }
        .onChange(of: controller.buffering.isBuffering) { _, _ in considerBandwidthToast() }
        .onChange(of: controller.diagnostics.observedBitrateKbps) { _, _ in considerBandwidthToast() }
        .onChange(of: controller.diagnostics.requiredBitrateKbps) { _, _ in considerBandwidthToast() }
        .onChange(of: isReconnecting) { _, _ in
            scheduleChromeHideIfNeeded()
            considerBandwidthToast()
        }
    }

    private var shouldShowChrome: Bool {
        chromeVisible || controller.transport.isPaused || controller.playbackError.isFailed || isReconnecting || selectedMenu != nil
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
            HStack(alignment: .center, spacing: 14) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Long episode/movie titles should never compress the menu pills.
                    // Cap the title region and give the action cluster layout priority
                    // so buttons keep stable tap targets on narrower player widths.
                    .frame(maxWidth: 420, alignment: .leading)
                    .accessibilityLabel(title)

                Spacer(minLength: 12)

                cinemaButton
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)

                realityTheaterDeveloperButton
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)

                menuStrip
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
            }

            if scrubState.isDragging, trickPlayProvider != nil {
                trickPlayPreview
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 16) {
                Button(action: {
                    revealChrome()
                    togglePlayback()
                }) {
                    Image(systemName: controller.transport.isPaused ? "play.fill" : "pause.fill")
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
        // This is only the hidden Wave-2/Wave-3 AVPlayerLayer-in-ImmersiveSpace scaffold.
        // Issue #12's RealityKit theater has a separate feature/session boundary and must not
        // become visible here until device-ready behavior is proven.
        if !CustomCinemaMode.isUserVisible {
            EmptyView()
        } else if cinemaSession.presentationState == .open {
            Button {
                revealChrome(keepVisible: true)
                Task { @MainActor in await toggleCinemaMode() }
            } label: {
                Label("Exit Cinema", systemImage: "rectangle.on.rectangle.slash")
                    .labelStyle(.titleAndIcon)
                    .font(.headline.weight(.semibold))
                    .frame(minWidth: 128)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!cinemaSession.hasActivePlayer || cinemaSession.presentationState == .inTransition)
        } else {
            Button {
                revealChrome(keepVisible: true)
                Task { @MainActor in await toggleCinemaMode() }
            } label: {
                Label("Cinema", systemImage: "theatermasks")
                    .labelStyle(.titleAndIcon)
                    .font(.headline.weight(.semibold))
                    .frame(minWidth: 94)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
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
                    .font(.headline.weight(.semibold))
                    .frame(minWidth: 128)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(realityTheaterSession.phase == .opening)
            .help("RealityKit cinema prototype for #12 headset testing")
        }
    }

    private var menuStrip: some View {
        HStack(spacing: 8) {
            ForEach(availableMenus) { menu in
                Button {
                    openMenu(menu)
                } label: {
                    Label(menu.shortTitle, systemImage: menu.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.headline.weight(.semibold))
                        .frame(minWidth: menu.minChromeWidth)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
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

    private var failureCard: some View {
        VStack(spacing: 12) {
            Label("Playback failed", systemImage: "exclamationmark.triangle")
                .font(.headline)
            if let message = controller.playbackError.message, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                Button(action: {
                    revealChrome()
                    onRetry()
                }) {
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
        }
        .padding(22)
        // Cap the width so a long server message wraps onto multiple centered lines
        // instead of stretching the card across the screen.
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var bufferingCard: some View {
        ProgressView("Buffering…")
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .allowsHitTesting(false)
    }

    private func considerBandwidthToast() {
        guard controller.buffering.isBuffering,
              !controller.playbackError.isFailed,
              !isReconnecting,
              let message = controller.diagnostics.bandwidthMismatchMessage
        else { return }

        let now = Date()
        if let lastBandwidthToastDate, now.timeIntervalSince(lastBandwidthToastDate) < 30 {
            return
        }
        lastBandwidthToastDate = now
        bandwidthToast = .init(message: message)
        bandwidthToastTask?.cancel()
        bandwidthToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            bandwidthToast = nil
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

    private func togglePlayback() {
        if controller.transport.isPaused {
            controller.player.play()
        } else {
            controller.player.pause()
        }
        scheduleChromeHideIfNeeded()
    }

    private func toggleCinemaMode() async {
        switch cinemaSession.presentationState {
        case .closed:
            cinemaSession.presentationState = .inTransition
            switch await openImmersiveSpace(id: CustomCinemaMode.immersiveSpaceID) {
            case .opened:
                break
            case .userCancelled, .error:
                fallthrough
            @unknown default:
                cinemaSession.presentationState = .closed
            }
        case .open:
            cinemaSession.presentationState = .inTransition
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
        guard !controller.transport.isPaused,
              !controller.playbackError.isFailed,
              !isReconnecting,
              selectedMenu == nil else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  !controller.transport.isPaused,
                  !controller.playbackError.isFailed,
                  !isReconnecting,
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

private struct BandwidthMismatchToastModel: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

private struct BandwidthMismatchToast: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.orange.opacity(0.45), lineWidth: 1)
        }
        .shadow(radius: 18)
        .allowsHitTesting(false)
        .accessibilityLabel("Network quality warning")
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
        case .quality, .subtitles, .audio, .speed, .stats: 84
        case .chapters: 112
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
        case .quality, .subtitles, .audio: .center
        case .chapters, .speed, .stats: .trailing
        }
    }
}

private struct CustomPlayerMenuPopover: View {
    let menu: CustomPlayerMenuKind
    let controller: PlaybackController
    @Bindable var menuState: PlayerMenuState
    let onClose: () -> Void

    var body: some View {
        let size = menu.popoverSize
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
                UserDefaults.standard.set(kbps, forKey: "maxVideoBitrateKbps")
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

struct CustomReconnectingOverlay: View {
    let onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Reconnecting…")
                .font(.headline.weight(.semibold))
            if let onClose {
                Button(role: .cancel, action: onClose) {
                    Text("Close")
                        .frame(width: 150)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 18)
    }
}
