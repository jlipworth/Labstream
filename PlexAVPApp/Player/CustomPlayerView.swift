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
                                   onRetry: { controller.retry() },
                                   onClose: onClose)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .task(id: clockTaskID) { await runPlayer() }
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
        return playback
    }

    private func runPlayer() async {
        await MainActor.run {
            let playback = makeController()
            controller = playback
            refreshScrubberClock(from: playback)
            playback.start()
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

/// Native-ish windowed controls for the fallback player. This is intentionally small: prove
/// the app-owned primary scrubber first, then add menu parity after the path earns it.
private struct CustomPlayerChrome: View {
    let controller: PlaybackController
    let title: String
    @Binding var scrubState: PlaybackScrubState
    let onRetry: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let onClose {
                Button(action: onClose) {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.borderedProminent)
                .padding(28)
            }

            VStack {
                Spacer()

                if controller.playbackError.isFailed {
                    failureCard
                        .padding(.bottom, 18)
                } else if controller.buffering.isBuffering {
                    ProgressView("Buffering…")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 18)
                }

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
                }

                if controller.upNext.isShown, let next = controller.upNext.nextItem {
                    upNextCard(next)
                        .padding(.horizontal, 34)
                        .padding(.bottom, 14)
                }

                controls
                    .padding(.horizontal, 34)
                    .padding(.bottom, 28)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 16) {
                Button(action: togglePlayback) {
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
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
                Button(action: onRetry) {
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
            Button("Cancel") { controller.cancelUpNext() }
                .buttonStyle(.bordered)
            Button("Play Now") { controller.playNextNow() }
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
            if !scrubState.isDragging {
                scrubState.beginDrag(livePositionMs: controller.currentResumeMs)
            }
            scrubState.updateDrag(fraction: fraction)
        }
    }

    private func handleScrubEditingChanged(_ editing: Bool) {
        if editing {
            scrubState.beginDrag(livePositionMs: controller.currentResumeMs)
        } else if let target = scrubState.commit() {
            controller.performUserSeek(toMs: target)
        }
    }

    private func togglePlayback() {
        if controller.transport.isPaused {
            controller.player.play()
        } else {
            controller.player.pause()
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
