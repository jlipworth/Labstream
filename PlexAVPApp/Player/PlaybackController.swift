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

    /// Live diagnostics for the "Stats for Nerds" overlay. Always present; the panel
    /// is hidden until the user toggles it on.
    let diagnostics = PlaybackDiagnostics()

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

    /// Which `Media` entry (version) of the item to transcode. Plex items can ship
    /// multiple files at different resolutions/codecs; the DetailView's version picker
    /// threads the chosen index here so playback uses that specific version. Defaults to
    /// `0` (the first/primary version), which matches the prior hard-coded behavior.
    private let mediaIndex: Int

    /// Hard bitrate cap requested of PMS (kbps). 8 Mbps default per spec.
    ///
    /// Mutable: the in-player quality menu rebuilds the stream at a new cap via
    /// `reload(bitrateKbps:)`. `0` is the sentinel for "Maximum / Original" (no cap).
    private(set) var maxVideoBitrateKbps: Int

    /// Per-playback transcode session id (also reused as the timeline session).
    private let sessionID = "plex-avp-" + UUID().uuidString

    // State.
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var didEndObserver: NSObjectProtocol?
    private var diagnosticsTimer: Timer?
    private var lastTimelineState: TimelineRequest.State?
    private var lastReportedSecond: Int = -1
    private var didScrobble = false
    private var started = false

    /// Whether this session is streaming (vs local file). Drives which menus the
    /// player surface offers (quality reload only makes sense for streaming).
    var isStreaming: Bool { localFile == nil && server != nil && token != nil }

    /// Chapter markers for the current item, if Plex provided any. Empty when none —
    /// the player hides the Chapters info-panel tab in that case.
    ///
    /// NOTE: visionOS's AVKit does NOT expose `AVNavigationMarkersGroup` /
    /// `AVPlayerItem.navigationMarkerGroups` (tvOS/iOS only), so native scrubber chapter
    /// ticks are unavailable here; we surface chapters via the custom Chapters tab and
    /// seek the playhead directly.
    var chapters: [Chapter] { item.chapters ?? [] }

    /// How often (seconds) the periodic time observer fires.
    private let timelineIntervalSeconds: Double = 10

    // MARK: - Init

    /// Streaming initializer.
    init(item: MediaItem,
         server: URL,
         token: String,
         identity: ClientIdentity,
         client: PlexClient,
         maxVideoBitrateKbps: Int = 8000,
         mediaIndex: Int = 0) {
        self.item = item
        self.server = server
        self.token = token
        self.identity = identity
        self.client = client
        self.localFile = nil
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.mediaIndex = mediaIndex
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
        // A local file is already one concrete version on disk; no version selection.
        self.mediaIndex = 0
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

    // MARK: - Subtitles (soft renditions)

    /// A selectable subtitle track surfaced by the HLS legible media-selection group.
    ///
    /// We model the picker over `AVMediaSelectionOption`s rather than Plex metadata
    /// because the transcode requests `subtitles=auto`: PMS muxes the chosen/forced
    /// subtitle streams into the HLS as soft renditions, and AVFoundation exposes them
    /// as a legible `AVMediaSelectionGroup`. Switching between them is instantaneous
    /// (`playerItem.select(_:in:)`) — no transcode reload, unlike burn-in.
    struct SubtitleTrack: Identifiable {
        /// Stable identity for SwiftUI. `nil` option (the "Off" row) uses `-1`.
        let id: Int
        let displayName: String
        /// The underlying option, or `nil` for the "Off" (deselect) row.
        let option: AVMediaSelectionOption?
    }

    /// Load the current item's legible (subtitle/closed-caption) selection group and its
    /// options, plus which one is active. Returns `nil` for the group when the HLS carries
    /// no legible renditions at all (e.g. a source with no subtitles) so the Subtitles tab
    /// can show a graceful empty state.
    ///
    /// Async because `AVAsset.loadMediaSelectionGroup(for:)` is the modern, non-blocking
    /// accessor (the synchronous `mediaSelectionGroup(forMediaCharacteristic:)` is
    /// deprecated on visionOS).
    func loadSubtitleTracks() async -> (tracks: [SubtitleTrack], selectedID: Int)? {
        guard let playerItem = player.currentItem else { return nil }
        let asset = playerItem.asset
        guard let group = try? await asset.loadMediaSelectionGroup(for: .legible),
              !group.options.isEmpty else {
            return nil
        }

        // "Off" is always offered first. It maps to deselecting the group entirely.
        var tracks: [SubtitleTrack] = [SubtitleTrack(id: -1, displayName: "Off", option: nil)]
        for (index, option) in group.options.enumerated() {
            tracks.append(SubtitleTrack(id: index,
                                        displayName: option.displayName,
                                        option: option))
        }

        // Resolve the active selection so the tab can render a checkmark. A `nil`
        // selected option (or a group not currently selected) means "Off" (id -1).
        let current = playerItem.currentMediaSelection.selectedMediaOption(in: group)
        let selectedID = current.flatMap { selected in
            group.options.firstIndex(of: selected)
        } ?? -1

        return (tracks, selectedID)
    }

    /// Apply a subtitle selection chosen in the Subtitles tab. Passing a track whose
    /// `option` is `nil` (the "Off" row) deselects the legible group. This is a soft
    /// switch on the live `AVPlayerItem` — no reload, no playhead snapshot needed.
    func selectSubtitle(_ track: SubtitleTrack) async {
        guard let playerItem = player.currentItem else { return }
        guard let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible) else {
            return
        }
        playerItem.select(track.option, in: group)
    }

    // MARK: - Quality / bitrate reload

    /// Rebuild the transcode stream at a new bitrate cap and resume seamlessly.
    ///
    /// The PMS universal transcoder cannot change its cap mid-session, so we tear the
    /// HLS stream down and start a fresh `start.m3u8` at `bitrateKbps`. To make it feel
    /// continuous we snapshot the current playhead, load the new item, then seek back to
    /// that position before playing. `0` requests "Maximum / Original" (no cap — we pass
    /// a very high ceiling so PMS still produces a compatible HLS rendition).
    ///
    /// Only valid for streaming sessions; a no-op for local files.
    func reload(bitrateKbps: Int) {
        guard isStreaming else { return }
        guard bitrateKbps != maxVideoBitrateKbps else { return }
        maxVideoBitrateKbps = bitrateKbps
        // Snapshot position so we can resume where the viewer was.
        let resumeMs = Int(player.currentTime().seconds.isFinite ? player.currentTime().seconds * 1000 : 0)
        removeObservers()
        Task { await self.startStreaming(resumeOffsetMsOverride: resumeMs) }
    }

    // MARK: - Streaming path

    /// Build (or rebuild) the streaming player item. `resumeOffsetMsOverride` lets a
    /// bitrate reload resume at the live playhead instead of the item's saved viewOffset.
    private func startStreaming(resumeOffsetMsOverride: Int? = nil) async {
        guard let server, let token else { return }
        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"

        // 0 (Maximum/Original) maps to a very high ceiling so PMS still emits a
        // playable HLS rendition rather than rejecting an absent cap.
        let requestedCap = maxVideoBitrateKbps <= 0 ? 200_000 : maxVideoBitrateKbps

        // Resume position. Tell PMS to PRIME the transcode here (seconds) so it emits
        // `#EXT-X-START:TIME-OFFSET` and the first segment at the playhead is produced
        // immediately. Without this PMS transcodes from 0 and a deep client seek stalls
        // waiting on a segment the transcoder hasn't reached yet.
        let resumeMs = resumeOffsetMsOverride ?? item.viewOffset
        let offsetSeconds = (resumeMs ?? 0) > 0 ? (resumeMs! / 1000) : nil

        let transcode = TranscodeRequest(server: server,
                                         token: token,
                                         identity: identity,
                                         metadataKey: metadataKey,
                                         maxVideoBitrateKbps: requestedCap,
                                         sessionID: sessionID,
                                         mediaIndex: mediaIndex,
                                         partIndex: 0,
                                         startOffsetSeconds: offsetSeconds)

        // Ask PMS for a transcode decision. We proceed for both directPlay and
        // transcode; only a hard `.unsupported` aborts. A failed decision call is
        // non-fatal — fall through and try start.m3u8 anyway.
        var decision: DecisionResponse?
        do {
            let decisionReq = PlexRequest(url: transcode.decisionURL(), method: "GET")
            let response = try await client.send(decisionReq, as: DecisionResponse.self)
            decision = response
            if case .unsupported = response.decision {
                // Best-effort: still attempt playback; PMS often plays despite an
                // odd decision code. Logged for the integration pass.
                NSLog("PlaybackController: transcode decision unsupported: \(String(describing: response.generalDecisionText))")
            }
        } catch {
            NSLog("PlaybackController: decision call failed (\(error)); attempting start.m3u8 anyway")
        }

        // Seed the Stats-for-Nerds static facts (no token is ever read here).
        diagnostics.applyStatic(item: item,
                                decision: decision,
                                server: server,
                                targetBitrateKbps: maxVideoBitrateKbps)

        let streamURL = transcode.startM3U8URL()
        let asset = AVURLAsset(url: streamURL)
        let playerItem = AVPlayerItem(asset: asset)
        // No client-side seek for streaming: PMS already positions the session via the
        // `offset` param + `#EXT-X-START`, so AVPlayer begins at the resume point with a
        // primed segment. (Seeking again here would re-trigger the cold deep-seek stall.)
        load(playerItem, resumeOffsetMs: nil)
    }

    // MARK: - Local-file path

    private func loadLocalFile(_ url: URL) {
        // Seed static facts for the Stats overlay; offline playback is always a local
        // direct file (no transcode decision, no remote host).
        diagnostics.applyStatic(item: item,
                                decision: nil,
                                server: nil,
                                targetBitrateKbps: 0)
        diagnostics.connectionHost = "Local file"

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        // Offline content resumes from the same `viewOffset` if present.
        load(playerItem, resumeOffsetMs: item.viewOffset)
    }

    // MARK: - Shared load + observers

    private func load(_ playerItem: AVPlayerItem, resumeOffsetMs: Int?) {
        player.replaceCurrentItem(with: playerItem)
        installObservers(for: playerItem, resumeOffsetMs: resumeOffsetMs)
        startDiagnosticsSampling()
        player.play()
    }

    /// Poll the player's access/error logs ~1s for the Stats overlay. A repeating
    /// `Timer` is used (rather than the timeline observer) so the numbers tick even
    /// while paused and at a finer cadence than the 10s heartbeat.
    private func startDiagnosticsSampling() {
        diagnosticsTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.diagnostics.sample(player: self.player)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsTimer = timer
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
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
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
