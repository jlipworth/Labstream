import Foundation
import Observation
import AVFoundation
import AVFAudio
import MediaPlayer
import UIKit
import PMSKit

/// Queue-based music playback for the Plexamp-style music module (#17).
///
/// Design:
///   • DIRECT PART PLAY, no transcode: `AVPlayer` natively decodes the formats a Plex
///     music library realistically holds (mp3/aac/alac/flac), so each track streams its
///     original file via `MusicRequest.trackStreamURL` — no `/video/:/transcode` decision,
///     no HLS session to manage, and seeking is instant within the buffered file.
///   • ONE `AVPlayer`, `replaceCurrentItem` per track (mirroring `PlaybackController`,
///     not `AVQueuePlayer`): a single-item player keeps the observer/reporting lifecycle
///     simple and matches the rest of the app. Gapless playback is a later refinement.
///   • ONE `TimelineReporter` PER TRACK: the reporter binds to a single `MediaItem` at
///     init (it's how the video path uses it too), so each track start creates a fresh
///     reporter and the outgoing track gets a final `.stopped` flush before the swap.
///   • Shares `AudioSessionCoordinator` with the video path, configured for music:
///     `.default` mode and `pausesOnBackground: false`, so audio keeps playing when the
///     app loses the foreground / the headset chrome changes. Interruption and
///     route-change handling (pause on AirPods disconnect, resume after a call) is
///     identical to video.
///   • System integration via `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`
///     (first use of MediaPlayer in the app): track metadata + 600×600 artwork in the
///     system Now Playing surface, and play/pause/next/previous/scrub remote commands.
///
/// Unlike `PlaybackController` (created per-presentation), one instance of this
/// controller is expected to live at the app root so music survives navigation; views
/// drive it through the public API below.
@MainActor
@Observable
final class MusicPlayerController {

    /// Queue repeat behavior. `one` replays the current track; `all` wraps the queue.
    enum RepeatMode: CaseIterable {
        case off, all, one
    }

    // MARK: - Observable state

    /// Tracks in DISPLAY order (the order the NowPlaying queue list shows). Shuffle
    /// never reorders this — it only changes the traversal (`playOrder`).
    private(set) var queue: [MediaItem] = []

    /// Index into `queue` of the playing track; `nil` when nothing has been loaded.
    private(set) var currentIndex: Int?

    /// The currently loaded track, derived from `queue`/`currentIndex`.
    var current: MediaItem? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// Whether playback is actively running (mirrors the player's `timeControlStatus`).
    private(set) var isPlaying = false

    /// Set by Now Playing's "go to artist/album" taps; `RootView` consumes it by
    /// switching to the Music tab and pushing the item onto its navigation stack
    /// (the sheet itself sits outside any NavigationStack, so it can't push).
    var navigationRequest: MediaItem?

    /// Live playhead (seconds), updated by a 0.5s periodic time observer.
    private(set) var elapsedSeconds: Double = 0

    /// Duration (seconds) of the current track: the live `AVPlayerItem` duration once
    /// known, falling back to the Plex metadata duration (ms) until then.
    var durationSeconds: Double {
        if let secs = player.currentItem?.duration.seconds, secs.isFinite, secs > 0 {
            return secs
        }
        if let ms = current?.duration { return Double(ms) / 1000 }
        return 0
    }

    /// Whether shuffle is on. Toggling reshuffles the UPCOMING traversal only; the
    /// current track keeps playing and `queue`'s display order is untouched.
    private(set) var shuffleEnabled = false

    /// Active repeat behavior; cycled off → all → one by `cycleRepeatMode()`.
    private(set) var repeatMode: RepeatMode = .off

    /// User-facing playback failure text. Set when a track's `AVPlayerItem` fails (the
    /// controller then auto-advances past it); cleared once a subsequent track reaches
    /// `.readyToPlay` — i.e. on the next genuinely successful start.
    private(set) var playbackErrorMessage: String?

    // MARK: - Internals

    /// The single player every track is loaded into.
    @ObservationIgnored private let player = AVPlayer()

    @ObservationIgnored private let appModel: AppModel

    /// Audio-session config + interruption / route-change handling, shared with the
    /// video path but configured for music: `.default` mode, and NO pause-on-background
    /// (audio keeps playing when the app loses the foreground).
    @ObservationIgnored private lazy var audioSession =
        AudioSessionCoordinator(player: player, mode: .default, pausesOnBackground: false)

    /// Traversal order: indices into `queue`. Identity when unshuffled; with shuffle on,
    /// the current track's index comes first followed by the rest in random order.
    /// `next()`/`previous()` walk this array, NOT `queue` directly.
    @ObservationIgnored private var playOrder: [Int] = []

    /// Browse-session identity that produced the current queue. Queue `MediaItem`s carry backend
    /// ids but no explicit origin session, so every transport/queue action verifies this before it
    /// resolves a track through the current `AppModel` (#136).
    @ObservationIgnored private var queueBrowseSessionKey: String?

    /// Timeline/scrobble reporter for the CURRENT track only — recreated on every track
    /// start (it binds to one `MediaItem` at init). The outgoing reporter flushes a final
    /// `.stopped` before being replaced.
    @ObservationIgnored private var reporter: TimelineReporter?

    // Per-track observers, torn down and reinstalled on each track swap.
    @ObservationIgnored private lazy var trackObservers = PlayerObserverBag(player: player)

    // Player-level observers, installed once on first play and removed in `stop()`.
    @ObservationIgnored private lazy var playerObservers = PlayerObserverBag(player: player)

    /// True once the audio session is active and the player-level observers + remote
    /// commands are registered. Reset by `stop()` so a later play re-prepares.
    @ObservationIgnored private var sessionPrepared = false

    /// True after the queue finished with repeat off. The player item is parked at its
    /// end, so a plain `play()` would silently do nothing — `togglePlayPause()` checks
    /// this and restarts the queue instead. Cleared by any track start.
    @ObservationIgnored private var atQueueEnd = false

    /// True while music is yielded to a video presentation: paused, remote commands
    /// disabled (so AirPods/system transport drives the video, not us), system Now
    /// Playing left to the video path. Cleared when music playback resumes.
    @ObservationIgnored private var suspendedForVideo = false

    /// Artwork for the current track, cached so play/pause/seek nowPlayingInfo refreshes
    /// don't drop the image while keeping the (async-fetched) artwork best-effort.
    @ObservationIgnored private var currentArtwork: MPMediaItemArtwork?

    /// How often (seconds) the elapsed-time observer fires.
    @ObservationIgnored private let elapsedIntervalSeconds: Double = 0.5

    /// How often (seconds) the timeline heartbeat fires (matches the video path).
    @ObservationIgnored private let heartbeatIntervalSeconds: Double = 10

    // MARK: - Init

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    // MARK: - Public API

    /// Replace the queue with `tracks` (display order) and start playing the track at
    /// `index`. Respects the current shuffle flag: when shuffle is on, the chosen track
    /// plays first and the rest follow in a fresh random order.
    func play(tracks: [MediaItem], startingAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        queueBrowseSessionKey = appModel.activeBrowseSessionKey
        queue = tracks
        rebuildPlayOrder(currentFirst: index)
        startTrack(at: index)
    }

    /// Enable shuffle, then play `tracks` starting from a random one — the "shuffle
    /// album" affordance.
    func playAlbumShuffled(tracks: [MediaItem]) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = true
        play(tracks: tracks, startingAt: Int.random(in: tracks.indices))
    }

    /// Toggle between playing and paused. No-op when nothing is loaded. After the queue
    /// has finished (repeat off), play restarts the queue from the top — the parked
    /// at-end item can't resume with a plain `play()`.
    func togglePlayPause() {
        guard ensureCurrentQueueSession() else { return }
        guard player.currentItem != nil else { return }
        if atQueueEnd {
            if let firstIdx = playOrder.first { startTrack(at: firstIdx) }
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if suspendedForVideo { reclaimFromVideo() }
            player.play()
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    /// Yield to a video presentation: pause music AND detach from the system transport
    /// (otherwise an AirPods tap during the movie would resume music underneath it).
    /// Call before launching any fullscreen video player. No-op when idle.
    func pauseForVideo() {
        guard ensureCurrentQueueSession() else { return }
        guard sessionPrepared, player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        setRemoteCommands(enabled: false)
        suspendedForVideo = true
        updateNowPlayingPlaybackState()
    }

    /// Undo `pauseForVideo()`: reactivate the music audio session (idempotent),
    /// re-enable our remote commands, and rebuild the system Now Playing card the
    /// video path may have cleared.
    private func reclaimFromVideo() {
        suspendedForVideo = false
        audioSession.activate()
        setRemoteCommands(enabled: true)
        if let track = current { updateNowPlayingInfo(for: track) }
    }

    /// Advance to the next track in the traversal order. A manual next at the end of the
    /// queue wraps to the start regardless of repeat mode (the user asked explicitly);
    /// only the AUTO advance at play-to-end honors `.off` by stopping.
    func next() {
        guard ensureCurrentQueueSession() else { return }
        advance(auto: false)
    }

    /// Restart the current track if more than 3 seconds in; otherwise go to the previous
    /// track in the traversal order (or restart when already at the first).
    func previous() {
        guard ensureCurrentQueueSession() else { return }
        guard currentIndex != nil else { return }
        if elapsedSeconds > 3 {
            seek(to: 0)
            return
        }
        guard let currentIndex,
              let pos = playOrder.firstIndex(of: currentIndex),
              pos > 0 else {
            seek(to: 0)
            return
        }
        startTrack(at: playOrder[pos - 1])
    }

    /// Seek the current track to `seconds`. Zero tolerance so the scrubber lands exactly
    /// where the user dropped it; `elapsedSeconds` updates eagerly so the UI doesn't snap
    /// back while the seek completes.
    func seek(to seconds: Double) {
        guard ensureCurrentQueueSession() else { return }
        let clamped = max(0, seconds)
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        elapsedSeconds = clamped
        updateNowPlayingPlaybackState()
    }

    /// Toggle shuffle. The current track keeps playing; only the UPCOMING traversal is
    /// reshuffled (current first), and turning shuffle off restores queue order.
    func toggleShuffle() {
        guard ensureCurrentQueueSession() else { return }
        shuffleEnabled.toggle()
        rebuildPlayOrder(currentFirst: currentIndex ?? 0)
    }

    /// Cycle off → all → one → off.
    func cycleRepeatMode() {
        guard ensureCurrentQueueSession() else { return }
        let all = RepeatMode.allCases
        guard let idx = all.firstIndex(of: repeatMode) else { return }
        repeatMode = all[(idx + 1) % all.count]
    }

    /// Play a specific queue row (tapped in the NowPlaying queue list). With shuffle on,
    /// the upcoming order is re-randomized from the chosen track.
    func jump(to index: Int) {
        guard ensureCurrentQueueSession() else { return }
        guard queue.indices.contains(index) else { return }
        rebuildPlayOrder(currentFirst: index)
        startTrack(at: index)
    }

    // MARK: - Queue mutation (#17 Phase 4)

    // The index bookkeeping lives in PMSKit's pure `QueueMutation` helpers
    // (unit-tested there); this section only snapshots state in, applies the
    // result, and performs whatever playback side effect the math dictates.

    /// "Play Next": insert `tracks` immediately after the current track in both
    /// display and traversal order. With nothing loaded this just starts playing
    /// them (matching the system-music expectation).
    func playNext(_ tracks: [MediaItem]) {
        guard !tracks.isEmpty else { return }
        guard ensureCurrentQueueSession() else {
            play(tracks: tracks, startingAt: 0)
            return
        }
        guard current != nil else {
            play(tracks: tracks, startingAt: 0)
            return
        }
        apply(QueueMutation.playNext(tracks, in: mutationState))
    }

    /// "Add to Queue": append `tracks` to the END of the queue and of the
    /// traversal — even under shuffle, deliberately (dead-simple semantics,
    /// MUSIC-DESIGN §4.3). Starts playback when nothing is loaded.
    func addToQueue(_ tracks: [MediaItem]) {
        guard !tracks.isEmpty else { return }
        guard ensureCurrentQueueSession() else {
            play(tracks: tracks, startingAt: 0)
            return
        }
        guard current != nil else {
            play(tracks: tracks, startingAt: 0)
            return
        }
        apply(QueueMutation.addToQueue(tracks, in: mutationState))
    }

    /// Remove the queue row at `queueIndex` (display order). Removing the
    /// playing track advances to its traversal successor (no wrap — mirrors the
    /// failure-advance rule); removing it with nothing upcoming stops playback
    /// but keeps the remaining queue visible.
    func remove(at queueIndex: Int) {
        guard ensureCurrentQueueSession() else { return }
        let (state, effect) = QueueMutation.remove(at: queueIndex, from: mutationState)
        switch effect {
        case .none:
            apply(state)
        case .playTrack(let nextIndex):
            apply(state)
            startTrack(at: nextIndex)
        case .stopPlayback:
            if state.queue.isEmpty {
                stop()
            } else {
                haltPlaybackKeepingQueue()
                apply(state)
            }
        }
    }

    /// Display-order reorder (`List.onMove` offset semantics — also what the
    /// queue's Move Up/Down menu actions feed in). `currentIndex` follows its
    /// track. Shuffle off → the traversal becomes the new display order; shuffle
    /// on → the traversal is rebuilt (current first, rest reshuffled).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard ensureCurrentQueueSession() else { return }
        let state = QueueMutation.move(fromOffsets: source, toOffset: destination,
                                       in: mutationState)
        if shuffleEnabled {
            queue = state.queue
            currentIndex = state.currentIndex
            rebuildPlayOrder(currentFirst: state.currentIndex ?? 0)
        } else {
            apply(state)
        }
    }

    /// "Clear queue": drop everything except the current track.
    func clearUpcoming() {
        guard ensureCurrentQueueSession() else { return }
        guard !queue.isEmpty else { return }
        apply(QueueMutation.clearUpcoming(in: mutationState))
    }

    /// Snapshot of the bookkeeping for the pure mutation helpers.
    private var mutationState: QueueMutation.State<MediaItem> {
        .init(queue: queue, playOrder: playOrder, currentIndex: currentIndex)
    }

    /// Write a mutated snapshot back into the observable state.
    private func apply(_ state: QueueMutation.State<MediaItem>) {
        queue = state.queue
        playOrder = state.playOrder
        currentIndex = state.currentIndex
    }

    /// Silence playback WITHOUT the full `stop()` teardown: used when the
    /// playing track is removed and nothing follows it — the rest of the queue
    /// stays visible so the user can tap another row (which goes through
    /// `jump(to:)`/`startTrack` and re-stands everything up).
    private func haltPlaybackKeepingQueue() {
        reporter?.report(state: .stopped, force: true)
        reporter = nil
        removeTrackObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        elapsedSeconds = 0
        currentArtwork = nil
        atQueueEnd = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Clear playback when the active browse session no longer matches the session that produced
    /// the queue. Called both from RootView/ContentView on session changes and defensively before
    /// transport actions, so a stale queue can never later resolve ids against a different server.
    func stopIfBrowseSessionChanged() {
        guard let queueBrowseSessionKey,
              queueBrowseSessionKey != appModel.activeBrowseSessionKey else { return }
        NSLog("MusicPlayerController: clearing music queue for browse session change")
        stop()
    }

    private func ensureCurrentQueueSession() -> Bool {
        guard let queueBrowseSessionKey else { return true }
        guard queueBrowseSessionKey == appModel.activeBrowseSessionKey else {
            NSLog("MusicPlayerController: refusing stale music queue action after browse session change")
            stop()
            return false
        }
        return true
    }

    /// Tear down playback entirely: final `.stopped` report, all observers and remote-
    /// command targets removed, the player emptied, the audio session released (notifying
    /// other audio apps), and the queue cleared.
    func stop() {
        reporter?.report(state: .stopped, force: true)
        reporter = nil
        removeTrackObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        // Session-level teardown only when first play actually prepared it; stopping a
        // never-started controller shouldn't deactivate an audio session it never owned.
        if sessionPrepared {
            removePlayerObservers()
            removeRemoteCommandTargets()
            // Leave the shared command center enabled for whoever uses it next; a
            // disabled-while-suspended state must not outlive this controller's session.
            setRemoteCommands(enabled: true)
            audioSession.removeObservers()
            audioSession.deactivate()
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        currentArtwork = nil
        queueBrowseSessionKey = nil
        queue = []
        playOrder = []
        currentIndex = nil
        isPlaying = false
        elapsedSeconds = 0
        playbackErrorMessage = nil
        sessionPrepared = false
        atQueueEnd = false
        suspendedForVideo = false
    }

    // MARK: - Traversal

    /// Rebuild `playOrder` for the current queue. Unshuffled → identity. Shuffled →
    /// `first` (the playing/starting track) leads, the rest follow in random order.
    private func rebuildPlayOrder(currentFirst first: Int) {
        guard !queue.isEmpty else {
            playOrder = []
            return
        }
        if shuffleEnabled {
            let lead = queue.indices.contains(first) ? first : 0
            playOrder = [lead] + queue.indices.filter { $0 != lead }.shuffled()
        } else {
            playOrder = Array(queue.indices)
        }
    }

    /// Move to the next track in `playOrder`. `auto` distinguishes a play-to-end advance
    /// (honors `repeatMode == .off` by stopping at the queue end) from a user-initiated
    /// `next()` (always wraps). `wrapOnEnd` is forced off for failure-driven advances so
    /// a queue where every track fails can't loop forever.
    private func advance(auto: Bool, wrapOnEnd: Bool = true) {
        guard ensureCurrentQueueSession() else { return }
        guard let currentIndex,
              let pos = playOrder.firstIndex(of: currentIndex) else { return }
        let nextPos = pos + 1
        if nextPos < playOrder.count {
            startTrack(at: playOrder[nextPos])
        } else if wrapOnEnd, (!auto || repeatMode == .all), let firstIdx = playOrder.first {
            startTrack(at: firstIdx)
        } else {
            finishQueue()
        }
    }

    /// End of queue with repeat off: stop playing but keep the queue (and the last track
    /// as `current`) visible so the user can replay or pick another row.
    private func finishQueue() {
        reporter?.report(state: .stopped, force: true)
        player.pause()
        isPlaying = false
        atQueueEnd = true
        updateNowPlayingPlaybackState()
    }

    // MARK: - Track loading

    /// Load and play `queue[index]`: flush the outgoing track's reporter, build the
    /// direct-play stream URL, swap the player item, and stand up the per-track reporter
    /// + observers. First call also activates the audio session, installs the player-
    /// level observers, and registers the remote commands.
    private func startTrack(at index: Int) {
        guard ensureCurrentQueueSession() else { return }
        guard queue.indices.contains(index) else { return }
        let track = queue[index]

        // Resolve the backend-specific stream BEFORE tearing anything down: a bad target
        // track must not silence the one that's already playing.
        let stream: MusicStreamResolver.Stream
        do {
            stream = try MusicStreamResolver.stream(for: track, appModel: appModel)
        } catch MusicStreamResolver.ResolveError.notConnected {
            // No server: surface it but DON'T advance — no track would play.
            playbackErrorMessage = "Not connected to a server."
            return
        } catch {
            // No playable file on this track: surface it and skip forward (mirrors
            // handleTrackFailure) instead of stranding the queue on a dead row.
            playbackErrorMessage = "\u{201C}\(track.title)\u{201D} has no playable file. Skipping."
            currentIndex = index
            advance(auto: true, wrapOnEnd: false)
            return
        }

        // Final flush for the outgoing track before its reporter is replaced.
        reporter?.report(state: .stopped, force: true)
        removeTrackObservers()

        if suspendedForVideo { reclaimFromVideo() }
        atQueueEnd = false
        currentIndex = index
        elapsedSeconds = 0
        currentArtwork = nil

        // Auth rides in the asset header for MediaBrowser (token not in URL); Plex bakes
        // its token into the URL and needs no header (see MusicStreamResolver).
        let assetOptions: [String: Any]? = stream.headers.isEmpty
            ? nil
            : ["AVURLAssetHTTPHeaderFieldsKey": stream.headers]
        let playerItem = AVPlayerItem(asset: AVURLAsset(url: stream.url, options: assetOptions))

        reporter = makeReporter(for: track)

        prepareSessionIfNeeded()
        installTrackObservers(for: playerItem)
        player.replaceCurrentItem(with: playerItem)
        player.play()
        isPlaying = true

        updateNowPlayingInfo(for: track)
        fetchArtwork(for: track)
    }

    /// Timeline/scrobble reporting uses the Plex PMS `/:/timeline` + scrobble endpoints,
    /// so it is created only for Plex. MediaBrowser (Jellyfin/Emby) music progress
    /// reporting is a later refinement; until then those tracks simply don't scrobble.
    private func makeReporter(for track: MediaItem) -> TimelineReporter? {
        guard appModel.activeBackend == .plex,
              let server = appModel.serverBaseURL, let token = appModel.serverToken else { return nil }
        return TimelineReporter(item: track,
                                server: server,
                                token: token,
                                identity: appModel.identity,
                                client: appModel.client,
                                player: player)
    }

    /// One-time (per controller life) session prep: activate the music-mode audio
    /// session, register interruption/route-change observers, install the player-level
    /// time/rate observers, and hook up the system remote commands.
    private func prepareSessionIfNeeded() {
        guard !sessionPrepared else { return }
        sessionPrepared = true
        audioSession.activate()
        audioSession.installObservers()
        installPlayerObservers()
        registerRemoteCommands()
    }

    // MARK: - Observers

    /// Per-track observers: item status (readiness gate / failure) and play-to-end.
    private func installTrackObservers(for playerItem: AVPlayerItem) {
        // Item status, observed for the item's whole lifetime (mirrors PlaybackController
        // P4 #8): `.readyToPlay` opens the timeline readiness gate and clears any stale
        // error; `.failed` surfaces a message and auto-advances past the bad track.
        trackObservers.store(playerItem.observe(\.status, options: [.new]) { [weak self] pItem, _ in
            guard let self else { return }
            Task { @MainActor in
                // Ignore stale callbacks from an item we've already swapped out.
                guard pItem === self.player.currentItem else { return }
                switch pItem.status {
                case .readyToPlay:
                    // Gate timeline/scrobble heartbeats until a real duration exists
                    // (P8 #11), and clear the error surface — this is a successful start.
                    let durSecs = pItem.duration.seconds
                    if durSecs.isFinite && durSecs > 0 {
                        self.reporter?.isReadyForReporting = true
                    }
                    self.playbackErrorMessage = nil
                    // The live duration is now known; refresh the system Now Playing.
                    if let track = self.current {
                        self.updateNowPlayingInfo(for: track)
                    }
                case .failed:
                    self.handleTrackFailure(pItem.error)
                default:
                    break
                }
            }
        })

        // Natural end of track: scrobble, then advance per the repeat mode.
        trackObservers.storeNotification(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self, weak playerItem] _ in
            Task { @MainActor in
                guard let self,
                      let endedItem = playerItem,
                      endedItem === self.player.currentItem else { return }
                self.handleTrackEnded()
            }
        })
    }

    /// Player-level observers (installed once): the 0.5s elapsed-time tick, the 10s
    /// timeline heartbeat + near-end scrobble, and the play/pause state mirror.
    private func installPlayerObservers() {
        let elapsedInterval = CMTime(seconds: elapsedIntervalSeconds, preferredTimescale: 600)
        playerObservers.storeTimeObserver(player.addPeriodicTimeObserver(forInterval: elapsedInterval,
                                                                         queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, seconds.isFinite else { return }
                self.elapsedSeconds = seconds
            }
        })

        let heartbeatInterval = CMTime(seconds: heartbeatIntervalSeconds, preferredTimescale: 1)
        playerObservers.storeTimeObserver(player.addPeriodicTimeObserver(forInterval: heartbeatInterval,
                                                                         queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.ensureCurrentQueueSession() else { return }
                let state: TimelineRequest.State =
                    self.player.timeControlStatus == .paused ? .paused : .playing
                self.reporter?.report(state: state, force: false)
                // Progress-based scrobble (P9 #11): mark played once past ~90%, with
                // didPlayToEnd as the backstop.
                self.reporter?.scrobbleIfNearEnd()
            }
        })

        // Mirror play/pause into observable state, report the flip to PMS, and keep the
        // system Now Playing rate in sync (covers remote-initiated changes too).
        playerObservers.store(player.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            guard let self else { return }
            let status = avPlayer.timeControlStatus
            Task { @MainActor in
                let playing = status != .paused
                guard playing != self.isPlaying else { return }
                self.isPlaying = playing
                self.reporter?.report(state: playing ? .playing : .paused, force: true)
                self.updateNowPlayingPlaybackState()
            }
        })
    }

    private func removeTrackObservers() {
        trackObservers.reset()
    }

    private func removePlayerObservers() {
        playerObservers.reset()
    }

    // MARK: - End / failure handling

    /// Play-to-end: `.one` replays the same track in place (seek to zero — same item,
    /// same reporter); otherwise scrobble and auto-advance (`.all` wraps at the queue
    /// end, `.off` stops there with the queue kept visible).
    private func handleTrackEnded() {
        guard ensureCurrentQueueSession() else { return }
        if repeatMode == .one {
            reporter?.scrobble()
            // Fresh reporter for the replay: scrobbling is one-shot per reporter, so
            // reusing it would count only the first loop as played.
            if let track = current {
                reporter = makeReporter(for: track)
                reporter?.isReadyForReporting = true
            }
            seek(to: 0)
            player.play()
            isPlaying = true
            return
        }
        reporter?.scrobble()
        advance(auto: true)
    }

    /// A track's `AVPlayerItem` failed: surface a friendly message, then skip past the
    /// bad track. The advance deliberately does NOT wrap at the queue end, so a queue
    /// where every track fails terminates instead of looping; the message stays up until
    /// a later track reaches `.readyToPlay`.
    private func handleTrackFailure(_ error: Error?) {
        guard ensureCurrentQueueSession() else { return }
        let title = current?.title ?? "track"
        AppDiagnostics.record(.music, "music.item_failed", fields: [
            "error": .error(error),
            "has_current_track": .bool(current != nil),
        ])
        if let error {
            NSLog("MusicPlayerController: item failed (%@)",
                  DiagnosticRedactor.safeErrorSummary(error))
        }
        playbackErrorMessage = "Couldn't play \u{201C}\(title)\u{201D}. Skipping to the next track."
        advance(auto: true, wrapOnEnd: false)
    }

    // MARK: - System Now Playing (MPNowPlayingInfoCenter)

    /// Push the current track's metadata into the system Now Playing surface: title,
    /// artist (`grandparentTitle`), album (`parentTitle`), duration, playhead, rate, and
    /// any already-fetched artwork. Called on every track change and on play/pause/seek.
    private func updateNowPlayingInfo(for track: MediaItem) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist = track.grandparentTitle {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = track.parentTitle {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let currentArtwork {
            info[MPMediaItemPropertyArtwork] = currentArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Lightweight refresh of the time-varying Now Playing fields (playhead + rate)
    /// without rebuilding the whole dictionary.
    private func updateNowPlayingPlaybackState() {
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else {
            // Another player (the video path) cleared the center; rebuild from scratch
            // so music doesn't silently vanish from the system surface.
            if let track = current { updateNowPlayingInfo(for: track) }
            return
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
    }

    /// Best-effort 600×600 artwork fetch for the system Now Playing card, resolved by the
    /// shared `MediaArtwork` helper (Plex `/photo` transcode, or the authenticated
    /// Jellyfin/Emby image endpoint). Guards that the track is still current before
    /// assigning, so a quick skip can't attach stale art.
    private func fetchArtwork(for track: MediaItem) {
        guard let request = MediaArtwork.imageRequest(path: track.musicArtPath,
                                                      appModel: appModel,
                                                      pixelWidth: 600,
                                                      pixelHeight: 600) else { return }
        let ratingKey = track.ratingKey
        Task { [weak self] in
            guard let data = await Self.fetchArtworkData(request: request),
                  let image = UIImage(data: data) else { return }
            let artwork = Self.makeArtwork(image)
            await MainActor.run {
                guard let self, self.current?.ratingKey == ratingKey else { return }
                self.currentArtwork = artwork
                if let track = self.current {
                    self.updateNowPlayingInfo(for: track)
                }
            }
        }
    }

    /// MPMediaItemArtwork's request handler is invoked on MediaPlayer's own serial queue
    /// (e.g. while serializing Now Playing info), so it must NOT be actor-isolated — a
    /// closure formed inside this @MainActor class inherits MainActor isolation and the
    /// runtime's dispatch_assert_queue check SIGTRAPs (seen live: crash on first song).
    /// Building it in a nonisolated context keeps the handler callable from any thread.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Best-effort artwork fetch. Returns `nil` (never throws) on any failure so it
    /// can't black-hole playback. `nonisolated` + returns Sendable `Data`.
    private nonisolated static func fetchArtworkData(request: URLRequest) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) { return nil }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    // MARK: - Remote commands (MPRemoteCommandCenter)

    /// Hook up the system transport controls (registered once, on first play; targets
    /// removed in `stop()`). MediaPlayer normally calls these on the main thread, where
    /// we can return the precise status synchronously. If the system ever delivers a
    /// command off-main, schedule the mutation onto the main actor instead of trapping.
    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { () -> MPRemoteCommandHandlerStatus in
                    guard let self, self.player.currentItem != nil else { return .noActionableNowPlayingItem }
                    if !self.isPlaying { self.togglePlayPause() }
                    return .success
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem != nil else { return }
                if !self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { () -> MPRemoteCommandHandlerStatus in
                    guard let self, self.player.currentItem != nil else { return .noActionableNowPlayingItem }
                    if self.isPlaying { self.togglePlayPause() }
                    return .success
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem != nil else { return }
                if self.isPlaying { self.togglePlayPause() }
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { () -> MPRemoteCommandHandlerStatus in
                    guard let self, self.player.currentItem != nil else { return .noActionableNowPlayingItem }
                    self.togglePlayPause()
                    return .success
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem != nil else { return }
                self.togglePlayPause()
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { () -> MPRemoteCommandHandlerStatus in
                    guard let self, self.current != nil else { return .noActionableNowPlayingItem }
                    self.next()
                    return .success
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.current != nil else { return }
                self.next()
            }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { () -> MPRemoteCommandHandlerStatus in
                    guard let self, self.current != nil else { return .noActionableNowPlayingItem }
                    self.previous()
                    return .success
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.current != nil else { return }
                self.previous()
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { () -> MPRemoteCommandHandlerStatus in
                    guard let self, self.player.currentItem != nil,
                          let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                        return .commandFailed
                    }
                    self.seek(to: positionEvent.positionTime)
                    return .success
                }
            }
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = positionEvent.positionTime
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem != nil,
                      !Task.isCancelled else { return }
                self.seek(to: positionTime)
            }
            return .success
        }
    }

    /// Remove all targets from the commands we registered. We're the only MediaPlayer
    /// user in the app, so a blanket `removeTarget(nil)` per command is safe.
    private func removeRemoteCommandTargets() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
    }

    /// Flip `isEnabled` on every command we registered — used to mute the music
    /// transport while a video presentation owns the system controls (targets stay
    /// registered; disabled commands simply don't fire).
    private func setRemoteCommands(enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
        center.nextTrackCommand.isEnabled = enabled
        center.previousTrackCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
    }
}
