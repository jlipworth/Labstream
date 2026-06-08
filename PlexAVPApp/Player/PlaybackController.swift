import Foundation
import AVKit
import PlexKit

/// Owns the `AVPlayer` for one playback session and drives Plex playback state.
///
/// Two entry points, ONE playback path:
///   • streaming: `start()` runs the transcode decision (`decisionURL()`), then
///     loads `startM3U8URL()` into the player and seeks to `viewOffset`.
///   • local file: `startLocalFile(_:)` loads a downloaded asset directly.
///
/// While playing it fires `TimelineRequest.timeline(...)` roughly every 10s and on
/// every play/pause/stop transition, and sends `TimelineRequest.scrobble(...)` when
/// the item plays to completion.
///
/// This controller deliberately holds a strong ref to `PlexClient` only (not
/// `AppModel`) so it can be created and torn down per-presentation without cycles.
@MainActor
final class PlaybackController {

    /// The player the `AVPlayerViewController` is bound to.
    let player = AVPlayer()

    // Inputs.
    private let item: MediaItem
    private let client: PlexClient
    private let identity: ClientIdentity

    /// Streaming context. `nil` for local-file playback (no timeline reporting then,
    /// since there is no server session/token to report against).
    private let server: URL?
    private let token: String?

    /// The local file URL, when playing offline content.
    private let localFile: URL?

    /// Hard bitrate cap requested of PMS (kbps). 8 Mbps default per spec.
    private let maxVideoBitrateKbps: Int

    /// Per-playback transcode session id (also reused as the timeline session).
    private let sessionID = "plex-avp-" + UUID().uuidString

    // State.
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var didEndObserver: NSObjectProtocol?
    private var lastTimelineState: TimelineRequest.State?
    private var lastReportedSecond: Int = -1
    private var didScrobble = false
    private var started = false

    /// How often (seconds) the periodic time observer fires.
    private let timelineIntervalSeconds: Double = 10

    // MARK: - Init

    /// Streaming initializer.
    init(item: MediaItem,
         server: URL,
         token: String,
         identity: ClientIdentity,
         client: PlexClient,
         maxVideoBitrateKbps: Int = 8000) {
        self.item = item
        self.server = server
        self.token = token
        self.identity = identity
        self.client = client
        self.localFile = nil
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
    }

    /// Local-file initializer (offline playback of a downloaded title).
    init(localFile: URL,
         item: MediaItem,
         identity: ClientIdentity,
         client: PlexClient,
         maxVideoBitrateKbps: Int = 8000) {
        self.item = item
        self.localFile = localFile
        self.identity = identity
        self.client = client
        self.server = nil
        self.token = nil
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
    }

    // MARK: - Lifecycle

    /// Begin playback. Safe to call once; subsequent calls are ignored.
    func start() {
        guard !started else { return }
        started = true
        if let localFile {
            loadLocalFile(localFile)
        } else {
            Task { await self.startStreaming() }
        }
    }

    /// Tear down observers and report a final `stopped` timeline. Call from the
    /// view's `dismantle`.
    func stop() {
        reportTimeline(state: .stopped, force: true)
        player.pause()
        removeObservers()
    }

    // MARK: - Streaming path

    private func startStreaming() async {
        guard let server, let token else { return }
        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"

        let transcode = TranscodeRequest(server: server,
                                         token: token,
                                         identity: identity,
                                         metadataKey: metadataKey,
                                         maxVideoBitrateKbps: maxVideoBitrateKbps,
                                         sessionID: sessionID,
                                         mediaIndex: 0,
                                         partIndex: 0)

        // Ask PMS for a transcode decision. We proceed for both directPlay and
        // transcode; only a hard `.unsupported` aborts. A failed decision call is
        // non-fatal — fall through and try start.m3u8 anyway.
        do {
            let decisionReq = PlexRequest(url: transcode.decisionURL(), method: "GET")
            let response = try await client.send(decisionReq, as: DecisionResponse.self)
            if case .unsupported = response.decision {
                // Best-effort: still attempt playback; PMS often plays despite an
                // odd decision code. Logged for the integration pass.
                NSLog("PlaybackController: transcode decision unsupported: \(String(describing: response.generalDecisionText))")
            }
        } catch {
            NSLog("PlaybackController: decision call failed (\(error)); attempting start.m3u8 anyway")
        }

        let streamURL = transcode.startM3U8URL()
        let asset = AVURLAsset(url: streamURL)
        let playerItem = AVPlayerItem(asset: asset)
        load(playerItem, resumeOffsetMs: item.viewOffset)
    }

    // MARK: - Local-file path

    private func loadLocalFile(_ url: URL) {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        // Offline content resumes from the same `viewOffset` if present.
        load(playerItem, resumeOffsetMs: item.viewOffset)
    }

    // MARK: - Shared load + observers

    private func load(_ playerItem: AVPlayerItem, resumeOffsetMs: Int?) {
        player.replaceCurrentItem(with: playerItem)
        installObservers(for: playerItem, resumeOffsetMs: resumeOffsetMs)
        player.play()
    }

    private func installObservers(for playerItem: AVPlayerItem, resumeOffsetMs: Int?) {
        // Seek to the saved offset once the item is ready.
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] pItem, _ in
            guard let self else { return }
            Task { @MainActor in
                guard pItem.status == .readyToPlay else { return }
                if let resumeOffsetMs, resumeOffsetMs > 0 {
                    let target = CMTime(value: CMTimeValue(resumeOffsetMs), timescale: 1000)
                    self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                self.statusObservation = nil
            }
        }

        // Periodic heartbeat ~ every 10s.
        let interval = CMTime(seconds: timelineIntervalSeconds, preferredTimescale: 1)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self else { return }
            let state: TimelineRequest.State = self.player.timeControlStatus == .paused ? .paused : .playing
            self.reportTimeline(state: state, force: false)
        }

        // Fire on play/pause transitions.
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            guard let self else { return }
            Task { @MainActor in
                let state: TimelineRequest.State = avPlayer.timeControlStatus == .paused ? .paused : .playing
                self.reportTimeline(state: state, force: true)
            }
        }

        // Scrobble on completion.
        didEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reportTimeline(state: .stopped, force: true)
                self.sendScrobble()
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation = nil
        rateObservation = nil
        if let didEndObserver {
            NotificationCenter.default.removeObserver(didEndObserver)
            self.didEndObserver = nil
        }
    }

    // MARK: - Timeline / scrobble

    /// Send a timeline heartbeat. Skips when nothing meaningful changed (same state
    /// within the same ~10s second bucket) unless `force` is set.
    private func reportTimeline(state: TimelineRequest.State, force: Bool) {
        // Local-file playback has no server session to report to.
        guard let server, let token else { return }

        let currentMs = Int(player.currentTime().seconds.isFinite ? player.currentTime().seconds * 1000 : 0)
        let currentSecond = currentMs / 1000

        if !force,
           state == lastTimelineState,
           currentSecond == lastReportedSecond {
            return
        }
        lastTimelineState = state
        lastReportedSecond = currentSecond

        let durationMs = item.duration
            ?? Int((player.currentItem?.duration.seconds ?? 0).isFinite ? (player.currentItem?.duration.seconds ?? 0) * 1000 : 0)
        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"

        let req = TimelineRequest.timeline(server: server,
                                           token: token,
                                           identity: identity,
                                           ratingKey: item.ratingKey,
                                           key: metadataKey,
                                           state: state,
                                           timeMs: currentMs,
                                           durationMs: durationMs)
        Task { try? await client.send(req) }
    }

    private func sendScrobble() {
        guard !didScrobble, let server, let token else { return }
        didScrobble = true
        let req = TimelineRequest.scrobble(server: server,
                                           token: token,
                                           identity: identity,
                                           ratingKey: item.ratingKey)
        Task { try? await client.send(req) }
    }
}
