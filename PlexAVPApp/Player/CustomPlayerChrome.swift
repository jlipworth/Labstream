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
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    let controller: PlaybackController
    let title: String
    @Binding var scrubState: PlaybackScrubState
    let isReconnecting: Bool
    let onRetry: () -> Void
    let onClose: (() -> Void)?

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var selectedMenu: CustomPlayerMenuKind?
    @State private var menuState: PlayerMenuState

    init(controller: PlaybackController,
         title: String,
         scrubState: Binding<PlaybackScrubState>,
         isReconnecting: Bool,
         onRetry: @escaping () -> Void,
         onClose: (() -> Void)?) {
        self.controller = controller
        self.title = title
        _scrubState = scrubState
        self.isReconnecting = isReconnecting
        self.onRetry = onRetry
        self.onClose = onClose
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
        .onDisappear { hideTask?.cancel() }
        .onChange(of: controller.transport.isPaused) { _, _ in scheduleChromeHideIfNeeded() }
        .onChange(of: controller.playbackError.isFailed) { _, _ in scheduleChromeHideIfNeeded() }
        .onChange(of: isReconnecting) { _, _ in scheduleChromeHideIfNeeded() }
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
                Spacer()
                cinemaButton
                menuStrip
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
        if cinemaSession.presentationState == .open {
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

    private var menuStrip: some View {
        HStack(spacing: 8) {
            ForEach(CustomPlayerMenuKind.allCases) { menu in
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
        }
    }

    private func handleScrubEditingChanged(_ editing: Bool) {
        if editing {
            revealChrome(keepVisible: true)
            scrubState.beginDrag(livePositionMs: controller.currentResumeMs)
        } else if let target = scrubState.commit() {
            controller.performUserSeek(toMs: target)
            revealChrome()
        } else {
            revealChrome()
        }
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
            if controller.isStreaming {
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
