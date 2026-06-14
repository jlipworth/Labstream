import AVFoundation
import PMSKit
import SwiftUI
import UIKit

/// Experimental fallback video player with app-owned chrome and scrubber.
///
/// This intentionally does NOT replace the default AVPlayerViewController path. It is routed
/// only by the default-off Settings toggle so we can test whether deterministic scrubber intent
/// and an AVPlayerLayer presenter avoid native AVKit control/chrome seek weirdness.
struct CustomPlayerView: View {
    private let item: MediaItem
    private let server: URL
    private let token: String
    private let identity: ClientIdentity
    private let client: PlexClient
    private let maxVideoBitrateKbps: Int
    private let mediaIndex: Int
    private let machineIdentifier: String?
    private let onClose: (() -> Void)?
    private let onRequestPlay: ((MediaItem) -> Void)?

    @State private var controller: PlaybackController?
    @State private var scrubState: PlaybackScrubState
    @State private var clockTaskID = UUID()
    @State private var isReconnecting = false

    init(item: MediaItem,
         server: URL,
         token: String,
         identity: ClientIdentity,
         client: PlexClient,
         maxVideoBitrateKbps: Int = 8000,
         mediaIndex: Int = 0,
         machineIdentifier: String? = nil,
         onClose: (() -> Void)? = nil,
         onRequestPlay: ((MediaItem) -> Void)? = nil) {
        self.item = item
        self.server = server
        self.token = token
        self.identity = identity
        self.client = client
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.mediaIndex = mediaIndex
        self.machineIdentifier = machineIdentifier
        self.onClose = onClose
        self.onRequestPlay = onRequestPlay
        _scrubState = State(initialValue: PlaybackScrubState(durationMs: item.duration ?? 0,
                                                            livePositionMs: item.viewOffset ?? 0))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(player: controller?.player)
                .ignoresSafeArea()

            if let controller {
                CustomPlayerChrome(controller: controller,
                                   title: item.title,
                                   scrubState: $scrubState,
                                   isReconnecting: isReconnecting,
                                   onRetry: { retry(controller) },
                                   onClose: onClose)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .task(id: clockTaskID) { await runPlayer() }
        .task(id: isReconnecting) { await reconnectWatchdog() }
        .onDisappear { controller?.stop() }
    }

    @MainActor
    private func makeController() -> PlaybackController {
        let playback = PlaybackController(item: item,
                                          server: server,
                                          token: token,
                                          identity: identity,
                                          client: client,
                                          maxVideoBitrateKbps: maxVideoBitrateKbps,
                                          mediaIndex: mediaIndex,
                                          machineIdentifier: machineIdentifier)
        playback.onAdvanceToNext = onRequestPlay
        playback.onPlaybackActive = { isReconnecting = false }
        return playback
    }

    private func runPlayer() async {
        await MainActor.run {
            let playback = makeController()
            controller = playback
            refreshScrubberClock(from: playback)
            playback.start()
            Task { @MainActor in
                _ = await playback.loadChaptersIfNeeded()
            }
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                if let controller {
                    refreshScrubberClock(from: controller)
                }
            }
        }
    }

    @MainActor
    private func refreshScrubberClock(from controller: PlaybackController) {
        let duration = controller.player.currentItem?.duration
        let itemDurationMs = item.duration ?? 0
        let durationMs: Int
        if let duration, duration.seconds.isFinite, duration.seconds > 0 {
            durationMs = Int((duration.seconds * 1000).rounded())
        } else {
            durationMs = itemDurationMs
        }

        scrubState.updateDuration(durationMs)
        if !scrubState.isDragging {
            scrubState.updateLivePosition(controller.currentResumeMs)
        }
    }

    @MainActor
    private func retry(_ controller: PlaybackController) {
        isReconnecting = true
        controller.retry()
    }

    private func reconnectWatchdog() async {
        guard isReconnecting else { return }
        try? await Task.sleep(for: .seconds(20))
        await MainActor.run {
            guard isReconnecting, let controller else { return }
            isReconnecting = false
            controller.surfaceReconnectTimeout()
        }
    }
}

/// Minimal UIKit bridge whose backing layer is AVPlayerLayer.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerHostView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerLayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

/// App-owned fullscreen chrome for the experimental player.
///
/// This deliberately mirrors the AVKit info-panel feature set: the custom route must not be a
/// feature regression just because it owns its transport. The chrome behaves like player chrome,
/// not permanent app UI: taps reveal it, playback auto-hides it, and modal menu/error/reconnect
/// states keep it visible while the viewer is acting on them.
private struct CustomPlayerChrome: View {
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
                .onTapGesture { revealChrome() }

            if shouldShowChrome {
                topChrome
                    .transition(.opacity)
            }

            VStack {
                Spacer()

                if controller.playbackError.isFailed {
                    failureCard
                        .padding(.bottom, 18)
                } else if isReconnecting {
                    CustomReconnectingOverlay(onClose: onClose)
                        .padding(.bottom, 18)
                } else if controller.buffering.isBuffering {
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

            if selectedMenu != nil {
                CustomPlayerMenuPanel(selection: Binding(
                    get: { self.selectedMenu ?? .quality },
                    set: { self.selectedMenu = $0 }
                ),
                controller: controller,
                menuState: menuState,
                onClose: { closeMenu() })
                .padding(40)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
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

    private var menuStrip: some View {
        HStack(spacing: 8) {
            ForEach(CustomPlayerMenuKind.allCases) { menu in
                Button {
                    openMenu(menu)
                } label: {
                    Label(menu.shortTitle, systemImage: menu.systemImage)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
            HStack {
                Button(action: {
                    revealChrome()
                    onRetry()
                }) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                if let onClose {
                    Button("Close", action: onClose)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(22)
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

    private func togglePlayback() {
        if controller.transport.isPaused {
            controller.player.play()
        } else {
            controller.player.pause()
        }
        scheduleChromeHideIfNeeded()
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
}

private struct CustomPlayerMenuPanel: View {
    @Binding var selection: CustomPlayerMenuKind
    let controller: PlaybackController
    @Bindable var menuState: PlayerMenuState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Label("Player options", systemImage: "info.circle")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Label("Close menu", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.bordered)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(CustomPlayerMenuKind.allCases) { item in
                        if selection == item {
                            menuButton(item)
                                .buttonStyle(.borderedProminent)
                        } else {
                            menuButton(item)
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .frame(width: 170)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Label(selection.title, systemImage: selection.systemImage)
                        .font(.title3.weight(.semibold))
                    menuContent
                        .frame(minWidth: 560, maxWidth: 760, minHeight: 320, maxHeight: 420)
                }
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(radius: 30)
    }

    private func menuButton(_ item: CustomPlayerMenuKind) -> some View {
        Button {
            selection = item
        } label: {
            Label(item.title, systemImage: item.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var menuContent: some View {
        switch selection {
        case .quality:
            QualityTabView(state: menuState) { kbps in
                controller.reload(bitrateKbps: kbps)
                menuState.selectedBitrateKbps = kbps
                UserDefaults.standard.set(kbps, forKey: "maxVideoBitrateKbps")
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
            }
        case .stats:
            StatsTabView(diagnostics: controller.diagnostics)
        }
    }
}

private struct CustomReconnectingOverlay: View {
    let onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            ProgressView()
                .controlSize(.large)
            Text("Reconnecting…")
                .font(.headline)
            if let onClose {
                Button(role: .cancel, action: onClose) {
                    Text("Close").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DS.Space.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}
