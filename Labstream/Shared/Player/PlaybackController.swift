import Foundation
import AVKit
import AVFAudio
import os
import PMSKit

/// Persistent (`.notice`-level, disk-backed) log for the playback session lifecycle.
/// Used sparingly for events worth diagnosing after the fact — e.g. the transcode-stop
/// before an in-place restart (#27), which guards against the server-OOM job pile-up.
let playbackLog = Logger(subsystem: "com.jlipworth.Labstream", category: "Playback")

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

    /// The `AVPlayer` the custom player (its `AVPlayerLayer`) is bound to.
    let player = AVPlayer()

    /// Live diagnostics for the "Stats for Nerds" overlay. Always present; the panel
    /// is hidden until the user toggles it on.
    let diagnostics = PlaybackDiagnostics()

    /// Observable surface for playback failures so the UI (PlayerView/DetailView) can
    /// show an error + Retry. Modeled as its own `@Observable` object (mirroring
    /// `diagnostics`) rather than making the whole controller observable, keeping the
    /// reactive surface minimal. Populated when an `AVPlayerItem` reports `.failed`
    /// or fails to play to end (P3 #8); cleared on a (re)start.
    let playbackError = PlaybackError()

    /// Observable surface for the currently-active Skip Intro / Skip Credits affordance
    /// (#14). Modeled as its own `@Observable` object (mirroring `playbackError`) so the
    /// PlayerView overlay can react to a marker becoming active/inactive without making the
    /// whole controller observable. Populated by the marker time observer while the playhead
    /// is inside an intro/credits range; cleared otherwise.
    let skipMarker = SkipMarkerState()

    /// Observable surface for the "Up Next" card (#15). Modeled as its own `@Observable`
    /// object (mirroring `skipMarker`) so the PlayerView overlay can react to the card
    /// showing/hiding and its countdown ticking without making the whole controller
    /// observable. Holds the resolved next `MediaItem` (an episode, when one exists), whether
    /// the card is currently shown, and a live countdown. Only ever populated for `episode`
    /// items whose next episode resolves; movies / last episodes simply never show it.
    let upNext = UpNextState()

    /// Invoked when the user (or the countdown / play-to-end) requests advancing to the
    /// resolved next item. The PlayerView wires this to its `onRequestPlay`, which the
    /// DetailView turns into a presented-item swap (rebuilding this view/controller for the
    /// next episode). Nil for sessions with no advance handler (e.g. offline playback).
    var onAdvanceToNext: ((MediaItem) -> Void)?

    /// Invoked when playback reaches EOF and there is no resolved Up Next item to advance to.
    /// Player presentations wire this to their close/dismiss action so completed movies and
    /// offline files return to the app instead of sitting on a paused final frame.
    var onPlaybackEnded: (() -> Void)?

    /// Fired whenever the item reaches `.playing`. PlayerView uses it to dismiss the
    /// "Reconnecting…" overlay shown during a failure-recovery rebuild (GH #33): the overlay
    /// covers the window where this controller is nil / the fresh item hasn't started, and
    /// genuine playback is the signal that the rebuild succeeded. Idempotent — safe to fire on
    /// every play transition (including post-rebuffer resumes).
    var onPlaybackActive: (() -> Void)?

    // Inputs.
    let item: MediaItem
    private var client: PlexClient
    private let identity: ClientIdentity
    private let sessionSource: PlaybackSessionSource

    private var plexSession: PlexPlaybackSession? {
        guard case .plex(let session) = sessionSource else { return nil }
        return session
    }

    private var mediaBrowserSession: MediaBrowserPlaybackSession? {
        guard case .mediaBrowser(let session) = sessionSource else { return nil }
        return session
    }

    private var offlineSession: OfflinePlaybackSession? {
        guard case .offline(let session) = sessionSource else { return nil }
        return session
    }

    // Source-specific facts are derived from the typed carrier. Optional access here means
    // "not this source kind", never an independently configurable lane component.
    private var server: URL? { plexSession?.server }
    private var token: String? { plexSession?.token }
    /// App-lifetime artwork facade and exact authority/source descriptor configured by the player
    /// view before `start()`. Offline descriptors never consult current browse credentials.
    private var externalArtworkPipeline: ArtworkPipeline?
    private var externalArtworkDescriptor: ArtworkRequestDescriptor?
    /// Persists local-file playback progress for offline downloads. nil for online streams.
    private var localPlaybackProgress: ((Int, Int?) -> Void)? { offlineSession?.onPlaybackProgress }
    /// Cached per-chapter image file URLs (chapter index → file), for offline playback only (#88).
    /// Empty for online playback, where `chapterThumbnailRequest` derives a live server request instead.
    private var offlineChapterImageURLs: [Int: URL] { offlineSession?.chapterImageURLs ?? [:] }
    private var offlineTextSubtitles: [OfflineTextSubtitleTrack] { offlineSession?.textSubtitles ?? [] }
    private var offlineSubtitleBaseURL: URL? { offlineSession?.subtitleBaseURL }
    private var offlineSubtitleCuesByTrackID: [Int: [OfflineTextSubtitleCue]] = [:]
    private var selectedOfflineSubtitleTrackID: Int?
    private var offlineSubtitleSelectionAuthority = OfflineSubtitleSelectionAuthority()
    private let offlineSubtitleCueLoader: OfflineSubtitleCueLoader
    private var metadataAudioSelectionAuthority = MetadataAudioSelectionAuthority()
    private var metadataAudioSelectionTail: Task<Void, Never>?
    private let plexAudioStreamSelector: PlexAudioStreamSelector?
    var activeMetadataAudioSelectionIntentID: Int? {
        metadataAudioSelectionAuthority.intendedStreamID
    }

    /// Already-resolved remote media URL, when a non-Plex backend (Jellyfin/Emby) has
    /// performed its own playback negotiation and only needs the custom player to open the
    /// resulting stream. This keeps the player surface agnostic: Plex owns its transcode resolver,
    /// while other backends can hand us a concrete stream URL and a re-open hook for quality/seek.
    private var remoteStreamURL: URL? { mediaBrowserSession?.initialStreamURL }
    /// Optional HTTP headers required by `remoteStreamURL`. Backend playback tokens must stay in
    /// headers rather than URL query parameters so client logs/history never capture URL tokens.
    private var remoteHTTPHeaders: [String: String] {
        get { mediaBrowserSession?.httpHeaders ?? [:] }
        set { mediaBrowserSession?.httpHeaders = newValue }
    }
    private var remoteSourceMetadata: MediaBrowserPlaybackSourceMetadata? {
        get { mediaBrowserSession?.sourceMetadata }
        set { mediaBrowserSession?.sourceMetadata = newValue }
    }
    private var remotePlayMethod: MediaBrowserPlayMethod? {
        get { mediaBrowserSession?.playMethod }
        set { mediaBrowserSession?.playMethod = newValue }
    }
    private var remoteTranscodeReasons: [String] {
        get { mediaBrowserSession?.transcodeReasons ?? [] }
        set { mediaBrowserSession?.transcodeReasons = newValue }
    }
    private var remotePlaySessionId: String? {
        get { mediaBrowserSession?.playSessionID }
        set { mediaBrowserSession?.playSessionID = newValue }
    }
    private var mediaBrowserProgressSession: MediaBrowserPlaybackProgressSession? {
        get { mediaBrowserSession?.progressSession }
        set { mediaBrowserSession?.progressSession = newValue }
    }
    private var onStopRemoteSession: (() -> Void)? {
        get { mediaBrowserSession?.onStop }
        set { mediaBrowserSession?.onStop = newValue }
    }
    private var didStopRemoteSession: Bool {
        get { mediaBrowserSession?.didStop ?? true }
        set { mediaBrowserSession?.didStop = newValue }
    }

    /// The server's machine identifier (== the Plex resource `clientIdentifier`), used to
    /// build a play queue for "Up Next" resolution (#15). `nil` when unavailable (offline
    /// playback, or a caller that didn't thread it), in which case Up Next never resolves.
    private var machineIdentifier: String? { plexSession?.machineIdentifier }

    /// Which `Media` entry (version) of the item to transcode. Plex items can ship
    /// multiple files at different resolutions/codecs; the DetailView's version picker
    /// threads the chosen index here so playback uses that specific version. Defaults to
    /// `0` (the first/primary version), which matches the prior hard-coded behavior.
    let mediaIndex: Int

    /// Hard bitrate cap requested of PMS (kbps). 8 Mbps default per spec.
    ///
    /// Mutable: the in-player quality menu rebuilds the stream at a new cap via
    /// `reload(bitrateKbps:)`. `0` is the sentinel for "Direct Play / Maximum" (no cap).
    private(set) var maxVideoBitrateKbps: Int

    /// The user's explicit quality ceiling for this session. Automatic adaptation may move the
    /// active `maxVideoBitrateKbps` down/up inside this ceiling, but never writes preferences or
    /// climbs above what the viewer selected. Manual Quality picks update this and reset the
    /// automatic state machine.
    private var userSelectedMaxVideoBitrateKbps: Int

    private let qualityDefaultsKey: String
    var qualityPreferenceDefaultsKey: String { qualityDefaultsKey }

    /// Per-playback transcode session id (also reused as the timeline session).
    let sessionID = "visionplay-" + UUID().uuidString

    // MARK: - Playback speed (R5)

    /// `@AppStorage`-style key for the persisted playback rate (UserDefaults-backed so the
    /// controller — which can't be a SwiftUI view — and the Speed info tab share one source
    /// of truth, mirroring the subtitle-preference pattern). Default 1.0×.
    private static let playbackSpeedKey = "playbackSpeed"

    /// Observable surface for the playback-speed checkmark in the Speed info tab. Modeled as
    /// its own `@Observable` object (mirroring `skipMarker`/`playbackError`) so the tab reflects
    /// the active rate even after a programmatic reapply, without making the whole controller
    /// observable. Seeded from the persisted choice in `init`.
    let speedState = PlaybackSpeedState()

    /// Observable surface for the rebuffer/stall spinner (#21). Kept for non-chrome callers and
    /// diagnostics compatibility; user-facing transport overlays are now derived by
    /// `transportStatus` so views do not compose buffering + retry + failure booleans.
    let buffering = BufferingState()

    /// Single authoritative transport-status overlay model for all custom player surfaces.
    /// Windowed and Cinema chrome read this instead of each maintaining local
    /// buffering/reconnecting state.
    let transportStatus = PlaybackTransportStatusState()

    /// Observable mirror of the player's paused state, driven from the same
    /// `timeControlStatus` KVO as the timeline reporting. `PlayerControlSurface` uses it to
    /// offer the "✕ Close" contextual action only while PAUSED (or failed) — visionOS has no
    /// transport-bar-visibility callback (`API_UNAVAILABLE(visionos)`), so this is the only
    /// signal that keeps the pill off the video during normal playback.
    let transport = TransportState()

    /// Observable text overlay for locally cached offline sidecar subtitles (#80).
    let offlineSubtitleOverlay = OfflineSubtitleOverlayState()

    /// The user's chosen playback rate, persisted across launches and reapplied to each new
    /// item once it reaches `.readyToPlay` (so a Quality reload — which swaps the
    /// `AVPlayerItem` and resets the rate to 1.0 — doesn't clobber the choice). Read from
    /// UserDefaults, defaulting to 1.0 when unset.
    private var playbackSpeed: Float {
        get {
            let v = UserDefaults.standard.object(forKey: Self.playbackSpeedKey) as? Double
            return Float(v ?? 1.0)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.playbackSpeedKey) }
    }

    // State.
    private lazy var observers = PlayerObserverBag(player: player)
    private lazy var diagnosticsObservers = PlayerObserverBag()
    private var lastDiagnosticSnapshotUptime: TimeInterval = 0
    private var lastDiagnosticTimeControlStatus: AVPlayer.TimeControlStatus?
    private var currentPlayerItemGeneration = 0
    private var nextPlayerItemGeneration = 0
    private var ignoredRecoverableFailedToEndCount = 0
    private let videoNowPlayingMetadataObservers = VideoNowPlayingMetadataObserverRegistry()
    #if os(visionOS)
    /// visionOS has no platform coordinator around the player layer, so its system Now
    /// Playing session is owned directly by the playback controller (#197).
    private var videoNowPlayingCoordinator: VideoNowPlayingCoordinator?
    #endif
    /// Watchdog for a stalled stream (#8 hardening). HLS network loss frequently manifests as a
    /// PERMANENT stall — the player sits in `.waitingToPlayAtSpecifiedRate` with an empty buffer
    /// and never flips `AVPlayerItem.status` to `.failed` (AVKit paints its own placeholder glyph
    /// from the error log, but neither the status observer nor `failedToPlayToEnd` fires). This
    /// timer is the catch-all: armed while the player is starved, it surfaces the error+Retry
    /// overlay if the stall outlasts `stallTimeoutSeconds`, turning a dead-end into a recoverable
    /// state. Cancelled the moment playback genuinely resumes (`.playing`).
    private lazy var stallWatchdogObservers = PlayerObserverBag()
    /// GH #196: non-nil when the DV P5 guard forced this session onto a tone-map transcode.
    /// Drives the first-frame watchdog and the Stats decision suffix.
    private var dvGuardReason: String?
    private lazy var dvGuardWatchdogObservers = PlayerObserverBag()
    private var dvGuardProgressBaseline: StallProgressSignature?
    private var reconnectWatchdogTask: Task<Void, Never>?
    private let reconnectWatchdogAuthority = PlaybackReconnectWatchdogAuthority()
    private var reconnectInProgress = false
    private var hasObservedPlayback = false
    private var currentTimeControlStatus: AVPlayer.TimeControlStatus = .paused
    private var hasObservedTimeControlStatus = false
    /// True while the controller is actively producing a fresh AVPlayerItem — from entering a
    /// begin/reopen path (detach → negotiate → prewarm → proxy standup → load) until the new
    /// item's first `timeControlStatus` KVO or `.readyToPlay`. During that window the cached
    /// KVO fields above are STALE (they hold the previous item's last value and are only reset
    /// in `load()`), so `resolvedTransportStatus()` would otherwise fall through to `.none`
    /// over a black, item-less video surface — the recurring "black screen, no indicator"
    /// class (GH #110 follow-up; every begin/reopen lane, not just seek rebuilds).
    private var itemPreparationInProgress = false
    private var itemPreparationWatchdogTask: Task<Void, Never>?
    private var itemPreparationProgressBaseline: StallProgressSignature?
    private var lastLoggedTransportStatus: PlaybackTransportStatus = .none
    /// Observer for `AVPlayerItem.timeJumpedNotification` — the only in-process signal of a user
    /// seek on visionOS (#25): AVKit's user-navigation delegate callbacks
    /// (`willResumePlaybackAfterUserNavigatedFromTime:toTime:`) are `API_UNAVAILABLE(visionos)`,
    /// checked in the XROS 26.5 AVPlayerViewController.h.
    private var started = false
    private var preferShortRemoteHLSBufferForNextLoad = false
    private var activeForwardBufferTargetSeconds: Double = 0
    private var playbackStartupSpan: PerformanceSpan?
    private var playbackItemLoadSpan: PerformanceSpan?
    private var playbackTask: Task<Void, Never>?
    private var upNextTask: Task<Void, Never>?
    private var playbackGeneration = 0
    private lazy var lifecycleCallbacks = PlaybackLifecycleCallbackSink<Int> { [weak self] generation in
        self?.isCurrentPlaybackLifecycle(generation) == true
    }
    private var remoteHLSProxy: MediaSessionProxy?
    private var remoteHLSProxyGeneration: Int?
    /// User transport intent, independent of AVPlayer's transient loading state.
    ///
    /// During initial HLS priming AVPlayer sits in `.waitingToPlayAtSpecifiedRate`, so a quick
    /// tap on Pause can otherwise be lost or undone by the later `.readyToPlay` rate reapply.
    /// Keep the user intent here and honor it once the item becomes ready (#40).
    private var userWantsPaused = false

    /// Playback-time direct-play fallback (Direct Play / Maximum). PMS can agree to copy the
    /// video (`savesVideoEncode`) yet hand back an HLS rendition AVFoundation can't actually
    /// play, which fails at LOAD time — not at the decision stage. `directPlayFallbackArmed`
    /// is set only while a committed direct-play stream is live; on its first failure we
    /// fall back once to the production HLS path instead of surfacing a dead-end. That path may
    /// still Direct Stream/video-copy; it is not an automatic capped video-transcode fallback.
    /// `suppressDirectPlayProbe` is the one-shot that makes that rebuild skip the literal
    /// direct-play start and also marks "a fallback is in flight" so a sibling failure
    /// callback on the same dead item doesn't surface over it. Both are reset/consumed at the
    /// top of every `startStreaming`.
    private var directPlayFallbackArmed = false
    private var suppressDirectPlayProbe = false
    /// Direct-play `start.m3u8` rejections seen during this controller's lifetime, keyed by
    /// metadata/media/part. Plex can return "Direct play OK" from the decision endpoint and then
    /// reject the actual `directPlay=1` start with HTTP 400; once seen, avoid retrying the same
    /// doomed start on every seek/reopen until the viewer explicitly changes quality.
    private var rejectedDirectPlayStartKeys: Set<String> = []

    /// GH #196 startup-deadline auto-retry (one-shot). When AVFoundation abandons the sole
    /// copy-lane variant because the first segments missed its hard startup deadlines
    /// (-12889/-16830 → -12880), a single warm rebuild — same session, transcoder NOT
    /// stopped, segments from the failed attempt already on disk — almost always succeeds.
    /// Reset once real playback is observed, so a genuinely dead stream still surfaces
    /// Retry to the user after one silent attempt.
    private var startupDeadlineRetryAttempted = false

    /// Client-driven ABR state machine (#29). True ABR is a server HLS ladder; when Plex/Jellyfin
    /// hands us one concrete stream instead, this policy approximates adaptive playback by
    /// reopening at bounded rungs after sustained stall/down and sustained healthy playback/up.
    /// The pure anti-oscillation rules live in PMSKit tests; this controller owns the player and
    /// backend reopen side effects.
    private var adaptiveBitratePolicy = AdaptiveBitratePolicy(
        transcodedRungsKbps: StreamingQuality.ladder.map(\.kbps).filter {
            $0 > 0 && $0 < StreamingQuality.maxTranscodedKbps
        })

    /// Server-safe final-target rebuild policy (#33 reset). A drag can emit many
    /// `timeJumpedNotification`s, but PMS must only see one intentional rebuild at the final
    /// settled target. The pure policy is unit-tested in PMSKit; the controller owns the timer and
    /// the actual player-item replacement.
    private var finalTargetRebuildPolicy = FinalTargetRebuildPolicy()
    private var finalTargetSettleTask: Task<Void, Never>?
    private var activeFinalTargetRebuildGeneration: Int?
    private static let finalTargetSettleNanos: UInt64 = 500_000_000
    private static let diagnosticSnapshotIntervalSeconds: TimeInterval = 15
    private static let defaultAdaptiveUpshiftBufferSeconds: Double = 45
    private static let remoteTranscodeAdaptiveUpshiftBufferSeconds: Double = 10
    private var adaptiveBitrateEnabled: Bool {
        PlaybackPreferences.adaptiveBitrateEnabled()
    }
    /// Offset we most recently primed via `start.m3u8?offset=...`; suppress nearby programmatic
    /// resume seeks so a rebuild does not immediately schedule another rebuild.
    private var lastPrimedOffsetMs = 0
    private static let finalTargetEchoEpsilonMs = 2000

    // MARK: - Extracted collaborators

    /// iOS-only escape hatch for system-video surfaces. Regular video still pauses when
    /// Labstream backgrounds/resigns active, but PiP/AirPlay sessions are allowed to continue.
    var shouldContinueOnBackground: @MainActor () -> Bool = { false }

    /// Audio-session config + interruption / route-change / background handling (#17, P5).
    /// Activated and observer-registered once per controller lifetime (both idempotent
    /// across a Quality reload); torn down in `stop()`.
    private lazy var audioSession = AudioSessionCoordinator(
        player: player,
        shouldContinueOnBackground: { [weak self] in
            self?.shouldContinueOnBackground() ?? false
        }
    )

    /// Timeline heartbeats + scrobble reporting to PMS. Spans Quality reloads (its
    /// one-shot scrobble guard deliberately survives a stream rebuild); its readiness
    /// gate is reset per item in `load(_:)`.
    private lazy var timeline = TimelineReporter(item: item,
                                                 server: server,
                                                 token: token,
                                                 identity: identity,
                                                 client: client,
                                                 player: player,
                                                 mediaBrowserProgressSession: { [weak self] in
                                                     self?.mediaBrowserProgressSession
                                                 })

    /// One-shot guard for the resume seek. Replaces the old "self-nil the observation
    /// inside its own callback" pattern (P4 #8): nilling the observation there meant a
    /// later `unknown → ready → failed` transition was never seen. We now keep the
    /// status observation alive for the item's lifetime and gate the resume seek on this
    /// flag instead, so `.failed` is still observed after `.readyToPlay`.
    private var didSeek = false

    /// One-shot guard so the saved-subtitle-language auto-select runs once per item. Reset
    /// in `load(_:)` alongside the other per-item flags so a Quality reload (which swaps the
    /// `AVPlayerItem`) re-applies the preference to the new legible group.
    private var didApplySavedSubtitle = false

    /// True once the runtime HDR probe (#195) saw real video format descriptions for the
    /// current item. HLS items expose no format descriptions until segments load, so an
    /// inconclusive readyToPlay-time probe is retried from the diagnostics tick.
    private var hdrProbeConclusive = false

    /// One-shot guard so the saved-audio-language auto-select runs once per item (#3). Reset in
    /// `load(_:)` alongside `didApplySavedSubtitle` so a Quality reload re-applies the preference
    /// to the new audible group.
    private var didApplyAudioPreference = false

    /// `@AppStorage` keys for the persisted subtitle preference. Mirrors the UserDefaults-backed
    /// quality-cap pattern (`PlaybackPreferences`) so the controller — which can't be a SwiftUI
    /// view — and the settings UI share one source of truth.
    private enum SubtitlePrefKey {
        /// BCP-47 / ISO language code of the user's last chosen subtitle track (e.g. "en").
        static let language = PlaybackPreferences.Keys.preferredSubtitleLanguage
        /// `true` once the user has explicitly chosen "Off"; suppresses auto-select.
        static let off = PlaybackPreferences.Keys.subtitlesOff
    }

    /// `@AppStorage`-style key for the persisted audio-language preference (#3). Mirrors
    /// `SubtitlePrefKey`, but there is no "Off" — a video always plays some soundtrack.
    private enum AudioPrefKey {
        /// BCP-47 / ISO language code of the user's last chosen audio track (e.g. "en").
        static let language = PlaybackPreferences.Keys.preferredAudioLanguage
    }

    /// Every UserDefaults key this controller persists across sessions, for the Settings
    /// "Reset playback preferences" row (#26). Deliberately EXCLUDES `maxVideoBitrateKbps`,
    /// which has its own Streaming-quality picker. Keep in sync with the key enums above.
    static let persistedPreferenceKeys: [String] = [
        playbackSpeedKey,
        SubtitlePrefKey.language,
        SubtitlePrefKey.off,
        AudioPrefKey.language,
        PlaybackPreferences.Keys.subtitleAutoSelectMode,
        PlaybackPreferences.Keys.subtitleBurnMode,
        PlaybackPreferences.Keys.mobileVideoDisplayMode,
    ]

    /// Resume target (ms) for the current item, retained so the status observer can do a
    /// client-side seek fallback if PMS's `#EXT-X-START` priming didn't land (P2 #9).
    private var pendingResumeSample: PlaybackPositionSample?
    private var pendingResumeMs: Int? { pendingResumeSample?.positionMs }

    /// Last playhead that came from a trustworthy live clock or explicit user/restart target.
    /// Quality/audio/retry restarts use this as a guard against AVPlayer's transient 0 while an
    /// item is detached or a replacement HLS item has not landed yet.
    private var lastTrustworthyPlaybackSample: PlaybackPositionSample?
    private var lastTrustworthyPlaybackMs: Int? { lastTrustworthyPlaybackSample?.positionMs }

    /// AVPlayer often reports exactly/near 0 while a new item is being attached even though the
    /// server has been primed at a later offset. Treat 0..1.5s as a suspicious "near start"
    /// snapshot only when we have better evidence of prior progress.
    private static let transientZeroPlayheadThresholdMs = PlaybackPositionResolver.transientZeroThresholdMs

    /// One-shot guard for a diagnostic that catches the user-visible desync where the HLS item
    /// restarts near zero but the chrome keeps showing a stale resume/seek target.
    private var didLogResumeClockDesync = false

    /// True from the moment a user seek is dispatched (`performUserSeek` / scheduled final-target
    /// rebuild / remote reopen) until playback actually lands at the requested target. While set,
    /// the scrubber clock holds the committed target (GH #110): `tickCustomScrubberClock` skips
    /// `updateLivePosition` so the displayed time can't bounce between the target and a stale
    /// `currentResumeMs` reading during a Jellyfin/Emby/Plex stream rebuild. Replaces the old
    /// position-tolerance auto-clear, which fired too early (before the reopen completed) and had
    /// no lifecycle guard. MUST be cleared on every completion/failure/cancel path so the label
    /// can never freeze forever — see `setSeeking(_:)` call sites.
    private var seekHold = PlaybackSeekHold()
    var isSeeking: Bool { seekHold.isActive }
    private var seekHoldTargetMs: Int? { seekHold.target?.positionMs }
    private var seekGeneration: Int { seekHold.generation }

    /// Absolute upper bound on how long the scrubber may stay pinned to the seek target. Generous
    /// enough to cover a slow Jellyfin/Emby reopen + prime, short enough that a label can never
    /// look stuck.
    private let maxSeekHoldSeconds: TimeInterval = 12

    /// Centralized setter so every set/clear is greppable and consistently logged. Low-volume:
    /// fires once per seek begin/end, not per tick.
    private func setSeeking(_ seeking: Bool, targetMs: Int? = nil) {
        let wasSeeking = isSeeking
        if seeking {
            seekHold.begin(targetMs: targetMs,
                           now: ProcessInfo.processInfo.systemUptime)
            // FINDING 6: the max-hold ceiling must be measured from the LATEST (re)dispatched seek,
            // not the first. Re-seed the start timestamp on EVERY `setSeeking(true, …)` so a
            // continuous drag / rapid sequence of out-of-buffer reseeks keeps pushing the ceiling
            // forward — it then only fires after `maxSeekHoldSeconds` of genuine no-progress on the
            // most recent seek, instead of force-releasing mid-drag and resuming the label bounce
            // GH #110 fixed. The ceiling still fires if a SINGLE seek truly never lands (the clock
            // never crosses `target - slack` and no newer seek re-arms the timestamp).
        } else {
            seekHold.clear()
        }
        guard wasSeeking != seeking else { return }
        NSLog("PlaybackController: isSeeking=%@ targetMs=%@",
              seeking ? "true" : "false",
              seekHoldTargetMs.map { String($0) } ?? "nil")
        // The transport overlay covers the rebuild window of an in-flight seek (see
        // `resolvedTransportStatus`), so it must be re-derived on every hold begin/end.
        updateTransportStatus()
    }

    /// Release the hold only if it still belongs to the seek that scheduled this completion
    /// (guards against a stale native-seek completion clearing a newer seek's hold).
    private func clearSeekHold(ifGeneration generation: Int) {
        let wasSeeking = isSeeking
        guard seekHold.clear(ifGeneration: generation) else { return }
        if wasSeeking { updateTransportStatus() }
    }

    /// Tick-loop backstop (called from `tickCustomScrubberClock`): the per-item `.readyToPlay` only
    /// fires once and may land before the remote transcode's clock reaches the target, so the
    /// 500ms scrubber tick also polls for "live clock has reached the held target" to release the
    /// hold. Same landed-check as the readyToPlay path; cheap no-op when not seeking.
    func releaseSeekHoldIfLanded() {
        clearSeekHoldIfLanded()
    }

    /// Called from the per-item `.readyToPlay` observer for a rebuild/reopen-backed seek: once the
    /// live clock is at or past the held target (within a small slack), the rebuild has landed and
    /// the hold is released so the scrubber resumes following the live position.
    private func clearSeekHoldIfLanded() {
        guard isSeeking, let target = seekHoldTargetMs else { return }
        // Safety ceiling: never let the hold freeze the label even if the live clock never reaches
        // the target (GH #110).
        if seekHold.exceeded(maxSeconds: maxSeekHoldSeconds,
                             now: ProcessInfo.processInfo.systemUptime) {
            NSLog("PlaybackController: seek hold released by max-hold ceiling (target=%@)",
                  String(target))
            setSeeking(false)
            // The ceiling firing means the seek never landed. When the player still isn't
            // rendering — a starved transcoder can leave the rebuilt item reloading a
            // segment-less playlist forever, with no KVO transition, no item error, and no
            // stall watchdog (seen live: frozen chrome pinned at the target with zero
            // status) — escalate to the visible reconnect path: spinner now, and the
            // existing 20s reconnect watchdog converts a dead rebuild into the Retry/Close
            // overlay. A genuine recovery cancels it at the `.playing` transition.
            if player.timeControlStatus != .playing, !userWantsPaused, !playbackError.isFailed {
                recordPlaybackDiagnostic("playback.seek_hold_ceiling_escalated", fields: [
                    "target": .millisecondsBucket(target),
                ])
                beginReconnectStatus()
            }
            return
        }
        let secs = player.currentTime().seconds
        guard secs.isFinite, secs > 0 else { return }
        let liveMs = Int(secs * 1000)
        // Slack covers segment-boundary snapping on HLS reopens (the transcoder may start the
        // stream a beat before the exact target). Landing at/after target — or within slack
        // below it — means the rebuild reached the user's position.
        if liveMs >= target - 1500 {
            setSeeking(false)
        }
    }

    /// One-time resume target (ms) applied on the FIRST `start()` instead of the item's saved
    /// `viewOffset`. Set when the player view controller is REBUILT to recover from a wedged
    /// AVKit state after a failure (see `PlayerView`'s rebuild path): the fresh controller must
    /// resume at the live playhead we captured, not the stale on-disk offset.
    private var initialResumeMsOverride: Int? { plexSession?.initialResumeMsOverride }

    /// Best-effort current playhead (ms), used to rebuild the player after a failure without
    /// losing the user's position. Once playback has actually started, trust AVPlayer's live
    /// clock even when it is exactly zero — a failed/restarted HLS item can play from true 0:00
    /// while `pendingResumeMs` still contains the old resume/seek target, and the chrome must not
    /// stay pinned to that stale value.
    var currentResumeMs: Int {
        if let live = livePlaybackClockMs {
            rememberTrustworthyPlaybackPosition(live,
                                                cause: .currentResumeLive,
                                                allowsNearZero: false)
            noteResumeClockDesyncIfNeeded(liveMs: live)
            return live
        }
        // During an in-flight user seek the live clock is briefly invalid (item detached for a
        // reopen, or pre-prime); fall back to the seek target rather than the stale offset so the
        // scrubber/resume position never regresses to the OLD position (GH #110).
        if isSeeking, let seekHoldTargetMs { return seekHoldTargetMs }
        return pendingResumeMs ?? item.viewOffset ?? 0
    }

    /// AVPlayer's current clock when it is trustworthy for user-facing chrome. Before the first
    /// playback signal, a zero clock can just mean "the item has not primed yet", so the chrome may
    /// temporarily show the pending resume target. After `.playing` / observed playback, zero is a
    /// real clock value and must win over stale resume state.
    private var livePlaybackClockMs: Int? {
        guard let ms = rawPlayerClockMs else { return nil }
        let secs = Double(ms) / 1000.0
        if secs > 0 || hasObservedPlayback || currentTimeControlStatus == .playing {
            return ms
        }
        return nil
    }

    private var rawPlayerClockMs: Int? {
        let secs = player.currentTime().seconds
        guard secs.isFinite else { return nil }
        return max(0, Int((secs * 1000).rounded()))
    }

    private func setPendingResumeMs(_ ms: Int?,
                                    cause: PlaybackPositionCause,
                                    allowsNearZero: Bool = false) {
        let preservesExplicitNearZero = ms != nil
            && pendingResumeMs == ms
            && pendingResumeSample?.permitsNearZero == true
        pendingResumeSample = ms.map {
            PlaybackPositionSample(positionMs: $0,
                                   capturedAt: ProcessInfo.processInfo.systemUptime,
                                   cause: cause,
                                   permitsNearZero: allowsNearZero || preservesExplicitNearZero)
        }
    }

    private func rememberTrustworthyPlaybackPosition(_ ms: Int,
                                                     cause: PlaybackPositionCause,
                                                     allowsNearZero: Bool = false) {
        let clamped = max(0, ms)
        if clamped <= Self.transientZeroPlayheadThresholdMs,
           !allowsNearZero,
           isTransientZeroComparedToKnownPlayhead(clamped) {
            return
        }
        lastTrustworthyPlaybackSample = PlaybackPositionSample(
            positionMs: clamped,
            capturedAt: ProcessInfo.processInfo.systemUptime,
            cause: cause,
            permitsNearZero: allowsNearZero)
    }

    private func isTransientZeroComparedToKnownPlayhead(_ ms: Int) -> Bool {
        PlaybackPositionResolver.isTransientNearZero(
            ms,
            seekHold: seekHold,
            pending: pendingResumeSample,
            lastTrustworthy: lastTrustworthyPlaybackSample,
            savedOffsetMs: item.viewOffset)
    }

    private func shouldUseLivePlayheadForRestart(_ ms: Int) -> Bool {
        ms > Self.transientZeroPlayheadThresholdMs
            || !isTransientZeroComparedToKnownPlayhead(ms)
    }

    private func positionSnapshotDiagnosticFields(
        _ snapshot: PlaybackPositionSnapshot
    ) -> [String: DiagnosticFieldValue] {
        [
            "playhead_snapshot_source": .label(snapshot.selected.cause.diagnosticLabel),
            "raw_live_position": .millisecondsBucket(snapshot.rawLive?.positionMs),
            "pending_resume": .millisecondsBucket(snapshot.pending?.positionMs),
            "pending_resume_source": .label(snapshot.pending?.cause.diagnosticLabel),
            "last_trustworthy_position": .millisecondsBucket(snapshot.lastTrustworthy?.positionMs),
            "last_trustworthy_source": .label(snapshot.lastTrustworthy?.cause.diagnosticLabel),
            "transient_zero_suppressed": .bool(snapshot.suppressedTransientZero),
            "has_current_item": .bool(snapshot.hasCurrentItem),
            "item_preparation_in_progress": .bool(snapshot.itemPreparationInProgress),
            "time_control_status": .label(snapshot.timeControlStatusLabel),
        ]
    }

    /// Build one canonical restart snapshot from typed evidence captured on the same actor turn.
    private func playheadSnapshotForRestart(
        cause: PlaybackTransitionCause
    ) -> PlaybackPositionSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let rawLive = rawPlayerClockMs.map {
            PlaybackPositionSample(positionMs: $0,
                                   capturedAt: now,
                                   cause: .restartRawLive(cause))
        }
        let suppressedTransientZero = rawLive.map {
            $0.positionMs <= Self.transientZeroPlayheadThresholdMs
                && isTransientZeroComparedToKnownPlayhead($0.positionMs)
        } ?? false

        func snapshot(_ selected: PlaybackPositionSample) -> PlaybackPositionSnapshot {
            PlaybackPositionSnapshot(selected: selected,
                                     rawLive: rawLive,
                                     pending: pendingResumeSample,
                                     lastTrustworthy: lastTrustworthyPlaybackSample,
                                     suppressedTransientZero: suppressedTransientZero,
                                     hasCurrentItem: player.currentItem != nil,
                                     itemPreparationInProgress: itemPreparationInProgress,
                                     timeControlStatusLabel: Self.timeControlStatusLabel(player.timeControlStatus))
        }

        if let target = seekHold.target {
            let selected = PlaybackPositionSample(positionMs: target.positionMs,
                                                  capturedAt: now,
                                                  cause: .restartSeekHold(cause),
                                                  permitsNearZero: true)
            rememberTrustworthyPlaybackPosition(selected.positionMs,
                                                cause: selected.cause,
                                                allowsNearZero: true)
            return snapshot(selected)
        }

        if let rawLive, shouldUseLivePlayheadForRestart(rawLive.positionMs) {
            rememberTrustworthyPlaybackPosition(rawLive.positionMs,
                                                cause: rawLive.cause,
                                                allowsNearZero: false)
            return snapshot(rawLive)
        }

        if let fallback = PlaybackPositionResolver.bestKnownFallback(
            pending: pendingResumeSample,
            lastTrustworthy: lastTrustworthyPlaybackSample) {
            return snapshot(fallback)
        }

        let selected = PlaybackPositionSample(
            positionMs: item.viewOffset ?? 0,
            capturedAt: now,
            cause: item.viewOffset == nil ? .zeroDefault : .itemViewOffset)
        return snapshot(selected)
    }

    private func noteResumeClockDesyncIfNeeded(liveMs: Int) {
        guard !didLogResumeClockDesync,
              !isSeeking,
              (hasObservedPlayback || currentTimeControlStatus == .playing),
              let pending = pendingResumeMs,
              pending > 10_000,
              liveMs + 10_000 < pending else { return }
        didLogResumeClockDesync = true
        if isTransientZeroComparedToKnownPlayhead(liveMs) {
            recordPlaybackDiagnostic("playback.resume_clock_desync_suppressed", fields: [
                "live_position": .millisecondsBucket(liveMs),
                "pending_resume": .millisecondsBucket(pending),
                "last_trustworthy_position": .millisecondsBucket(lastTrustworthyPlaybackMs),
                "item_generation": .int(currentPlayerItemGeneration),
                "time_control_status": .label(Self.timeControlStatusLabel(player.timeControlStatus)),
            ])
            NSLog("PlaybackController: suppressing transient zero live clock (%dms) behind pending resume (%dms)",
                  liveMs, pending)
            return
        }
        recordPlaybackDiagnostic("playback.resume_clock_desync", fields: [
            "live_position": .millisecondsBucket(liveMs),
            "pending_resume": .millisecondsBucket(pending),
            "item_generation": .int(currentPlayerItemGeneration),
            "time_control_status": .label(Self.timeControlStatusLabel(player.timeControlStatus)),
        ])
        NSLog("PlaybackController: AVPlayer live clock (%dms) is behind pending resume (%dms); trusting live clock",
              liveMs, pending)
        setPendingResumeMs(liveMs, cause: .resumeClockDesyncLive)
        rememberTrustworthyPlaybackPosition(liveMs,
                                            cause: .resumeClockDesyncLive,
                                            allowsNearZero: false)
    }

    // MARK: - Zombie-playback detector (starved rebuild reporting `.playing`)

    /// Live-clock baseline for the zombie-playback check: last observed position (ms) and when
    /// it was recorded. A starved post-seek transcode can leave AVPlayer reporting `.playing`
    /// while it reloads a segment-less playlist forever (kFigAssetError_TrackNotFound ~1/s,
    /// seen live on iPad): the fake `.playing` transition cancels the stall watchdog, clears
    /// the buffering overlay, AND releases the seek hold (the item clock parks at the target),
    /// so every `.waiting`-keyed safety net goes dark. The 500ms scrubber tick polls this
    /// instead: `.playing` with a clock that hasn't advanced for `zombiePlaybackTimeoutSeconds`
    /// is not playback — escalate to the visible reconnect path (spinner now, Retry via the
    /// 20s reconnect watchdog). Genuine recovery cancels it at the next real `.playing`
    /// transition, and any clock advance re-seeds the baseline.
    private var zombieClockBaselineMs: Int?
    private var zombieClockBaselineAt: TimeInterval?
    private let zombiePlaybackTimeoutSeconds: TimeInterval = 8
    /// Minimum cumulative clock advance (ms) that counts as real progress. Cumulative, so slow
    /// playback rates still clear it across ticks; jitter on a parked clock stays below it.
    private let zombieClockAdvanceThresholdMs = 350

    /// Called from the 500ms scrubber tick alongside `releaseSeekHoldIfLanded`.
    func detectZombiePlaybackIfStuck() {
        guard player.timeControlStatus == .playing,
              !userWantsPaused, !transport.pauseRequested,
              !isSeeking,
              !playbackError.isFailed,
              player.rate > 0 else {
            zombieClockBaselineMs = nil
            zombieClockBaselineAt = nil
            return
        }
        let secs = player.currentTime().seconds
        guard secs.isFinite else { return }
        let nowMs = Int(secs * 1000)
        let now = ProcessInfo.processInfo.systemUptime
        guard let baseMs = zombieClockBaselineMs, let baseAt = zombieClockBaselineAt else {
            zombieClockBaselineMs = nowMs
            zombieClockBaselineAt = now
            return
        }
        if abs(nowMs - baseMs) > zombieClockAdvanceThresholdMs {
            zombieClockBaselineMs = nowMs
            zombieClockBaselineAt = now
            // The clock moving again after a zombie escalation IS the recovery: the player
            // never left `.playing`, so no KVO transition will fire to clear the overlay —
            // this tick is the only signal.
            if reconnectInProgress { finishReconnectStatus() }
            return
        }
        guard !reconnectInProgress, now - baseAt >= zombiePlaybackTimeoutSeconds else { return }
        recordPlaybackDiagnostic("playback.zombie_playback_detected", fields: [
            "position": .millisecondsBucket(nowMs),
            "stuck_seconds": .int(Int(now - baseAt)),
        ])
        NSLog("PlaybackController: .playing with frozen clock for %.0fs — escalating to reconnect",
              now - baseAt)
        beginReconnectStatus()
    }

    /// Whether this session is streaming (vs local file). Drives which menus the
    /// player surface offers (quality reload only makes sense for streaming).
    var isStreaming: Bool { sessionSource.kind == .plex }

    /// Whether this session can reopen its media stream at a new quality.
    /// Plex uses its universal-transcode start path; backend-resolved playback (Jellyfin/Emby)
    /// can provide a reopener closure without pretending to be a Plex timeline session.
    var supportsQualityReload: Bool { sessionSource.supportsStreamReopen }

    /// Whether the Audio tab should use backend/container metadata instead of AVFoundation's
    /// currently-loaded audible group. Plex and MediaBrowser backends expose alternate tracks in media
    /// metadata and require a stream reopen/rebuild to switch tracks; local downloads still use
    /// AVFoundation because the whole playable file is already on disk.
    var supportsMetadataAudioSelection: Bool { sessionSource.kind != .offline }

    private var seekStreamKind: RemoteSeekModePolicy.StreamKind {
        RemoteSeekModePolicy.streamKind(isLocalFile: sessionSource.kind == .offline,
                                        isPlexStreaming: isStreaming,
                                        isPlexVideoCopyLane: maxVideoBitrateKbps <= 0,
                                        hasRemoteStream: sessionSource.kind == .mediaBrowser,
                                        mediaBrowserPlayMethod: remotePlayMethod)
    }

    private var supportsSeekReprime: Bool {
        RemoteSeekModePolicy.supportsOutOfBufferReopen(streamKind: seekStreamKind)
    }

    /// Chapter markers for the current item, if Plex provided any. Empty when none —
    /// the player hides the Chapters menu in that case.
    ///
    /// Seeded from the launching item, but that copy often comes from a listing payload
    /// that omits chapters — `DetailView` backfills them with an async metadata refresh,
    /// and tapping Play can beat that round-trip (seen live as a missing Chapters tab).
    /// `loadChaptersIfNeeded()` makes the player independent of the caller's copy.
    ///
    /// NOTE: visionOS's AVKit does NOT expose `AVNavigationMarkersGroup` /
    /// `AVPlayerItem.navigationMarkerGroups` (tvOS/iOS only), so native scrubber chapter
    /// ticks are unavailable here; we surface chapters via the custom Chapters tab and
    /// seek the playhead directly.
    private(set) var chapters: [Chapter]

    /// Full-metadata copy backfilled by `loadChaptersIfNeeded()`. The launching item is
    /// often a listing copy that omits chapters AND `Media>Part>Stream` (the Audio tab's
    /// data source — live: "No audio track metadata" on a multi-track movie). Everything
    /// that mines part/stream metadata should prefer this over `item`.
    private var refreshedItem: MediaItem?

    /// Fetch full metadata (`includeChapters`/`includeMarkers`) when the launching item
    /// carried no chapters or no audio-stream metadata — see `chapters`/`refreshedItem`.
    /// Returns `true` when chapters or audio streams were newly populated so the control
    /// surface can re-install the info tabs. Also re-derives the Skip Intro/Credits
    /// ranges, which ride the same race.
    func loadChaptersIfNeeded() async -> Bool {
        let needChapters = chapters.isEmpty
        let needStreams = streamingPart?.audioStreams.isEmpty ?? true
        guard isStreaming, needChapters || needStreams, let server, let token else { return false }
        let browseSession = BackendSession(kind: .plex, baseURL: server, token: token)
        guard let service = try? PlexBrowseService(
            session: browseSession,
            identity: identity,
            client: client
        ), let full = try? await service.metadata(ratingKey: item.ratingKey) else { return false }
        refreshedItem = full
        if let markers = full.markers, !markers.isEmpty {
            skipRanges = Self.deriveSkipRanges(from: markers)
        }
        var updated = false
        if needChapters, let fetched = full.chapters, !fetched.isEmpty {
            chapters = fetched
            updated = true
        }
        if needStreams, streamingPart?.audioStreams.isEmpty == false {
            updated = true
        }
        return updated
    }

    /// Skippable intro/credits ranges derived from the item's Plex markers (#14), in
    /// SECONDS. Seeded from `item.markers` (markers don't change across a Quality reload
    /// of the same item), and re-derived by `loadChaptersIfNeeded()` when the launching
    /// item was a markerless listing copy. Commercial and `.other` markers are
    /// intentionally excluded — only intro/credits get a Skip button. `endSeconds` is the
    /// seek target when the user taps Skip.
    private struct SkipRange {
        let kind: SkipMarkerState.Kind
        let startSeconds: Double
        let endSeconds: Double
    }
    private lazy var skipRanges: [SkipRange] = Self.deriveSkipRanges(from: item.markers)

    /// Build the SECONDS-based skip ranges from raw Plex markers. Keeps only intro/credits
    /// with a valid `[start, end)` window; commercial/other are dropped (they don't get a
    /// Skip button per the feature spec).
    private static func deriveSkipRanges(from markers: [Marker]?) -> [SkipRange] {
        guard let markers else { return [] }
        return markers.compactMap { marker -> SkipRange? in
            let kind: SkipMarkerState.Kind
            switch marker.kind {
            case .intro: kind = .intro
            case .credits: kind = .credits
            case .commercial, .other: return nil
            }
            guard let startMs = marker.startTimeOffset,
                  let endMs = marker.endTimeOffset,
                  endMs > startMs else { return nil }
            return SkipRange(kind: kind,
                             startSeconds: Double(startMs) / 1000,
                             endSeconds: Double(endMs) / 1000)
        }
    }

    /// Tail (seconds) subtracted from a marker's end before we clear the button, so it
    /// doesn't flicker off exactly at the boundary while the playhead drifts across it.
    private let skipMarkerTailSeconds: Double = 1.0

    /// How often (seconds) the periodic time observer fires.
    private let timelineIntervalSeconds: Double = 10

    // MARK: - Init

    /// Construct one controller from exactly one typed playback authority.
    init(item: MediaItem,
         sessionSource: PlaybackSessionSource,
         identity: ClientIdentity,
         client: PlexClient,
         maxVideoBitrateKbps: Int = 8000,
         qualityDefaultsKey: String = PlaybackPreferences.Keys.legacyQualityKbps,
         mediaIndex: Int = 0,
         initialAudioStreamIndex: Int? = nil,
         initialSubtitleStreamIndex: Int? = nil,
         offlineSubtitleCueLoader: @escaping OfflineSubtitleCueLoader = OfflineSubtitleCueLoading.live,
         plexAudioStreamSelector: PlexAudioStreamSelector? = nil) {
        self.item = item
        self.sessionSource = sessionSource
        self.identity = identity
        self.client = client
        self.offlineSubtitleCueLoader = offlineSubtitleCueLoader
        self.plexAudioStreamSelector = plexAudioStreamSelector
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.userSelectedMaxVideoBitrateKbps = maxVideoBitrateKbps
        self.qualityDefaultsKey = qualityDefaultsKey
        // Offline playback already owns one concrete local file rather than a selectable Media.
        self.mediaIndex = sessionSource.kind == .offline ? 0 : mediaIndex
        self.chapters = item.chapters ?? []
        self.speedState.speed = self.playbackSpeed
        self.audioStreamIDOverride = initialAudioStreamIndex
        switch sessionSource.kind {
        case .mediaBrowser:
            self.subtitleSelectionOverride = BackendSubtitleSelection.mediaBrowserWireValue(
                initialSubtitleStreamIndex)
        case .plex:
            self.subtitleSelectionOverride = BackendSubtitleSelection.plexWireValue(
                initialSubtitleStreamIndex)
        case .offline:
            self.subtitleSelectionOverride = nil
        }
        // GH #196: MediaBrowser services enforce the same verdict on PlaybackInfo; retain it in
        // the controller so the first-frame watchdog and Stats decision describe that lane.
        if sessionSource.kind == .mediaBrowser,
           case .forceToneMapTranscode(let reason) = DolbyVisionGuard.verdict(for: item) {
            self.dvGuardReason = reason
        }
    }

    // MARK: - Lifecycle

    /// Begin playback. Safe to call once; subsequent calls are ignored.
    func start() {
        guard !started else { return }
        playbackGeneration += 1
        started = true
        let pathMode = sessionSource.pathMode
        playbackStartupSpan = PerformanceInstrumentation.begin(.playbackStartup,
                                                                backend: performanceBackendLabel,
                                                                fields: [
                                                                    "path_mode": pathMode,
                                                                    "resume": initialResumeMsOverride ?? item.viewOffset ?? 0,
                                                                    "quality_kbps": maxVideoBitrateKbps,
                                                                ])
        var fields: [String: DiagnosticFieldValue] = [
            "path_mode": .label(pathMode),
            "initial_resume": .millisecondsBucket(initialResumeMsOverride ?? item.viewOffset),
        ]
        fields.merge(sourceDiagnosticFields()) { _, new in new }
        recordPlaybackDiagnostic("playback.session_start", fields: fields)
        refreshVideoNowPlayingMetadata(
            elapsedMillisecondsOverride: initialResumeMsOverride ?? item.viewOffset,
            playbackRateOverride: 0)
        switch sessionSource {
        case .offline(let session):
            loadLocalFile(session.fileURL)
        case .mediaBrowser(let session):
            beginRemoteStream(session.initialStreamURL,
                              headers: session.httpHeaders,
                              resumeOffsetMs: item.viewOffset,
                              playMethod: session.playMethod)
        case .plex(let session):
            // Use the rebuild resume override on first start when present (recovering from a
            // wedged player); otherwise startStreaming falls back to the item's saved offset.
            // First start of this controller: no previous job under this sessionID to stop.
            beginStreaming(resumeOffsetMsOverride: session.initialResumeMsOverride,
                           stoppingPreviousTranscode: false)
        }
    }

    /// Tear down observers and report a final `stopped` timeline. Call from the
    /// view's `dismantle`.
    func stop() {
        // Invalidate callbacks before doing any final reporting. Observer removal cannot retract
        // a KVO/notification/time callback that has already queued its MainActor continuation.
        playbackGeneration += 1
        let terminalLiveClock = rawPlayerClockMs.map {
            PlaybackPositionSample(positionMs: $0,
                                   capturedAt: ProcessInfo.processInfo.systemUptime,
                                   cause: .currentResumeLive)
        }
        let terminalProgressMs = PlaybackPositionResolver.terminalPosition(
            live: terminalLiveClock,
            liveIsTrustworthy: terminalLiveClock.map {
                shouldUseLivePlayheadForRestart($0.positionMs)
            } ?? false,
            seekHold: seekHold,
            lastTrustworthy: lastTrustworthyPlaybackSample,
            savedOffsetMs: item.viewOffset)
        maybeRecordDiagnosticSnapshot(force: true)
        recordPlaybackDiagnostic("playback.session_stop", fields: [
            "resume": .millisecondsBucket(terminalProgressMs),
            "sent_transcode_stop": .bool(sentTranscodeStop),
        ])
        playbackItemLoadSpan?.end(result: "cancelled", fields: ["path_mode": performancePathMode])
        playbackItemLoadSpan = nil
        playbackStartupSpan?.end(result: "cancelled", fields: ["path_mode": performancePathMode])
        playbackStartupSpan = nil
        playbackTask?.cancel()
        playbackTask = nil
        setSeeking(false)
        endReconnectStatus()
        endItemPreparation()
        upNextTask?.cancel()
        upNextTask = nil
        if let proxy = remoteHLSProxy, let generation = remoteHLSProxyGeneration {
            Task { await proxy.stop(generation: generation) }
            remoteHLSProxy = nil
            remoteHLSProxyGeneration = nil
        }
        timeline.report(state: .stopped, force: true, positionMs: terminalProgressMs)
        recordLocalPlaybackPosition(terminalProgressMs)
        sendTranscodeStop()
        stopRemoteSessionIfNeeded()
        cancelPendingFinalTargetRebuild()
        if let activeFinalTargetRebuildGeneration {
            finalTargetRebuildPolicy.cancelRebuild(generation: activeFinalTargetRebuildGeneration)
            self.activeFinalTargetRebuildGeneration = nil
        }
        finalTargetRebuildPolicy.reset()
        stopVideoNowPlayingSession()
        player.pause()
        refreshVideoNowPlayingMetadata(elapsedMillisecondsOverride: terminalProgressMs,
                                       playbackRateOverride: 0)
        removeObservers()
        // Tear down the session/lifecycle observers (kept separate from the per-item
        // observers above) and release the audio session, notifying other apps so they can
        // resume (#17).
        audioSession.removeObservers()
        audioSession.deactivate()
    }

    private func recordLocalPlaybackPosition(_ positionMs: Int? = nil) {
        guard let localPlaybackProgress else { return }
        localPlaybackProgress(positionMs ?? currentResumeMs, item.duration)
    }

    private func stopRemoteSessionIfNeeded() {
        guard let session = mediaBrowserSession else { return }
        switch RemoteStreamLifecyclePolicy.finalSessionStopDecision(hasRemoteStream: true,
                                                                    didAlreadyStop: session.didStop) {
        case .stop:
            session.didStop = true
            session.onStop?()
        case .skip:
            return
        }
    }

    /// Whether the final `/video/:/transcode/universal/stop` was already fired, so
    /// repeated teardowns (dismantle + explicit stop paths) send it exactly once.
    private var sentTranscodeStop = false

    /// Best-effort: tell PMS to kill this session's transcode job. HLS gives the
    /// server no end-of-playback signal, so skipping this orphans a live FFmpeg
    /// process per close/rebuild until the inactivity reaper runs — observed live as
    /// a pile-up of open transcoder sessions on the server. Detached fire-and-forget:
    /// teardown must not block on (or fail with) the network.
    private func sendTranscodeStop() {
        guard isStreaming, !sentTranscodeStop, let server, let token else { return }
        sentTranscodeStop = true
        let req = TranscodeRequest.stop(server: server, token: token,
                                        identity: identity, sessionID: sessionID)
        let client = self.client
        Task.detached { try? await client.send(req) }
    }

    // MARK: - Subtitles (soft renditions)

    enum SubtitleTrackLoadError: LocalizedError {
        case playerNotReady
        case groupLoadFailed(Error)
        case selectionDidNotApply

        var errorDescription: String? {
            switch self {
            case .playerNotReady:
                "Subtitle tracks are still loading."
            case .groupLoadFailed:
                "Subtitle tracks could not be loaded."
            case .selectionDidNotApply:
                "The selected subtitle track could not be enabled."
            }
        }
    }

    /// Whether the Subtitles tab should fall back to backend/container metadata + a stream reopen
    /// instead of AVFoundation's legible group. Mirrors `supportsMetadataAudioSelection`, but scoped
    /// to backend-reopen sessions (Jellyfin/Emby): Emby's HLS transcode exposes no legible subtitle
    /// renditions, so the only way to show a subtitle is to reopen the stream with the chosen
    /// `SubtitleStreamIndex` (server burn-in). Jellyfin embeds soft renditions and so keeps using the
    /// instant AVFoundation path; this fallback only engages when the loaded asset has no legible
    /// group.
    var supportsMetadataSubtitleSelection: Bool { sessionSource.kind == .mediaBrowser }

    /// Load the current item's legible (subtitle/closed-caption) selection group and its
    /// options, plus which one is active. Returns `nil` for the group when the HLS carries
    /// no legible renditions at all (e.g. a source with no subtitles) so the Subtitles tab
    /// can show a graceful empty state.
    ///
    /// Async because `AVAsset.loadMediaSelectionGroup(for:)` is the modern, non-blocking
    /// accessor (the synchronous `mediaSelectionGroup(forMediaCharacteristic:)` is
    /// deprecated on visionOS).
    func loadSubtitleTracks() async throws -> PlaybackTrackSnapshot<PlaybackSubtitleTrack>? {
        if sessionSource.kind == .offline, !offlineTextSubtitles.isEmpty {
            return await loadOfflineSubtitleTracks()
        }
        if supportsMetadataSubtitleSelection {
            // Backend-resolved MediaBrowser streams (Jellyfin/Emby) need subtitle picks to be
            // carried into PlaybackInfo/HLS reopens as SubtitleStreamIndex. Keep this independent
            // of player.currentItem so the menu does not flash "No subtitle tracks" while a
            // subtitle pick rebuilds/swaps the AVPlayerItem.
            return loadMetadataSubtitleTracks()
        }

        // Plex HLS can expose a partial legible group (observed: only a nominal SDH
        // option that accepts selection but renders no cues) while source metadata has
        // the complete subtitle set. Prefer the authoritative Plex stream metadata
        // whenever available so every choice follows the proven PUT + HLS rebuild path.
        if let metadataTracks = loadPlexMetadataSubtitleTracks() {
            NSLog("LabstreamSubtitles: using Plex metadata optionCount=%d",
                  metadataTracks.tracks.count - 1)
            return metadataTracks
        }

        guard let playerItem = player.currentItem else {
            throw SubtitleTrackLoadError.playerNotReady
        }
        let asset = playerItem.asset
        let group: AVMediaSelectionGroup?
        do {
            group = try await asset.loadMediaSelectionGroup(for: .legible)
        } catch {
            NSLog("LabstreamSubtitles: group load failed itemStatus=%d error=%@",
                  playerItem.status.rawValue, String(describing: type(of: error)))
            throw SubtitleTrackLoadError.groupLoadFailed(error)
        }
        guard let group, !group.options.isEmpty else {
            if playerItem.status == .unknown {
                throw SubtitleTrackLoadError.playerNotReady
            }
            if let metadataTracks = loadPlexMetadataSubtitleTracks() {
                NSLog("LabstreamSubtitles: Plex HLS has no renditions; using metadata optionCount=%d",
                      metadataTracks.tracks.count - 1)
                return metadataTracks
            }
            NSLog("LabstreamSubtitles: group ready optionCount=0 itemStatus=%d", playerItem.status.rawValue)
            return nil
        }

        NSLog("LabstreamSubtitles: group ready optionCount=%d itemStatus=%d",
              group.options.count, playerItem.status.rawValue)

        // "Off" is always offered first. It maps to deselecting the group entirely.
        var tracks: [PlaybackSubtitleTrack] = [PlaybackSubtitleTrack(
            displayName: "Off",
            mechanism: .avFoundationOff)]
        // Build human-readable labels from each option, de-duplicating collisions (e.g. two
        // distinct "English" renditions) with a trailing index only when needed.
        var seenCounts: [String: Int] = [:]
        for (index, option) in group.options.enumerated() {
            var label = await Self.subtitleLabel(for: option)
            let priorCount = seenCounts[label, default: 0]
            seenCounts[label] = priorCount + 1
            if priorCount > 0 { label += " \(priorCount + 1)" }
            tracks.append(PlaybackSubtitleTrack(
                displayName: label,
                mechanism: .avFoundation(index: index, option: option)))
        }

        // Resolve the active selection so the tab can render a checkmark. A `nil`
        // selected option (or a group not currently selected) means the typed Off row.
        let current = playerItem.currentMediaSelection.selectedMediaOption(in: group)
        let selectedID: PlaybackSubtitleTrack.ID = current.flatMap { selected in
            group.options.firstIndex(of: selected).map(PlaybackSubtitleTrack.ID.avFoundation)
        } ?? .avFoundationOff

        return PlaybackTrackSnapshot(tracks: tracks, selectedID: selectedID)
    }

    private func loadOfflineSubtitleTracks() async -> PlaybackTrackSnapshot<PlaybackSubtitleTrack>? {
        var tracks: [PlaybackSubtitleTrack] = [PlaybackSubtitleTrack(
            displayName: "Off",
            mechanism: .offlineOff)]
        for track in offlineTextSubtitles {
            tracks.append(PlaybackSubtitleTrack(
                displayName: track.displayName,
                mechanism: .offlineSidecar(track)))
        }
        guard tracks.count > 1 else { return nil }
        let candidateID = selectedOfflineSubtitleTrackID.map(PlaybackSubtitleTrack.ID.offlineSidecar)
            ?? .offlineOff
        let selectedID = tracks.contains(where: { $0.id == candidateID }) ? candidateID : .offlineOff
        return PlaybackTrackSnapshot(tracks: tracks, selectedID: selectedID)
    }

    /// Parse one offline sidecar only when the viewer selects it. Opening the subtitle menu is now
    /// metadata-only even for titles with many feature-length SRT/VTT files.
    private func loadOfflineSubtitleCues(for track: OfflineTextSubtitleTrack) async throws {
        if offlineSubtitleCuesByTrackID[track.id] != nil { return }
        guard let base = offlineSubtitleBaseURL else {
            throw SubtitleTrackLoadError.selectionDidNotApply
        }
        let url = base.appendingPathComponent(track.relativePath)
        let cues = try await offlineSubtitleCueLoader(url)
        guard !cues.isEmpty else { throw SubtitleTrackLoadError.selectionDidNotApply }
        offlineSubtitleCuesByTrackID[track.id] = cues
    }

    private func updateOfflineSubtitleOverlay(at seconds: Double) {
        guard sessionSource.kind == .offline, let selectedOfflineSubtitleTrackID else {
            offlineSubtitleOverlay.set(nil)
            return
        }
        guard seconds.isFinite, let cues = offlineSubtitleCuesByTrackID[selectedOfflineSubtitleTrackID] else {
            offlineSubtitleOverlay.set(nil); return
        }
        let timeMs = Int(seconds * 1000)
        offlineSubtitleOverlay.set(Self.cueText(in: cues, at: timeMs))
    }

    /// Binary-search the sorted-by-startMs cue list for the one covering `timeMs`, instead of an
    /// O(n) scan on every periodic time-observer tick. Cues are non-overlapping in practice, so the
    /// rightmost cue whose `startMs <= timeMs` is the only candidate.
    private static func cueText(in cues: [OfflineTextSubtitleCue], at timeMs: Int) -> String? {
        var lo = 0, hi = cues.count - 1, candidate = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].startMs <= timeMs {
                candidate = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard candidate >= 0, cues[candidate].contains(timeMs) else { return nil }
        return cues[candidate].text
    }

    private func persistOfflineSubtitlePreference(for track: OfflineTextSubtitleTrack?) {
        let defaults = UserDefaults.standard
        guard let track else {
            defaults.set(true, forKey: SubtitlePrefKey.off)
            defaults.removeObject(forKey: SubtitlePrefKey.language)
            return
        }
        defaults.set(false, forKey: SubtitlePrefKey.off)
        if let language = track.language, !language.isEmpty {
            defaults.set(language, forKey: SubtitlePrefKey.language)
        }
    }

    /// Build the Subtitles tab from part metadata for backends whose HLS carries no legible group
    /// (Emby). Each row maps to a backend subtitle stream index; selecting one reopens the stream
    /// with that `SubtitleStreamIndex` so the server burns it in. The track id IS the stream index
    /// (always ≥ 0, distinct from the "Off" row's -1), so the UI checkmark and the reopen agree.
    /// Returns `nil` when metadata selection isn't supported or no subtitle streams exist, so the
    /// tab shows its graceful empty state.
    private func loadMetadataSubtitleTracks() -> PlaybackTrackSnapshot<PlaybackSubtitleTrack>? {
        guard supportsMetadataSubtitleSelection, let part = streamingPart else { return nil }
        let streams = part.subtitleStreams
        guard !streams.isEmpty else { return nil }

        // "Off" first. Carry Jellyfin's explicit off sentinel through the same backend-reopen
        // path as real subtitle streams; nil would mean "omit" and can inherit server defaults.
        var tracks: [PlaybackSubtitleTrack] = [PlaybackSubtitleTrack(
            displayName: "Off",
            mechanism: .mediaBrowserOff)]
        var seenCounts: [String: Int] = [:]
        for (index, stream) in streams.enumerated() {
            var label = stream.displayTitle
                ?? stream.extendedDisplayTitle
                ?? stream.language
                ?? "Subtitle \(index + 1)"
            if stream.forced == true, !label.lowercased().contains("forced") { label += " (Forced)" }
            let priorCount = seenCounts[label, default: 0]
            seenCounts[label] = priorCount + 1
            if priorCount > 0 { label += " \(priorCount + 1)" }
            tracks.append(PlaybackSubtitleTrack(
                displayName: label,
                mechanism: .mediaBrowserStream(stream.id)))
        }

        let selection = subtitleSelectionOverride
            ?? BackendSubtitleSelection.mediaBrowserWireValue(
                MediaBrowserPlaybackPreferencePolicy.preferredSubtitleStreamIndex(
                    for: item,
                    mediaIndex: mediaIndex))
            ?? .off
        let selectedID: PlaybackSubtitleTrack.ID = switch selection {
        case .off: .mediaBrowserOff
        case .stream(let streamIndex): .mediaBrowserStream(streamIndex)
        }
        let resolvedID = tracks.contains(where: { $0.id == selectedID }) ? selectedID : .mediaBrowserOff
        return PlaybackTrackSnapshot(tracks: tracks, selectedID: resolvedID)
    }

    /// Plex commonly emits no legible HLS renditions after the app explicitly clears its
    /// account-sticky part selection. The source metadata still carries the real subtitle
    /// streams, so expose those choices and rebuild after a pick instead of presenting an
    /// empty menu backed by an empty AVFoundation group.
    private func loadPlexMetadataSubtitleTracks() -> PlaybackTrackSnapshot<PlaybackSubtitleTrack>? {
        guard sessionSource.kind == .plex, let part = streamingPart else { return nil }
        let streams = part.subtitleStreams
        guard !streams.isEmpty else { return nil }

        var tracks: [PlaybackSubtitleTrack] = [PlaybackSubtitleTrack(
            displayName: "Off",
            mechanism: .plexOff)]
        var seenCounts: [String: Int] = [:]
        for (index, stream) in streams.enumerated() {
            var label = stream.displayTitle
                ?? stream.extendedDisplayTitle
                ?? stream.language
                ?? "Subtitle \(index + 1)"
            if stream.forced == true, !label.lowercased().contains("forced") { label += " (Forced)" }
            let priorCount = seenCounts[label, default: 0]
            seenCounts[label] = priorCount + 1
            if priorCount > 0 { label += " \(priorCount + 1)" }
            tracks.append(PlaybackSubtitleTrack(
                displayName: label,
                mechanism: .plexStream(stream.id)))
        }

        let selectedID: PlaybackSubtitleTrack.ID
        if let override = subtitleSelectionOverride {
            selectedID = switch override {
            case .off: .plexOff
            case .stream(let streamID): .plexStream(streamID)
            }
        } else {
            selectedID = streams.first(where: { $0.selected == true })
                .map { .plexStream($0.id) }
                ?? .plexOff
        }
        let resolvedID = tracks.contains(where: { $0.id == selectedID }) ? selectedID : .plexOff
        return PlaybackTrackSnapshot(tracks: tracks, selectedID: resolvedID)
    }

    /// Derive a human-readable label for a legible `AVMediaSelectionOption`.
    ///
    /// Name resolution (first non-empty wins):
    ///   1. The option's locale language → `Locale.current.localizedString(...)`. We try the
    ///      `extendedLanguageTag` identifier first (handles region/script tags like
    ///      `es-419`), then the bare language code.
    ///   2. `option.displayName` (AVFoundation's own label; often just "CC").
    ///   3. The option's `.commonMetadataTitle` value.
    ///   4. "Unknown".
    ///
    /// Then appends accessibility/forced qualifiers: " (Forced)" for forced-only subtitles
    /// and " (SDH)" for SDH/CC (spoken-dialog or music-and-sound description) tracks.
    ///
    /// `@MainActor` because it touches a non-`Sendable` `AVMediaSelectionOption`.
    static func subtitleLabel(for option: AVMediaSelectionOption) async -> String {
        var name = ""

        if let tag = option.extendedLanguageTag,
           let localized = Locale.current.localizedString(forIdentifier: tag),
           !localized.isEmpty {
            name = localized
        } else if let code = option.locale?.language.languageCode?.identifier,
                  let localized = Locale.current.localizedString(forLanguageCode: code),
                  !localized.isEmpty {
            name = localized
        }

        if name.isEmpty, !option.displayName.isEmpty {
            name = option.displayName
        }
        if name.isEmpty {
            let titles = AVMetadataItem.metadataItems(from: option.commonMetadata,
                                                      withKey: AVMetadataKey.commonKeyTitle,
                                                      keySpace: .common)
            if let title = try? await titles.first?.load(.stringValue), !title.isEmpty {
                name = title
            }
        }
        if name.isEmpty { name = "Unknown" }

        if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
            name += " (Forced)"
        } else if option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                    || option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) {
            name += " (SDH)"
        }

        return name
    }

    /// Persist the user's subtitle choice so it can be reapplied to a later item. Storing the
    /// chosen track's language code (or the "Off" flag) — NOT the option itself, which is
    /// non-`Sendable` and item-specific. Called from the Subtitles tab via `selectSubtitle`.
    private func persistSubtitlePreference(for option: AVMediaSelectionOption?) {
        let defaults = UserDefaults.standard
        guard let option else {
            // User picked "Off": remember that and clear any language preference.
            defaults.set(true, forKey: SubtitlePrefKey.off)
            defaults.removeObject(forKey: SubtitlePrefKey.language)
            return
        }
        defaults.set(false, forKey: SubtitlePrefKey.off)
        let code = option.extendedLanguageTag
            ?? option.locale?.language.languageCode?.identifier
        if let code, !code.isEmpty {
            defaults.set(code, forKey: SubtitlePrefKey.language)
        } else {
            defaults.removeObject(forKey: SubtitlePrefKey.language)
        }
    }

    /// Apply the subtitle preference to the current item's legible group, once per item
    /// (gated by `didApplySavedSubtitle`). The default is an explicit DESELECT: the HLS
    /// default selection must never stand on its own, because AVFoundation auto-selects
    /// DEFAULT/AUTOSELECT renditions per system caption settings while the picker computes
    /// "Off" — the "subtitles show while Off" bug. A track is selected only when an
    /// auto-select mode applies and a legible option matches the saved language.
    ///
    /// Invoked on `.readyToPlay`; stays on the @MainActor since it reads the non-`Sendable`
    /// `AVMediaSelectionOption`s.
    private func applySavedSubtitlePreferenceIfNeeded(playerItem: AVPlayerItem,
                                                       itemGeneration: Int,
                                                       observedPlaybackGeneration: Int) async {
        guard !didApplySavedSubtitle else { return }
        let defaults = UserDefaults.standard
        let wantsOff = defaults.bool(forKey: SubtitlePrefKey.off)
        let savedLang = defaults.string(forKey: SubtitlePrefKey.language)
        let mode = SubtitleAutoSelectMode(rawValue: defaults.string(forKey: PlaybackPreferences.Keys.subtitleAutoSelectMode) ?? "")
            ?? .manual

        // Load the legible group once. If the HLS carries no legible renditions, there's
        // nothing to apply on this item — mark applied so we don't re-probe each readyToPlay.
        let loadedGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible)
        guard isCurrentObservedItem(playerItem,
                                    itemGeneration: itemGeneration,
                                    observedPlaybackGeneration: observedPlaybackGeneration) else { return }
        guard let group = loadedGroup, !group.options.isEmpty else {
            didApplySavedSubtitle = true
            return
        }

        // Off unless an auto-select mode picks a matching track (mirrors
        // MediaBrowserPlaybackPreferencePolicy.preferredSubtitleStreamIndex).
        var selection: AVMediaSelectionOption?
        if !wantsOff, mode != .manual,
           let saved = savedLang, !saved.isEmpty,
           mode == .always || sourceAudioIsForeign(toPreferredLanguage: defaults) {
            selection = group.options.first { option in
                option.extendedLanguageTag == saved
                    || option.locale?.language.languageCode?.identifier == saved
            }
        }
        playerItem.select(selection, in: group)
        didApplySavedSubtitle = true
    }

    /// Apply a subtitle selection chosen in the Subtitles tab. Passing a track whose
    /// `option` is `nil` (the "Off" row) deselects the legible group. This is a soft
    /// switch on the live `AVPlayerItem` — no reload, no playhead snapshot needed.
    func selectSubtitle(_ track: PlaybackSubtitleTrack) async throws {
        switch track.mechanism {
        case .offlineOff:
            _ = offlineSubtitleSelectionAuthority.begin(trackID: nil)
            selectedOfflineSubtitleTrackID = nil
            persistOfflineSubtitlePreference(for: nil)
            updateOfflineSubtitleOverlay(at: player.currentTime().seconds)

        case .offlineSidecar(let offlineTrack):
            let token = offlineSubtitleSelectionAuthority.begin(trackID: offlineTrack.id)
            do {
                try await loadOfflineSubtitleCues(for: offlineTrack)
            } catch {
                guard offlineSubtitleSelectionAuthority.accepts(
                    token,
                    isCancelled: Task.isCancelled) else { return }
                throw error
            }
            guard offlineSubtitleSelectionAuthority.accepts(token,
                                                             isCancelled: Task.isCancelled) else {
                return
            }
            selectedOfflineSubtitleTrackID = offlineTrack.id
            persistOfflineSubtitlePreference(for: offlineTrack)
            updateOfflineSubtitleOverlay(at: player.currentTime().seconds)

        case .plexOff, .plexStream:
            guard sessionSource.kind == .plex else { return }
            let selection: BackendSubtitleSelection
            switch track.mechanism {
            case .plexOff: selection = .off
            case .plexStream(let streamID): selection = .stream(streamID)
            default: return
            }
            subtitleSelectionOverride = selection
            persistMetadataSubtitlePreference(selection)
            didApplySavedSubtitle = true
            NSLog("LabstreamSubtitles: Plex metadata selection requested streamID=%d",
                  selection.plexWireValue)
            let resumeMs = playheadSnapshotForRestart(cause: .plexSubtitleReload).positionMs
            restartAtCurrentPosition(offsetMs: resumeMs,
                                     bitrateKbps: maxVideoBitrateKbps,
                                     intent: .subtitleTrackChange)

        case .mediaBrowserOff, .mediaBrowserStream:
            guard sessionSource.kind == .mediaBrowser else { return }
            let selection: BackendSubtitleSelection
            switch track.mechanism {
            case .mediaBrowserOff: selection = .off
            case .mediaBrowserStream(let streamIndex): selection = .stream(streamIndex)
            default: return
            }
            if selection == subtitleSelectionOverride {
                persistMetadataSubtitlePreference(selection)
                didApplySavedSubtitle = true
                return
            }
            if let playerItem = player.currentItem,
               let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible),
               !group.options.isEmpty {
                playerItem.select(nil, in: group)
            }
            subtitleSelectionOverride = selection
            persistMetadataSubtitlePreference(selection)
            didApplySavedSubtitle = true
            let resumeMs = playheadSnapshotForRestart(cause: .subtitleReload).positionMs
            restartAtCurrentPosition(offsetMs: resumeMs,
                                     bitrateKbps: maxVideoBitrateKbps,
                                     intent: .subtitleTrackChange)

        case .avFoundationOff, .avFoundation:
            guard let playerItem = player.currentItem else {
                throw SubtitleTrackLoadError.playerNotReady
            }
            guard let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible),
                  !group.options.isEmpty else {
                throw SubtitleTrackLoadError.playerNotReady
            }
            let requestedOption: AVMediaSelectionOption? = switch track.mechanism {
            case .avFoundationOff: nil
            case .avFoundation(_, let option): option
            default: nil
            }
            playerItem.select(requestedOption, in: group)
            let applied = playerItem.currentMediaSelection.selectedMediaOption(in: group)
            guard applied == requestedOption else {
                NSLog("LabstreamSubtitles: selection did not apply optionCount=%d", group.options.count)
                throw SubtitleTrackLoadError.selectionDidNotApply
            }
            persistSubtitlePreference(for: requestedOption)
            didApplySavedSubtitle = true
        }
    }

    /// Persist a metadata-driven selection without exposing backend off sentinels to the picker.
    private func persistMetadataSubtitlePreference(_ selection: BackendSubtitleSelection) {
        let defaults = UserDefaults.standard
        guard case .stream(let streamIndex) = selection,
              let stream = streamingPart?.subtitleStreams.first(where: { $0.id == streamIndex }) else {
            defaults.set(true, forKey: SubtitlePrefKey.off)
            defaults.removeObject(forKey: SubtitlePrefKey.language)
            return
        }
        defaults.set(false, forKey: SubtitlePrefKey.off)
        if let lang = stream.languageTag ?? stream.language, !lang.isEmpty {
            defaults.set(lang, forKey: SubtitlePrefKey.language)
        }
    }

    // MARK: - Audio (soundtrack / language)

    /// Load the current item's audible (soundtrack) selection group and its options, plus which
    /// one is active. Returns `nil` for the group when the HLS carries fewer than two audible
    /// renditions — with nothing to choose between, the Audio tab shows a graceful empty state
    /// rather than a pointless one-row list.
    ///
    /// Async because `AVAsset.loadMediaSelectionGroup(for:)` is the modern, non-blocking accessor
    /// (the synchronous `mediaSelectionGroup(forMediaCharacteristic:)` is deprecated on visionOS).
    func loadAudioTracks() async -> PlaybackTrackSnapshot<PlaybackAudioTrack>? {
        guard let playerItem = player.currentItem else { return nil }
        let asset = playerItem.asset
        guard let group = try? await asset.loadMediaSelectionGroup(for: .audible),
              group.options.count > 1 else {
            return nil
        }

        // Build human-readable labels, de-duplicating collisions (e.g. two distinct "English"
        // renditions) with a trailing index only when needed — mirrors `loadSubtitleTracks`.
        var tracks: [PlaybackAudioTrack] = []
        var seenCounts: [String: Int] = [:]
        for (index, option) in group.options.enumerated() {
            var label = await Self.audioLabel(for: option)
            let priorCount = seenCounts[label, default: 0]
            seenCounts[label] = priorCount + 1
            if priorCount > 0 { label += " \(priorCount + 1)" }
            tracks.append(PlaybackAudioTrack(
                displayName: label,
                mechanism: .avFoundation(index: index, option: option)))
        }

        // Resolve the active selection so the tab can render a checkmark. Audio is never "off";
        // if AVFoundation reports no explicit selection yet, fall back to the first option.
        let current = playerItem.currentMediaSelection.selectedMediaOption(in: group)
        let selectedID = PlaybackAudioTrack.ID.avFoundation(current.flatMap { selected in
            group.options.firstIndex(of: selected)
        } ?? 0)

        return PlaybackTrackSnapshot(tracks: tracks, selectedID: selectedID)
    }

    /// Derive a human-readable label for an audible `AVMediaSelectionOption`.
    ///
    /// Name resolution mirrors `subtitleLabel(for:)` (first non-empty wins): the option's locale
    /// language, then `option.displayName`, then its `.commonMetadataTitle`, then "Unknown".
    /// Appends " (AD)" for an audio-description track (spoken narration of on-screen action for
    /// accessibility). The Forced/SDH qualifiers are subtitle-specific and intentionally omitted.
    ///
    /// `@MainActor` because it touches a non-`Sendable` `AVMediaSelectionOption`.
    static func audioLabel(for option: AVMediaSelectionOption) async -> String {
        var name = ""

        if let tag = option.extendedLanguageTag,
           let localized = Locale.current.localizedString(forIdentifier: tag),
           !localized.isEmpty {
            name = localized
        } else if let code = option.locale?.language.languageCode?.identifier,
                  let localized = Locale.current.localizedString(forLanguageCode: code),
                  !localized.isEmpty {
            name = localized
        }

        if name.isEmpty, !option.displayName.isEmpty {
            name = option.displayName
        }
        if name.isEmpty {
            let titles = AVMetadataItem.metadataItems(from: option.commonMetadata,
                                                      withKey: AVMetadataKey.commonKeyTitle,
                                                      keySpace: .common)
            if let title = try? await titles.first?.load(.stringValue), !title.isEmpty {
                name = title
            }
        }
        if name.isEmpty { name = "Unknown" }

        if option.hasMediaCharacteristic(.describesVideoForAccessibility) {
            name += " (AD)"
        }

        return name
    }

    /// Persist the user's audio-language choice so it can be reapplied to a later item. Stores the
    /// chosen track's language code — NOT the option itself (non-`Sendable`, item-specific).
    /// Called from the Audio tab via `selectAudio`. Unlike subtitles there is no "Off" state.
    private func persistAudioPreference(for option: AVMediaSelectionOption) {
        // Normalize to the base two-letter code the Settings picker uses as its ids —
        // storing e.g. a raw "en-US" tag plays back fine but desyncs the Settings checkmark.
        let code = MediaBrowserPlaybackPreferencePolicy.persistableLanguageCode(
            languageTag: option.extendedLanguageTag,
            languageCode: option.locale?.language.languageCode?.identifier)
        let defaults = UserDefaults.standard
        if let code {
            defaults.set(code, forKey: AudioPrefKey.language)
        } else {
            defaults.removeObject(forKey: AudioPrefKey.language)
        }
    }

    /// Auto-apply the persisted audio-language preference to the current item's audible group,
    /// once per item (gated by `didApplyAudioPreference`). Selects the first audible option whose
    /// language matches the saved code; no-op when nothing is saved or no match exists (the HLS
    /// default soundtrack stands). Invoked on `.readyToPlay`; stays on the @MainActor since it
    /// reads the non-`Sendable` `AVMediaSelectionOption`s.
    private func applySavedAudioPreferenceIfNeeded(playerItem: AVPlayerItem,
                                                    itemGeneration: Int,
                                                    observedPlaybackGeneration: Int) async {
        guard !didApplyAudioPreference else { return }
        let savedLang = UserDefaults.standard.string(forKey: AudioPrefKey.language)
        // No preference saved: leave the HLS default and don't burn the one-shot gate yet, so a
        // future pick starts fresh.
        guard let savedLang, !savedLang.isEmpty else { return }

        // Load the audible group once. If the HLS carries no audible renditions there's nothing
        // to apply on this item — mark applied so we don't re-probe each readyToPlay.
        let loadedGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible)
        guard isCurrentObservedItem(playerItem,
                                    itemGeneration: itemGeneration,
                                    observedPlaybackGeneration: observedPlaybackGeneration) else { return }
        guard let group = loadedGroup, !group.options.isEmpty else {
            didApplyAudioPreference = true
            return
        }

        // Select the first audible option whose language matches the saved code. No match →
        // leave the HLS default selection in place.
        let match = group.options.first { option in
            option.extendedLanguageTag == savedLang
                || option.locale?.language.languageCode?.identifier == savedLang
        }
        if let match {
            playerItem.select(match, in: group)
        }
        didApplyAudioPreference = true
    }

    /// Whether the current preferences resolve to "no subtitles" for a newly built stream.
    /// Delegates to the shared preference policy so Plex's part-level deselect, the picker's
    /// Off row, and the Emby/Jellyfin `-1` wire sentinel all share ONE semantic: explicit Off
    /// and manual mode ("Subtitles stay off until selected in the player") mean off; the
    /// auto-select modes mean off only when no stream matches the saved language.
    private func subtitlesOffForNewStream() -> Bool {
        BackendSubtitleSelection.mediaBrowserWireValue(
            MediaBrowserPlaybackPreferencePolicy.preferredSubtitleStreamIndex(
                for: item,
                mediaIndex: mediaIndex)) == .off
    }

    private func selectedBurnSubtitleStreamIDForCurrentPreferences() -> Int? {
        let defaults = UserDefaults.standard
        let burnMode = SubtitleBurnMode(rawValue: defaults.string(forKey: PlaybackPreferences.Keys.subtitleBurnMode) ?? "")
            ?? .automatic
        guard burnMode != .automatic else { return nil }

        let autoMode = SubtitleAutoSelectMode(rawValue: defaults.string(forKey: PlaybackPreferences.Keys.subtitleAutoSelectMode) ?? "")
            ?? .manual
        guard autoMode != .manual else { return nil }
        if autoMode == .foreignAudio && !sourceAudioIsForeign(toPreferredLanguage: defaults) {
            return nil
        }

        guard let part = sourcePartForCurrentMedia(),
              !part.subtitleStreams.isEmpty else {
            return nil
        }

        let preferredSubtitle = defaults.string(forKey: SubtitlePrefKey.language)
        let stream = preferredSubtitle.flatMap { preferred in
            part.subtitleStreams.first { Self.languageMatches(languageTag: $0.languageTag,
                                                              languageCode: $0.languageCode,
                                                              language: $0.language,
                                                              preferredLanguage: preferred) }
        } ?? (burnMode == .always ? part.subtitleStreams.first : nil)
        guard let stream else { return nil }

        switch burnMode {
        case .automatic:
            return nil
        case .imageFormatsOnly:
            return Self.isImageSubtitleCodec(stream.codec) ? stream.id : nil
        case .always:
            return stream.id
        }
    }

    private func sourceAudioIsForeign(toPreferredLanguage defaults: UserDefaults) -> Bool {
        guard let part = sourcePartForCurrentMedia() else { return false }
        return MediaBrowserPlaybackPreferencePolicy.sourceAudioIsForeign(part: part,
                                                                         defaults: defaults)
    }

    private func effectiveRemoteAudioStreamIndex() -> Int? {
        audioStreamIDOverride
            ?? MediaBrowserPlaybackPreferencePolicy.initialAudioStreamIndex(for: item,
                                                                           mediaIndex: mediaIndex)
    }

    private func effectiveRemoteSubtitleStreamIndex() -> Int? {
        subtitleSelectionOverride?.mediaBrowserWireValue
            ?? MediaBrowserPlaybackPreferencePolicy.preferredSubtitleStreamIndex(for: item,
                                                                                 mediaIndex: mediaIndex)
    }

    private func sourcePartForCurrentMedia() -> Part? {
        let media = item.media.flatMap { mediaItems -> Media? in
            if mediaItems.indices.contains(mediaIndex) { return mediaItems[mediaIndex] }
            return mediaItems.first
        }
        return media?.part.first
    }

    private static func isImageSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return codec.contains("pgs")
            || codec.contains("vobsub")
            || codec.contains("dvd")
            || codec.contains("hdmv")
            || codec.contains("image")
    }

    /// Delegates to the shared preference policy — the matching/normalization logic (and its
    /// ISO-639 table) was previously duplicated here verbatim and had to be fixed twice.
    private static func languageMatches(languageTag: String?,
                                        languageCode: String?,
                                        language: String?,
                                        preferredLanguage: String) -> Bool {
        MediaBrowserPlaybackPreferencePolicy.languageMatches(languageTag: languageTag,
                                                             languageCode: languageCode,
                                                             language: language,
                                                             preferredLanguage: preferredLanguage)
    }

    /// Apply an audio selection chosen in the Audio tab. A soft switch on the live `AVPlayerItem`
    /// — no reload. Persists the choice (language code) so it's reapplied to the next item, and
    /// marks the auto-select gate spent so a later readyToPlay won't override this manual pick.
    func selectAudio(_ track: PlaybackAudioTrack) async {
        guard case .avFoundation(_, let option) = track.mechanism else { return }
        guard let playerItem = player.currentItem else { return }
        guard let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible) else {
            return
        }
        playerItem.select(option, in: group)
        persistAudioPreference(for: option)
        didApplyAudioPreference = true
    }

    // MARK: - Audio (metadata-driven, streaming) — GH #3

    /// A selectable audio track sourced from Plex part metadata (`Stream`, streamType=2).
    ///
    /// Streaming sessions can't use the AVMediaSelection path above: PMS muxes only the
    /// part's *selected* audio track into the HLS transcode, so the audible group never
    /// lists alternates. The real track list lives in the item's metadata, and switching
    /// means PUTting the new `audioStreamID` on the part and rebuilding the transcode.
    /// The media part backing this streaming session (the one `startStreaming` transcodes:
    /// `mediaIndex` + partIndex 0). `nil` when the item metadata carries no Media/Part.
    /// Prefers the backfilled `refreshedItem`: listing copies omit `Stream` children, so
    /// the launching item's part often has no audio metadata (the play-vs-metadata race).
    private var streamingPart: Part? {
        let source = refreshedItem ?? item
        guard let media = source.media, media.indices.contains(mediaIndex) else { return nil }
        return media[mediaIndex].part.first
    }

    /// After a successful metadata-driven audio switch, the locally-known active stream id.
    /// For Plex this is `Stream.id` (sent to the part-selection endpoint); for Jellyfin-backed
    /// items our adapter maps it to `MediaStream.Index` (sent back through PlaybackInfo as
    /// `AudioStreamIndex`). The item snapshot's `selected` flags are stale after a switch, so
    /// the loader prefers this override when rebuilding the checkmarked list.
    private var audioStreamIDOverride: Int?

    /// Reserved for the same backend-reopen path as audio once subtitle metadata selection is
    /// promoted beyond AVFoundation's currently-loaded legible group. Keeping the request shape
    /// shared now prevents another one-off Jellyfin closure later.
    private var subtitleSelectionOverride: BackendSubtitleSelection?

    /// Build the Audio tab's track list from part metadata. Synchronous — pure reads of the
    /// decoded item. Returns an empty array when the metadata carries no audio streams (the
    /// tab then falls back to its empty state).
    func loadAudioStreamChoices() -> PlaybackTrackSnapshot<PlaybackAudioTrack>? {
        guard let part = streamingPart else { return nil }
        let streams = part.audioStreams
        guard !streams.isEmpty else { return nil }

        // Active track: a live override from a switch this session, else the exact policy used
        // for the initial remote open (preferred language, selected, default, then first). Keeping
        // this shared prevents the checkmark from describing a different stream than PlaybackInfo.
        let candidateSelectedID = audioStreamIDOverride
            ?? MediaBrowserPlaybackPreferencePolicy.initialAudioStreamIndex(for: item,
                                                                            mediaIndex: mediaIndex)
        guard let selectedID = PlaybackTrackSelectionPolicy.resolvedMetadataAudioStreamID(
            candidate: candidateSelectedID,
            streams: streams) else { return nil }

        // Label preference: displayTitle ("English (AAC Stereo)") is PMS's purpose-built
        // short label; fall back through the longer/raw fields, then a positional name.
        var choices: [PlaybackAudioTrack] = []
        var seenCounts: [String: Int] = [:]
        for (index, stream) in streams.enumerated() {
            var label = stream.displayTitle
                ?? stream.extendedDisplayTitle
                ?? stream.language
                ?? "Track \(index + 1)"
            let priorCount = seenCounts[label, default: 0]
            seenCounts[label] = priorCount + 1
            if priorCount > 0 { label += " \(priorCount + 1)" }
            let mechanism: PlaybackAudioTrack.Mechanism
            switch sessionSource.kind {
            case .plex: mechanism = .plexStream(stream.id)
            case .mediaBrowser: mechanism = .mediaBrowserStream(stream.id)
            case .offline: return nil
            }
            choices.append(PlaybackAudioTrack(displayName: label, mechanism: mechanism))
        }
        let selectedTrackID: PlaybackAudioTrack.ID
        switch sessionSource.kind {
        case .plex: selectedTrackID = .plexStream(selectedID)
        case .mediaBrowser: selectedTrackID = .mediaBrowserStream(selectedID)
        case .offline: return nil
        }
        return PlaybackTrackSnapshot(tracks: choices, selectedID: selectedTrackID)
    }

    /// Switch the active audio track for a streaming session: persist the selection on the
    /// part server-side, then rebuild the transcode at the live playhead (same mechanics as
    /// the Quality reload — PMS can't swap audio mid-session, so the stream must restart).
    /// Also persists the language preference so the next item auto-selects it.
    private enum MetadataAudioServerMutationResult {
        case applied
        case superseded
        case failed(String)
    }

    func selectAudioStream(_ choice: PlaybackAudioTrack) async {
        guard supportsMetadataAudioSelection, let part = streamingPart else { return }
        let streamID: Int
        switch choice.mechanism {
        case .plexStream(let id) where sessionSource.kind == .plex: streamID = id
        case .mediaBrowserStream(let index) where sessionSource.kind == .mediaBrowser: streamID = index
        default: return
        }
        guard streamID != audioStreamIDOverride else { return }
        let selectionToken = metadataAudioSelectionAuthority.begin(streamID: streamID)

        if isStreaming, let server, let token {
            let predecessor = metadataAudioSelectionTail
            let mutation = Task { @MainActor [weak self] () -> MetadataAudioServerMutationResult in
                await predecessor?.value
                guard let self,
                      self.metadataAudioSelectionAuthority.accepts(
                        selectionToken,
                        isCancelled: false) else {
                    return .superseded
                }
                do {
                    if let plexAudioStreamSelector = self.plexAudioStreamSelector {
                        try await plexAudioStreamSelector(part.id, streamID)
                    } else {
                        let request = StreamSelectionRequest.selectAudioStream(
                            server: server,
                            token: token,
                            identity: self.identity,
                            partID: part.id,
                            audioStreamID: streamID)
                        try await self.client.send(request)
                    }
                } catch {
                    guard self.metadataAudioSelectionAuthority.accepts(
                        selectionToken,
                        isCancelled: false) else {
                        return .superseded
                    }
                    return .failed(Self.safeErrorSummary(error))
                }
                guard self.metadataAudioSelectionAuthority.accepts(
                    selectionToken,
                    isCancelled: false) else {
                    return .superseded
                }
                return .applied
            }
            metadataAudioSelectionTail = Task { @MainActor in
                _ = await mutation.value
            }
            switch await mutation.value {
            case .applied:
                break
            case .superseded:
                return
            case .failed(let summary):
                NSLog("PlaybackController: audio stream selection failed: %@", summary)
                return
            }
        }
        guard metadataAudioSelectionAuthority.accepts(selectionToken,
                                                       isCancelled: false) else {
            return
        }

        audioStreamIDOverride = streamID
        // Persist a normalized code, never the display name ("English") — the Settings picker
        // matches the stored string against its two-letter ids.
        if let stream = part.audioStreams.first(where: { $0.id == streamID }),
           let lang = MediaBrowserPlaybackPreferencePolicy.persistableLanguageCode(
               languageTag: stream.languageTag, languageCode: stream.languageCode) {
            UserDefaults.standard.set(lang, forKey: AudioPrefKey.language)
        }

        // Restart/reopen where the viewer is — same UX as Quality reload. Plex persists the
        // stream selection above; Jellyfin carries the stream index in the reopen request.
        let resumeMs = playheadSnapshotForRestart(cause: .audioReload).positionMs
        restartAtCurrentPosition(offsetMs: resumeMs,
                                 bitrateKbps: maxVideoBitrateKbps,
                                 intent: .audioTrackChange)
    }

    // MARK: - Playback speed (R5)

    /// Apply a new playback rate chosen in the Speed info tab. Persists the choice (so it
    /// survives relaunch and is reapplied to a later item) and applies it to the live player:
    /// `defaultRate` makes a subsequent play() resume at the chosen speed (rather than 1.0×),
    /// and we also set the live `rate` if currently playing so the change is immediate. Setting
    /// `rate` on a paused player would start playback, so we only touch `rate` when already
    /// playing — the stored `defaultRate` carries the speed forward when the user next plays.
    func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
        speedState.speed = speed
        applyPlaybackSpeed()
        refreshVideoNowPlayingMetadata()
    }

    /// Push the persisted/chosen speed onto the live `AVPlayer`. Always sets `defaultRate`
    /// (so a future play() resumes at the chosen speed); only sets the live `rate` when the
    /// player is currently playing, so we never inadvertently start a paused player. Called on
    /// each item's `.readyToPlay` so a Quality reload (which swaps the item and resets the rate
    /// to 1.0) re-applies the user's choice once the new item is ready.
    private func applyPlaybackSpeed() {
        let speed = playbackSpeed
        player.defaultRate = speed
        if player.timeControlStatus != .paused, !userWantsPaused {
            player.rate = speed
        }
    }

    // MARK: - User transport intent (#40)

    /// Toggle play/pause through the controller instead of talking directly to `AVPlayer`.
    ///
    /// This preserves a pause request made while the item is still loading/priming and makes the
    /// chrome switch to Play immediately, even before AVPlayer reports `.paused`.
    func togglePlayback() {
        if transport.showsPausedControl {
            requestPlay()
        } else {
            requestPause()
        }
    }

    func requestPause() {
        userWantsPaused = true
        player.pause()
        buffering.set(false)
        transport.setPauseRequested(true)
        updateTransportStatus()
        timeline.report(state: .paused, force: true)
        recordPlaybackDiagnostic("playback.pause_requested", fields: [
            "status": .label(Self.timeControlStatusLabel(player.timeControlStatus)),
            "item_ready": .bool(player.currentItem?.status == .readyToPlay),
        ])
        refreshVideoNowPlayingMetadata(playbackRateOverride: 0)
    }

    func requestPlay() {
        userWantsPaused = false
        transport.setPauseRequested(false)
        recordPlaybackDiagnostic("playback.play_requested", fields: [
            "status": .label(Self.timeControlStatusLabel(player.timeControlStatus)),
            "item_ready": .bool(player.currentItem?.status == .readyToPlay),
        ])
        player.play()
        applyPlaybackSpeed()
        updateTransportStatus()
        refreshVideoNowPlayingMetadata()
    }

    // MARK: - Quality / bitrate reload

    /// Rebuild the transcode stream at a new bitrate cap and resume seamlessly.
    ///
    /// The PMS universal transcoder cannot change its cap mid-session, so we tear the
    /// HLS stream down and start a fresh `start.m3u8` at `bitrateKbps`. To make it feel
    /// continuous we snapshot the current playhead, load the new item, then seek back to
    /// that position before playing. `0` requests "Direct Play / Maximum" (no cap — we pass
    /// a very high ceiling so PMS still produces a compatible HLS rendition).
    ///
    /// Only valid for reopenable sessions; a no-op for local files/static streams.
    func reload(bitrateKbps: Int) {
        guard supportsQualityReload else { return }
        let previousActiveKbps = maxVideoBitrateKbps
        userSelectedMaxVideoBitrateKbps = bitrateKbps
        adaptiveBitratePolicy.reset()
        if bitrateKbps <= 0 {
            rejectedDirectPlayStartKeys.removeAll()
        }
        guard bitrateKbps != previousActiveKbps else { return }
        let snapshot = playheadSnapshotForRestart(cause: .qualityReload)
        var fields = positionSnapshotDiagnosticFields(snapshot)
        fields["from_quality"] = .label(StreamingQuality.label(kbps: previousActiveKbps))
        fields["to_quality"] = .label(StreamingQuality.label(kbps: bitrateKbps))
        fields["resume"] = .millisecondsBucket(snapshot.positionMs)
        fields["automatic_adaptation_reset"] = .bool(true)
        recordPlaybackDiagnostic("playback.quality_change", fields: fields)
        NSLog("PlaybackController: quality reload snapshot source=%@ resumeMs=%d raw=%@ pending=%@ last=%@ suppressedZero=%@",
              snapshot.selected.cause.diagnosticLabel,
              snapshot.positionMs,
              snapshot.rawLive.map { String($0.positionMs) } ?? "nil",
              snapshot.pending.map { String($0.positionMs) } ?? "nil",
              snapshot.lastTrustworthy.map { String($0.positionMs) } ?? "nil",
              snapshot.suppressedTransientZero ? "true" : "false")
        maxVideoBitrateKbps = bitrateKbps
        // A reload is explicit user intent: reset the final-target rebuild budget.
        // (didScrobble is intentionally NOT reset — the same content shouldn't re-scrobble.)
        restartAtCurrentPosition(offsetMs: snapshot.positionMs,
                                 bitrateKbps: bitrateKbps,
                                 intent: .qualityChange)
    }

    // MARK: - Failure / retry

    /// User-initiated retry after a surfaced playback failure (P3 #8). Re-runs the
    /// streaming start path from the last known playhead so a transient bad start.m3u8
    /// (or a recovered network blip) gets one fresh, user-requested session rather than a
    /// permanent black screen or hidden restart loop. Remote backend sessions use their re-open
    /// hook so Jellyfin gets the same visible Retry affordance as Plex. No-op for local-file
    /// sessions/static remote streams (nothing to re-fetch).
    func retry() {
        guard supportsQualityReload else { return }
        beginReconnectStatus()
        let snapshot = playheadSnapshotForRestart(cause: .retry)
        let resumeMs = snapshot.positionMs
        var fields = positionSnapshotDiagnosticFields(snapshot)
        fields["resume"] = .millisecondsBucket(resumeMs)
        fields["uses_remote_reopener"] = .bool(sessionSource.kind == .mediaBrowser)
        recordPlaybackDiagnostic("playback.retry", fields: fields)
        restartAtCurrentPosition(offsetMs: resumeMs,
                                 bitrateKbps: maxVideoBitrateKbps,
                                 intent: .explicitRetry)
    }

    /// App-owned scrubber commit hook for the experimental custom player path (#38).
    ///
    /// Native AVKit scrubber callbacks are unavailable on visionOS, so `PlayerView` has to infer
    /// user intent from `AVPlayerItem.timeJumpedNotification`. The fallback player owns the
    /// scrubber directly and can pass the user's intended target here. A pure seek policy chooses
    /// native `AVPlayer.seek` for buffered/local/static-range targets and reserves server reopen for
    /// out-of-buffer HLS streams whose segment window cannot satisfy a deep target.
    func performUserSeek(toMs targetMs: Int) {
        // Fresh user intent re-arms the GH #196 one-shot startup-deadline retry. It must
        // NOT re-arm on transient `.playing` (a retried item plays briefly at 0 before its
        // resume seek, which turned the one-shot into a hidden retry loop live: three
        // silent rebuilds off a single seek on a contended server before the probe gave up).
        startupDeadlineRetryAttempted = false
        let clamped = max(0, targetMs)
        setPendingResumeMs(clamped, cause: .userSeekTarget, allowsNearZero: true)
        rememberTrustworthyPlaybackPosition(clamped,
                                            cause: .userSeekTarget,
                                            allowsNearZero: true)
        let target = CMTime(value: CMTimeValue(clamped), timescale: 1000)
        let seconds = Double(clamped) / 1000
        let targetIsWithinLoadedRange = isWithinLoadedRanges(seconds: seconds)
        let streamKind = seekStreamKind
        let seekMode = RemoteSeekModePolicy.seekMode(streamKind: streamKind,
                                                     targetIsWithinLoadedRange: targetIsWithinLoadedRange)

        guard seekMode == .reopenStreamAtTarget, !playbackError.isFailed else {
            cancelPendingFinalTargetRebuild()
            recordPlaybackDiagnostic("playback.user_seek", fields: [
                "seek_mode": .label(targetIsWithinLoadedRange ? "native_buffered" : "native_direct"),
                "seek_stream_kind": .label(String(describing: streamKind)),
                "target": .millisecondsBucket(clamped),
            ])
            // Native seek (no reprime support, or already failed). Hold the scrubber on the target
            // until AVPlayer reports completion (GH #110).
            setSeeking(true, targetMs: clamped)
            refreshVideoNowPlayingMetadata(elapsedMillisecondsOverride: clamped)
            let gen = seekGeneration
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero,
                        completionHandler: { [weak self] _ in
                            Task { @MainActor [weak self] in self?.clearSeekHold(ifGeneration: gen) }
                        })
            return
        }

        recordPlaybackDiagnostic("playback.user_seek", fields: [
            "seek_mode": .label("server_rebuild"),
            "seek_stream_kind": .label(String(describing: streamKind)),
            "target": .millisecondsBucket(clamped),
        ])
        // Out-of-buffer: hold the scrubber across the debounced rebuild/reopen. The hold is
        // released by the post-rebuild `.readyToPlay` (clearSeekHoldIfLanded) or any failure.
        setSeeking(true, targetMs: clamped)
        refreshVideoNowPlayingMetadata(elapsedMillisecondsOverride: clamped)
        scheduleFinalTargetRebuild(toMs: clamped)
    }

    /// App-owned relative seek hook for fixed transport jumps (±10/±30). It deliberately
    /// funnels into `performUserSeek(toMs:)` so button jumps get the same in-buffer native seek
    /// vs. out-of-buffer final-target rebuild behavior as the custom scrubber.
    @discardableResult
    func performRelativeUserSeek(bySeconds deltaSeconds: Int,
                                 from baseMs: Int? = nil,
                                 durationMs: Int? = nil) -> Int {
        let live = livePlaybackClockMs.flatMap { shouldUseLivePlayheadForRestart($0) ? $0 : nil }
        if let live {
            noteResumeClockDesyncIfNeeded(liveMs: live)
        }
        let base = live ?? baseMs ?? playheadSnapshotForRestart(cause: .relativeSeek).positionMs
        let (deltaMs, deltaOverflow) = deltaSeconds.multipliedReportingOverflow(by: 1000)
        let upperBound = durationMs.flatMap { $0 > 0 ? $0 : nil } ?? knownDurationMs
        let (sum, sumOverflow) = base.addingReportingOverflow(deltaMs)
        let unclamped: Int
        if deltaOverflow || sumOverflow {
            unclamped = deltaSeconds < 0 ? Int.min : Int.max
        } else {
            unclamped = sum
        }
        let target = if let upperBound {
            min(max(unclamped, 0), upperBound)
        } else {
            max(unclamped, 0)
        }
        performUserSeek(toMs: target)
        return target
    }

    private var knownDurationMs: Int? {
        let seconds = player.currentItem?.duration.seconds
        if let seconds, seconds.isFinite, seconds > 0 {
            return Int((seconds * 1000).rounded())
        }
        if let duration = item.duration, duration > 0 {
            return duration
        }
        return nil
    }

    /// Fresh control-plane client for a retry/rebuild after the stream wedged (#33).
    /// PlayerView uses this when it performs the full `.id()` rebuild, and in-place retry
    /// callers use `switchToRecoveryControlClient()` directly.
    func recoveryControlClient() -> PlexClient {
        PlexClient.recovery(identity: identity)
    }

    private func switchToRecoveryControlClient() {
        let freshClient = recoveryControlClient()
        client = freshClient
        timeline.useClient(freshClient)
        recordPlaybackDiagnostic("playback.recovery_client_swapped")
        NSLog("PlaybackController: switched Retry control-plane requests to a fresh recovery URLSession")
    }

    /// `stoppingPreviousTranscode` is true on every in-place RESTART (quality/audio reload,
    /// retry, final-target rebuild) and false only on the initial start: a restart reuses
    /// `sessionID`, and PMS proved unreliable at reaping the superseded job on its own — a
    /// live pile-up of software transcoders OOM-killed the server pod (8Gi cgroup) during the
    /// #25 stall testing. Explicitly stop the old job first (see `stopPreviousTranscode`).
    private func beginStreaming(resumeOffsetMsOverride: Int? = nil,
                                stoppingPreviousTranscode: Bool = true,
                                finalTargetRebuildGeneration: Int? = nil) {
        beginItemPreparation()
        playbackTask?.cancel()
        if let activeFinalTargetRebuildGeneration {
            finalTargetRebuildPolicy.cancelRebuild(generation: activeFinalTargetRebuildGeneration)
            self.activeFinalTargetRebuildGeneration = nil
        }
        playbackGeneration += 1
        let generation = playbackGeneration
        activeFinalTargetRebuildGeneration = finalTargetRebuildGeneration
        playbackTask = Task { [weak self] in
            guard let self else { return }
            await self.startStreaming(resumeOffsetMsOverride: resumeOffsetMsOverride,
                                      stoppingPreviousTranscode: stoppingPreviousTranscode,
                                      generation: generation)
            if let finalTargetRebuildGeneration {
                self.finalTargetRebuildPolicy.finishRebuild(generation: finalTargetRebuildGeneration)
                if self.activeFinalTargetRebuildGeneration == finalTargetRebuildGeneration {
                    self.activeFinalTargetRebuildGeneration = nil
                }
                if let pendingTarget = self.finalTargetRebuildPolicy.consumePendingTarget(),
                   self.isStreaming,
                   !self.playbackError.isFailed {
                    self.scheduleFinalTargetRebuild(toMs: pendingTarget)
                }
            }
        }
    }

    /// Tell PMS to kill this session's current transcoder before we request a new start.m3u8
    /// for the same `sessionID`. Awaited (so the stop can never race past the new start and
    /// whack the replacement job) but bounded to 2s: over a dead network — exactly the retry
    /// path — an unbounded await would stall the rebuild behind URLSession's 60s timeout.
    private func stopPreviousTranscode(server: URL, token: String) async {
        let req = TranscodeRequest.stop(server: server, token: token,
                                        identity: identity, sessionID: sessionID)
        let client = self.client
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await client.send(req) }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Streaming path

    /// Build (or rebuild) the streaming player item. `resumeOffsetMsOverride` lets a
    /// bitrate reload resume at the live playhead instead of the item's saved viewOffset.
    private func startStreaming(resumeOffsetMsOverride: Int? = nil,
                                stoppingPreviousTranscode: Bool = true,
                                generation: Int) async {
        guard let server, let token else { return }
        guard !Task.isCancelled, generation == playbackGeneration else { return }
        if stoppingPreviousTranscode {
            // #27: kill the old transcoder before requesting a new start.m3u8 for the same
            // session, so superseded jobs can't pile up and OOM the server. Persisted so a
            // restart storm is diagnosable from the log after the fact.
            playbackLog.notice("transcode: stopping previous job before in-place restart")
            recordTranscodeDiagnostic("transcode.stop_previous", fields: [
                "reason": .label("in_place_restart"),
            ])
            await stopPreviousTranscode(server: server, token: token)
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            // GH #196: detach the now-dead item immediately. A zombie item whose session was
            // just stopped keeps 404-retrying its segments — and, observed live on a seek
            // rebuild, its pending media request (at the OLD playhead) lands on the RESTARTED
            // session and yanks the fresh transcoder to that offset, so the new session's
            // first segments never appear and the rebuild dies on startup deadlines. Once the
            // transcode is stopped the old item can only ever 404; cut its network now.
            if player.currentItem != nil {
                removeObservers()
                player.replaceCurrentItem(with: nil)
            }
        }
        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"

        // "Direct Play / Maximum" (the no-cap sentinel) maps to a very high ceiling so PMS still
        // emits a playable HLS rendition rather than rejecting an absent cap — the same
        // ceiling "Maximum (HLS)" uses, and the transcode fallback when an Original
        // pick can't be copied.
        let requestedCap = maxVideoBitrateKbps <= 0 ? StreamingQuality.maxTranscodedKbps : maxVideoBitrateKbps

        // Resume position. Tell PMS to PRIME the transcode here (seconds) so it emits
        // `#EXT-X-START:TIME-OFFSET` and the first segment at the playhead is produced
        // immediately. Without this PMS transcodes from 0 and a deep client seek stalls
        // waiting on a segment the transcoder hasn't reached yet.
        let resumeMs = resumeOffsetMsOverride ?? item.viewOffset

        // GH #196: on the copy lane (Direct Play / Maximum) the `offset=` start param is
        // actively harmful — PMS emits `#EXT-X-START:TIME-OFFSET` and AVPlayer was observed
        // live decoding a single frame at the offset then abandoning the sole variant
        // (-12880). Start the copy session at 0 and resume via the client-side seek
        // fallback in the readyToPlay handler instead. Capped transcode rungs keep offset
        // priming: there the transcoder runs at ~realtime, so without priming a deep
        // client seek stalls waiting on a segment the transcoder hasn't reached yet.
        let offsetSeconds: Int? = if maxVideoBitrateKbps <= 0 {
            nil
        } else if let resumeMs, resumeMs > 0 {
            resumeMs / 1000
        } else {
            nil
        }
        let burnSubtitleStreamID = selectedBurnSubtitleStreamIDForCurrentPreferences()

        // #118: PMS ignores the `subtitles=burn`/`subtitleStreamID` query params on the
        // transcode URL for image-based (PGS/VOBSUB) subtitles — it only burns a subtitle that
        // is *selected on the part*. So when we intend to burn, PUT the selection onto the part
        // first (same mechanic as `selectAudioStream`), then build the transcode below.
        //
        // Off is the same mechanic in reverse. Plex part-level selection is ACCOUNT-STICKY and
        // shared with every other Plex client, and `subtitles=auto` burns a part-selected text
        // subtitle into the video (proven live by LiveSubtitleOffProbeTests: a selected
        // forced/default SRT flipped the copy-lane decision to `video=transcode`, with the app's
        // picker showing "Off" the whole time). So when the effective preference is "no
        // subtitles", PUT `subtitleStreamID=0` to deselect — otherwise a selection left behind
        // by another client (or our own burn path) keeps burning subtitles into every session.
        // When subtitles ARE wanted (auto-select modes) we leave the part selection alone so
        // `subtitles=auto` can serve/burn the chosen stream.
        if let subtitleSelectionOverride, let part = sourcePartForCurrentMedia() {
            let plexStreamID = subtitleSelectionOverride.plexWireValue
            do {
                try await client.send(StreamSelectionRequest.selectSubtitleStream(server: server,
                                                                                  token: token,
                                                                                  identity: identity,
                                                                                  partID: part.id,
                                                                                  subtitleStreamID: plexStreamID))
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                NSLog("LabstreamSubtitles: applied Plex metadata streamID=%d before transcode build",
                      plexStreamID)
            } catch {
                NSLog("LabstreamSubtitles: Plex metadata selection PUT failed: %@", Self.safeErrorSummary(error))
            }
        } else if let burnSubtitleStreamID, let part = sourcePartForCurrentMedia() {
            do {
                try await client.send(StreamSelectionRequest.selectSubtitleStream(server: server,
                                                                                  token: token,
                                                                                  identity: identity,
                                                                                  partID: part.id,
                                                                                  subtitleStreamID: burnSubtitleStreamID))
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                NSLog("PlaybackController: #118 selected burn subtitle stream %d on part %d before transcode build",
                      burnSubtitleStreamID, part.id)
            } catch {
                // Non-fatal: fall through and still request the transcode. The burn just won't
                // apply (the pre-#118 behavior) rather than failing the whole stream start.
                NSLog("PlaybackController: subtitle burn selection PUT failed: %@", Self.safeErrorSummary(error))
            }
        } else if subtitlesOffForNewStream(), let part = sourcePartForCurrentMedia() {
            do {
                try await client.send(StreamSelectionRequest.selectSubtitleStream(server: server,
                                                                                  token: token,
                                                                                  identity: identity,
                                                                                  partID: part.id,
                                                                                  subtitleStreamID: BackendSubtitleSelection.off.plexWireValue))
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                NSLog("PlaybackController: deselected part %d subtitle stream (subtitles off) before transcode build",
                      part.id)
            } catch {
                // Non-fatal: the stream still starts; a stale server-side selection may burn
                // subtitles this session (the pre-fix behavior).
                NSLog("PlaybackController: subtitle off deselection PUT failed: %@", Self.safeErrorSummary(error))
            }
        }

        // Apply the "Preferred Audio" language at launch — the Plex twin of the Jellyfin/Emby
        // initial `AudioStreamIndex` (MediaBrowserPlaybackPreferencePolicy.initialSelection).
        // PMS muxes only the part-selected track into the transcode, so the preference must be
        // PUT on the part before the build (same account-sticky mechanic as the subtitle PUTs
        // above and the manual Audio-tab switch). Skipped when the user already switched audio
        // this session (`audioStreamIDOverride`) or the preferred track is already selected —
        // no redundant account-wide writes.
        if audioStreamIDOverride == nil,
           let part = sourcePartForCurrentMedia(),
           let preferredAudioID = MediaBrowserPlaybackPreferencePolicy.preferredAudioStreamIndex(for: item,
                                                                                                 mediaIndex: mediaIndex),
           part.audioStreams.first(where: { $0.selected == true })?.id != preferredAudioID {
            do {
                try await client.send(StreamSelectionRequest.selectAudioStream(server: server,
                                                                               token: token,
                                                                               identity: identity,
                                                                               partID: part.id,
                                                                               audioStreamID: preferredAudioID))
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                audioStreamIDOverride = preferredAudioID
                NSLog("PlaybackController: selected preferred-language audio stream %d on part %d before transcode build",
                      preferredAudioID, part.id)
            } catch {
                // Non-fatal: the stream still starts on the server-default track (the
                // pre-fix behavior).
                NSLog("PlaybackController: preferred audio selection PUT failed: %@", Self.safeErrorSummary(error))
            }
        }

        // GH #196 DV P5 guard: a fallback-less DV stream must not travel a copy lane
        // (unguarded live result on Plex: decoder-not-found, no picture at all).
        if case .forceToneMapTranscode(let reason) = DolbyVisionGuard.verdict(for: item,
                                                                              mediaIndex: mediaIndex) {
            dvGuardReason = reason
            NSLog("PlaybackController: DV P5 guard forcing tone-map transcode (%@)", reason)
        } else {
            dvGuardReason = nil
        }
        diagnostics.dvSignallingActive = false

        let transcode = TranscodeRequest(server: server,
                                         token: token,
                                         identity: identity,
                                         metadataKey: metadataKey,
                                         maxVideoBitrateKbps: requestedCap,
                                         sessionID: sessionID,
                                         mediaIndex: mediaIndex,
                                         partIndex: 0,
                                         burnSubtitleStreamID: burnSubtitleStreamID,
                                         startOffsetSeconds: offsetSeconds,
                                         forceTranscode: dvGuardReason != nil,
                                         advertiseDolbyVision: DolbyVisionGuard.shouldAdvertiseDolbyVision(for: item,
                                                                                                           mediaIndex: mediaIndex))
        let directPlayStartKey = Self.directPlayStartRejectionKey(metadataKey: metadataKey,
                                                                  mediaIndex: mediaIndex,
                                                                  partIndex: 0)

        var requestFields: [String: DiagnosticFieldValue] = [
            "requested_cap_kbps": .int(requestedCap),
            "selected_quality": .label(StreamingQuality.label(kbps: maxVideoBitrateKbps)),
            "resume": .millisecondsBucket(resumeMs),
            "start_offset": .secondsBucket(offsetSeconds.map(Double.init)),
            "part_index": .int(0),
            "profile": .label("visionos-hls"),
            "stop_previous": .bool(stoppingPreviousTranscode),
            "subtitle_auto_select": .label(UserDefaults.standard.string(forKey: PlaybackPreferences.Keys.subtitleAutoSelectMode) ?? SubtitleAutoSelectMode.manual.rawValue),
            "subtitle_burn_mode": .label(UserDefaults.standard.string(forKey: PlaybackPreferences.Keys.subtitleBurnMode) ?? SubtitleBurnMode.automatic.rawValue),
            "burning_subtitles": .bool(burnSubtitleStreamID != nil),
            "dv_guard": .bool(dvGuardReason != nil),
        ]
        requestFields.merge(sourceDiagnosticFields()) { _, new in new }
        recordPlaybackDiagnostic("playback.start_streaming", fields: requestFields)
        recordTranscodeDiagnostic("transcode.request", fields: requestFields)

        var decision: DecisionResponse?
        var streamURL = transcode.startM3U8URL()
        // This build decides afresh whether it commits to direct play, so disarm any prior
        // fallback and consume the one-shot probe suppression. `suppressDirectPlayProbe` is set
        // by the playback-time fallback below: when a committed direct-play stream fails to
        // load, the rebuild skips the literal direct-play start and uses production HLS instead.
        directPlayFallbackArmed = false
        let skipDirectPlayProbe = suppressDirectPlayProbe
        suppressDirectPlayProbe = false
        // "Direct Play / Maximum" asks PMS to direct-play the source bits when it can copy the
        // video. If the literal direct-play start is rejected, fall through to the production HLS
        // request, which may still Direct Stream/video-copy. If PMS cannot copy video at all, that
        // same production HLS path becomes the maximum-transcode fallback. Every numeric capped
        // rung transcodes at that cap; "Maximum (HLS)" skips the literal direct-play probe but
        // may still Direct Stream/video-copy compatible sources. The user picks the
        // path by picking the quality; there is no separate
        // toggle or pre-flight bandwidth gate (#31 superseded).
        if maxVideoBitrateKbps <= 0,
           !skipDirectPlayProbe,
           dvGuardReason == nil,
           burnSubtitleStreamID == nil,
           !rejectedDirectPlayStartKeys.contains(directPlayStartKey) {
            do {
                let probe = try await client.send(transcode.directPlayProbeRequest(), as: DecisionResponse.self)
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                if probe.savesVideoEncode {
                    var fields = decisionDiagnosticFields(probe)
                    fields["probe_result"] = .label("commit_direct_play")
                    recordTranscodeDiagnostic("transcode.direct_play_probe", fields: fields)

                    let startURL = transcode.directPlayStartM3U8URL()
                    do {
                        let playlistData = try await client.send(transcode.directPlayStartM3U8Request())
                        guard !Task.isCancelled, generation == playbackGeneration else { return }
                        NSLog("PlaybackController: Direct Play / Maximum — PMS will copy video and start.m3u8 is reachable; committing direct-play start.m3u8")
                        var startFields = decisionDiagnosticFields(probe)
                        startFields["probe_result"] = .label("commit_direct_play")
                        startFields["start_preflight"] = .label("ok")
                        startFields["playlist_bytes"] = .int(playlistData.count)
                        startFields["stream_url_shape"] = .urlShape(startURL)
                        recordTranscodeDiagnostic("transcode.direct_play_start_preflight", fields: startFields)
                        decision = probe
                        streamURL = startURL
                        // Arm the playback-time fallback: PMS agreed to copy and served the
                        // initial playlist, but AVFoundation may still fail later on the media
                        // rendition. If it does, retry once via production HLS, which may still
                        // Direct Stream/video-copy.
                        directPlayFallbackArmed = true
                        #if DEBUG
                        // Log what PMS decided for this title (probe vs production), so a Debug
                        // build can tell whole-file direct play (mde=1000) from Direct Stream
                        // (video=copy) at a glance. DEBUG-only; never compiled into Release.
                        logDirectPlayDecision(transcode: transcode, probe: probe)
                        #endif
                    } catch {
                        guard !Task.isCancelled, generation == playbackGeneration else { return }
                        rejectedDirectPlayStartKeys.insert(directPlayStartKey)
                        var startFields = decisionDiagnosticFields(probe)
                        startFields["probe_result"] = .label("fallback_to_production_hls")
                        startFields["start_preflight"] = .label("rejected")
                        startFields["error"] = .error(error)
                        if let status = Self.httpStatus(from: error) {
                            startFields["http_status"] = .int(status)
                        }
                        startFields["fallback"] = .label("production_hls")
                        startFields["stream_url_shape"] = .urlShape(startURL)
                        recordTranscodeDiagnostic("transcode.direct_play_start_rejected", fields: startFields)
                        NSLog("PlaybackController: Direct Play / Maximum — PMS accepted decision but rejected direct-play start.m3u8 (%@); using production HLS path",
                              Self.safeErrorSummary(error))
                    }
                } else {
                    var fields = decisionDiagnosticFields(probe)
                    fields["probe_result"] = .label("fallback_to_transcode")
                    recordTranscodeDiagnostic("transcode.direct_play_probe", fields: fields)
                    NSLog("PlaybackController: Direct Play / Maximum — PMS cannot copy video; using maximum transcode")
                }
            } catch {
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                recordTranscodeDiagnostic("transcode.direct_play_probe_failed", fields: [
                    "error": .error(error),
                    "fallback": .label("production_hls"),
                ])
                NSLog("PlaybackController: direct-play probe failed (%@); using production HLS path", Self.safeErrorSummary(error))
            }
        } else if maxVideoBitrateKbps <= 0,
                  !skipDirectPlayProbe,
                  burnSubtitleStreamID == nil,
                  rejectedDirectPlayStartKeys.contains(directPlayStartKey) {
            recordTranscodeDiagnostic("transcode.direct_play_start_skipped", fields: [
                "reason": .label("cached_start_rejection"),
                "fallback": .label("production_hls"),
            ])
            NSLog("PlaybackController: Direct Play / Maximum — skipping cached rejected direct-play start.m3u8; using production HLS path")
        }

        if decision == nil {
            do {
                let response = try await client.send(transcode.decisionRequest(), as: DecisionResponse.self)
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                decision = response
                recordTranscodeDiagnostic("transcode.decision", fields: decisionDiagnosticFields(response))
                if case .unsupported = response.decision {
                    recordTranscodeDiagnostic("transcode.unsupported", fields: decisionDiagnosticFields(response))
                    NSLog("PlaybackController: transcode decision unsupported code=%@",
                          response.generalDecisionCode.map(String.init) ?? "nil")
                    // GH #196: a DV-P5-guarded session with an unsupported decision means PMS
                    // refuses the tone-map ("DoVi (Profile 5) color space is not supported" —
                    // its software pipeline can't convert IPTPQc2). The follow-up start.m3u8
                    // would 400 into an opaque -1008; fail fast with the DV message instead.
                    if dvGuardReason != nil {
                        NSLog("PlaybackController: PMS refused DV P5 tone-map, surfacing DV error (#196)")
                        surfaceFailure(NSError(domain: "Labstream.Playback",
                                               code: -196,
                                               userInfo: [NSLocalizedDescriptionKey: DolbyVisionGuard.failureMessage]))
                        return
                    }
                }
            } catch {
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                recordTranscodeDiagnostic("transcode.decision_failed", fields: [
                    "error": .error(error),
                    "fallback": .label("attempt_start_m3u8"),
                ])
                NSLog("PlaybackController: decision call failed (%@); attempting start.m3u8 anyway", Self.safeErrorSummary(error))
            }
        }

        diagnostics.applyStatic(item: item,
                                mediaIndex: mediaIndex,
                                decision: decision,
                                server: server,
                                targetBitrateKbps: maxVideoBitrateKbps,
                                subtitleBurnRequested: burnSubtitleStreamID != nil,
                                dolbyVisionGuardActive: dvGuardReason != nil,
                                decisionUnavailableMeansTranscode: true)
        var selectedFields: [String: DiagnosticFieldValue] = [
            "stream_url_shape": .urlShape(streamURL),
            "direct_play_fallback_armed": .bool(directPlayFallbackArmed),
            "decision_present": .bool(decision != nil),
        ]
        if let decision {
            selectedFields.merge(decisionDiagnosticFields(decision)) { _, new in new }
        }
        selectedFields.merge(playbackExplanationDiagnosticFields()) { _, new in new }
        recordPlaybackDiagnostic("playback.stream_selected", fields: selectedFields)

        // GH #196 copy-lane startup hardening: on Direct Play / Maximum the PMS session emits
        // 10s / tens-of-MB fMP4 segments in a single-variant playlist, and on a cold session
        // the transcoder only starts once the child playlist is fetched — so AVPlayer's hard
        // startup deadlines (-12889/-16830) can fire before the first segment exists, and with
        // one variant the miss is terminal (-12880). Warm the session ourselves: fetch the
        // playlists (starting the transcoder) and wait until PMS actually serves the init
        // header + first segment byte before attaching AVPlayer. Soft-fail: on timeout we
        // attach anyway and the error-log auto-retry below is the backstop.
        if maxVideoBitrateKbps <= 0 {
            let prewarm = await HLSSessionPrewarmer.prewarm(
                startURL: streamURL,
                headers: PlexHeaders.media(identity: identity, token: token))
            guard !Task.isCancelled, generation == playbackGeneration else { return }
            recordTranscodeDiagnostic("transcode.prewarm", fields: [
                "outcome": .label(prewarm.outcome.rawValue),
                "elapsed_ms": .int(Int(prewarm.elapsedSeconds * 1000)),
                "polls": .int(prewarm.polls),
            ])
            NSLog("PlaybackController: copy-lane prewarm %@ after %.1fs (%d polls) (#196)",
                  prewarm.outcome.rawValue, prewarm.elapsedSeconds, prewarm.polls)
        }

        // Plex Universal HLS can rely on the X-Plex identity headers in addition to the
        // token-bearing query string. In particular the Generic profile path that lets PMS
        // remux/copy 10-bit HEVC at Direct Play / Maximum has been observed to 400 on the
        // same URL when fetched without the standard X-Plex headers. Thread the headers into
        // AVFoundation so the media-plane request matches our successful control preflight.
        let assetOptions: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": PlexHeaders.media(identity: identity, token: token),
        ]

        // GH #196 spike (b): with the experimental DV-signalling setting on and a DV P8
        // source, route the Plex HLS session through the loopback proxy so the master
        // playlist gains SUPPLEMENTAL-CODECS/VIDEO-RANGE. Failure falls back to the direct
        // URL — this lane must never be worse than today.
        if let injection = DolbyVisionGuard.playlistInjection(for: item, mediaIndex: mediaIndex) {
            let proxy = MediaSessionProxy(dolbyVisionInjection: injection,
                                          extraUpstreamHeaders: PlexHeaders.media(identity: identity,
                                                                                  token: token))
            do {
                let handle = try await proxy.standUpLoopback(forStream: streamURL)
                guard !Task.isCancelled, generation == playbackGeneration else {
                    await proxy.stop(generation: handle.generation)
                    return
                }
                if let oldProxy = remoteHLSProxy, let oldGeneration = remoteHLSProxyGeneration {
                    await oldProxy.stop(generation: oldGeneration)
                }
                remoteHLSProxy = proxy
                remoteHLSProxyGeneration = handle.generation
                streamURL = handle.localURL
                diagnostics.dvSignallingActive = true
                recordPlaybackDiagnostic("playback.dv_injection_proxy_open", fields: [
                    "supplemental_codecs": .label(injection.supplementalCodecs),
                    "video_range": .label(injection.videoRange),
                ])
                NSLog("PlaybackController: DV signalling injection active (%@ / %@) (#196)",
                      injection.supplementalCodecs, injection.videoRange)
            } catch {
                recordPlaybackDiagnostic("playback.dv_injection_proxy_failed", fields: [
                    "error": .error(error),
                ])
                NSLog("PlaybackController: DV injection proxy failed, using direct URL (%@)",
                      Self.safeErrorSummary(error))
            }
        }

        let asset = AVURLAsset(url: streamURL, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        guard !Task.isCancelled, generation == playbackGeneration else { return }
        load(playerItem, resumeOffsetMs: resumeMs)
    }

    #if DEBUG
    /// DEBUG-only per-title decision logger for the "Direct Play / Maximum" path. When PMS agrees
    /// to direct-play a title we commit `directPlayStartM3U8URL()`; this records WHY, so a Debug
    /// build can distinguish whole-file direct play (`mde=1000`) from Direct Stream (`video=copy`,
    /// copy video / transcode audio) at a glance, alongside the production verdict we would
    /// otherwise have transcoded on. Logged as `gen= mde= part= video= audio= saves=`. Only the
    /// probe-commit branch reaches here, so it fires solely for titles PMS agreed to direct-play.
    /// No token, host, or URL is ever logged — only decision codes and the decision enums.
    ///
    /// History: this began as a one-shot probe to chase a phantom "start.m3u8 → HTTP 400" (round 2
    /// proved start.m3u8 returns 200 for every profile-extra variant and direct play works); the
    /// decision fields stayed useful, so the URL-status dissection was removed and this kept.
    private func logDirectPlayDecision(transcode: TranscodeRequest, probe: DecisionResponse) {
        let client = self.client
        Task {
            func fields(_ d: DecisionResponse) -> String {
                "gen=\(d.generalDecisionCode.map(String.init) ?? "-")"
                    + " mde=\(d.mdeDecisionCode.map(String.init) ?? "-")"
                    + " part=\(d.partDecision ?? "-")"
                    + " video=\(d.videoDecision ?? "-")"
                    + " audio=\(d.audioDecision ?? "-")"
                    + " saves=\(d.savesVideoEncode)"
            }
            // probe is in hand; the production verdict we fetch fresh (its own params).
            NSLog("PlaybackController[dp-diag]: probe-decision %@", fields(probe))
            do {
                let prod = try await client.send(transcode.decisionRequest(), as: DecisionResponse.self)
                NSLog("PlaybackController[dp-diag]: prod-decision  %@", fields(prod))
            } catch {
                NSLog("PlaybackController[dp-diag]: prod-decision  failed %@", Self.safeErrorSummary(error))
            }
        }
    }
    #endif

    // MARK: - Local-file path

    private func loadLocalFile(_ url: URL) {
        // Seed static facts for the Stats overlay; offline playback is always a local
        // direct file (no transcode decision, no remote host).
        diagnostics.applyStatic(item: item,
                                decision: nil,
                                server: nil,
                                targetBitrateKbps: 0)
        diagnostics.connectionHost = "Local file"
        var fields: [String: DiagnosticFieldValue] = [
            "path_mode": .label("local_file"),
            "stream_url_shape": .urlShape(url),
        ]
        fields.merge(sourceDiagnosticFields()) { _, new in new }
        recordPlaybackDiagnostic("playback.start_path", fields: fields)

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        // Offline content resumes from the same `viewOffset` if present.
        load(playerItem, resumeOffsetMs: item.viewOffset)
    }

    private func loadRemoteStream(_ url: URL, headers: [String: String], resumeOffsetMs: Int? = nil) {
        // Seed static facts for the Stats overlay. The stream has already been resolved by the
        // backend, so there is no Plex decision/proxy state to report here.
        diagnostics.applyStatic(item: item,
                                mediaIndex: mediaIndex,
                                decision: nil,
                                server: url,
                                targetBitrateKbps: maxVideoBitrateKbps)
        if let remoteSourceMetadata, let remotePlayMethod {
            diagnostics.applyMediaBrowserSource(remoteSourceMetadata,
                                                playMethod: remotePlayMethod,
                                                transcodeReasons: remoteTranscodeReasons,
                                                dolbyVisionGuardActive: dvGuardReason != nil)
        }
        diagnostics.usesLocalMediaProxy = Self.isLoopback(url)
        if diagnostics.usesLocalMediaProxy,
           let upstream = remoteStreamURL,
           !Self.isLoopback(upstream),
           let host = upstream.host {
            diagnostics.connectionHost = upstream.port.map { "\(host):\($0)" } ?? host
        } else {
            diagnostics.connectionHost = url.host ?? "Remote stream"
        }
        var fields: [String: DiagnosticFieldValue] = [
            "path_mode": .label("remote_stream"),
            "stream_url_shape": .urlShape(url),
            "play_method": .label(remotePlayMethod?.rawValue),
            "headers_present": .bool(!headers.isEmpty),
        ]
        fields.merge(sourceDiagnosticFields()) { _, new in new }
        fields.merge(mediaBrowserSourceDiagnosticFields(remoteSourceMetadata)) { _, new in new }
        fields.merge(playbackExplanationDiagnosticFields()) { _, new in new }
        recordPlaybackDiagnostic("playback.start_path", fields: fields)

        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        load(playerItem, resumeOffsetMs: resumeOffsetMs ?? item.viewOffset)
    }

    private func beginRemoteStream(_ url: URL,
                                   headers: [String: String],
                                   resumeOffsetMs: Int?,
                                   playMethod: MediaBrowserPlayMethod?) {
        beginItemPreparation()
        let generation = playbackGeneration
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let playableURL = await self.playableRemoteStreamURL(url,
                                                                       headers: headers,
                                                                       resumeOffsetMs: resumeOffsetMs,
                                                                       playMethod: playMethod,
                                                                       generation: generation),
                  RemoteStreamLifecyclePolicy.acceptsReopenResult(
                      capturedGeneration: generation,
                      currentGeneration: self.playbackGeneration,
                      isCancelled: Task.isCancelled) else {
                return
            }
            self.loadRemoteStream(playableURL, headers: headers, resumeOffsetMs: resumeOffsetMs)
        }
    }

    private func playableRemoteStreamURL(_ url: URL,
                                         headers: [String: String],
                                         resumeOffsetMs: Int?,
                                         playMethod: MediaBrowserPlayMethod?,
                                         generation: Int) async -> URL? {
        guard !Task.isCancelled, generation == playbackGeneration else { return nil }
        guard playMethod == .transcode,
              let resumeOffsetMs, resumeOffsetMs > 0,
              let primedURL = jellyfinHLSURL(url, startTimeTicks: resumeOffsetMs * 10_000)
        else { return url }

        // GH #196: same startup-deadline hazard as the Plex copy lane, MediaBrowser flavor —
        // a deep-offset reopen makes the server restart its transcoder at the target, and
        // Emby was observed live serving NOTHING for the first media file within
        // AVFoundation's deadline (-12889 "No response for media file in 6s"), repeatedly.
        // Fetching the playlists starts the transcoder and polling the first segment holds
        // the attach until media exists. Soft-fail: on timeout we attach anyway and the
        // one-shot deadline retry is the backstop. Budget is deliberately short: Emby serves
        // within ~1-2s once its transcoder starts, while Jellyfin never satisfies the poll
        // (its ticks-primed playlist names segments it mints only on demand — verified live:
        // prewarm timed out yet playback resumed fine) — so a long budget would only add
        // latency to every JF deep seek.
        let prewarm = await HLSSessionPrewarmer.prewarm(startURL: primedURL,
                                                        headers: headers,
                                                        budgetSeconds: 8)
        guard !Task.isCancelled, generation == playbackGeneration else { return nil }
        recordPlaybackDiagnostic("playback.remote_prewarm", fields: [
            "outcome": .label(prewarm.outcome.rawValue),
            "elapsed_ms": .int(Int(prewarm.elapsedSeconds * 1000)),
            "polls": .int(prewarm.polls),
            "target": .millisecondsBucket(resumeOffsetMs),
        ])
        NSLog("PlaybackController: remote transcode prewarm %@ after %.1fs (%d polls) (#196)",
              prewarm.outcome.rawValue, prewarm.elapsedSeconds, prewarm.polls)

        let proxy = MediaSessionProxy(strippedPlaylistQueryItemNames: ["starttimeticks"],
                                      injectedPlaylistStartTimeOffsetSeconds: Double(resumeOffsetMs) / 1000.0)
        do {
            let handle = try await proxy.standUpLoopback(forStream: primedURL)
            guard !Task.isCancelled, generation == playbackGeneration else {
                await proxy.stop(generation: handle.generation)
                return nil
            }
            if let oldProxy = remoteHLSProxy, let oldGeneration = remoteHLSProxyGeneration {
                await oldProxy.stop(generation: oldGeneration)
            }
            remoteHLSProxy = proxy
            remoteHLSProxyGeneration = handle.generation
            recordPlaybackDiagnostic("playback.remote_hls_proxy_open", fields: [
                "target": .millisecondsBucket(resumeOffsetMs),
                "strips_start_time_ticks": .bool(true),
            ])
            return handle.localURL
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, generation == playbackGeneration else {
                return nil
            }
            recordPlaybackDiagnostic("playback.remote_hls_proxy_failed", fields: [
                "target": .millisecondsBucket(resumeOffsetMs),
                "error": .error(error),
            ])
            return url
        }
    }

    private func jellyfinHLSURL(_ url: URL, startTimeTicks: Int) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = comps.queryItems ?? []
        items.removeAll { $0.name.caseInsensitiveCompare("StartTimeTicks") == .orderedSame }
        items.append(URLQueryItem(name: "StartTimeTicks", value: String(startTimeTicks)))
        comps.queryItems = items
        return comps.url
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    // MARK: - visionOS Video Now Playing / remote commands (#197)

    private func activateVideoNowPlayingSessionIfNeeded() {
        #if os(visionOS)
        if videoNowPlayingCoordinator == nil {
            videoNowPlayingCoordinator = VideoNowPlayingCoordinator(controller: self)
        }
        #endif
    }

    private func stopVideoNowPlayingSession() {
        #if os(visionOS)
        videoNowPlayingCoordinator?.stop()
        videoNowPlayingCoordinator = nil
        #endif
    }

    /// Registers the process-wide iOS/macOS publisher as an observer of canonical playback
    /// metadata events. The token prevents delayed teardown from removing a newer publisher.
    @discardableResult
    func observeVideoNowPlayingMetadata(
        _ observer: @escaping VideoNowPlayingMetadataObserverRegistry.Observer
    ) -> VideoNowPlayingMetadataObserverRegistry.Token {
        videoNowPlayingMetadataObservers.observe(observer)
    }

    func removeVideoNowPlayingMetadataObserver(
        _ token: VideoNowPlayingMetadataObserverRegistry.Token
    ) {
        videoNowPlayingMetadataObservers.remove(token)
    }

    func refreshVideoNowPlayingMetadata(elapsedMillisecondsOverride: Int? = nil,
                                        playbackRateOverride: Double? = nil) {
        #if os(visionOS)
        if let videoNowPlayingCoordinator {
            videoNowPlayingCoordinator.refreshDynamicMetadata(
                mediaItem: item,
                durationMilliseconds: knownDurationMs,
                elapsedMilliseconds: elapsedMillisecondsOverride ?? currentResumeMs,
                playbackRate: playbackRateOverride ?? currentNowPlayingPlaybackRate,
                defaultPlaybackRate: Double(playbackSpeed))
        }
        #endif
        videoNowPlayingMetadataObservers.publish(.init(
            elapsedMillisecondsOverride: elapsedMillisecondsOverride,
            playbackRateOverride: playbackRateOverride))
    }

    var videoNowPlayingDurationMilliseconds: Int? { knownDurationMs }

    /// Apply a validated system-transport intent through the same app-owned user-seek paths as
    /// the custom chrome. Platform coordinators own publishing, not seek behavior.
    func performVideoNowPlayingCommand(_ intent: VideoNowPlayingCommandPolicy.Intent) {
        switch intent {
        case .seek(let targetMilliseconds):
            performUserSeek(toMs: targetMilliseconds)
        case .skip(let deltaSeconds):
            performRelativeUserSeek(bySeconds: deltaSeconds)
        }
    }

    #if os(visionOS)
    private var currentNowPlayingPlaybackRate: Double {
        guard !userWantsPaused, player.timeControlStatus == .playing else { return 0 }
        let rate = Double(player.rate)
        return rate > 0 ? rate : Double(playbackSpeed)
    }
    #endif

    // MARK: - Now Playing / cinema chrome metadata (R5)

    /// Build the textual `externalMetadata` items for the player chrome (Now Playing /
    /// Control Center / the visionOS cinema title card) from the `MediaItem`. Title, an
    /// optional subtitle (year, used as lightweight context since `MediaItem` doesn't carry
    /// show/episode names), and the summary as the description. Artwork is fetched separately
    /// and appended asynchronously (see `attachExternalMetadata`).
    ///
    /// `@MainActor` because `AVMetadataItem` construction is done here alongside the player.
    private func textExternalMetadata() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        items.append(Self.metadataItem(identifier: .commonIdentifierTitle, value: item.title))

        // Release year for the system ⓘ Info card (shown after the runtime). Without this the
        // card falls back to the transcode stream's creation date — today's year (seen live as
        // "2026" on a 2013 film). The card only honors `.commonIdentifierCreationDate` with an
        // NSDate-typed value: STRING values under it and every other plausible date identifier
        // (quickTime/id3/iTunes) were proven ignored live. See docs/DEVELOPMENT.md.
        if let year = item.year,
           let date = DateComponents(calendar: Calendar(identifier: .gregorian),
                                     year: year, month: 1, day: 1).date {
            let dateItem = AVMutableMetadataItem()
            dateItem.identifier = .commonIdentifierCreationDate
            dateItem.value = date as NSDate
            dateItem.extendedLanguageTag = "und"
            items.append(dateItem)
        }
        if let summary = item.summary, !summary.isEmpty {
            items.append(Self.metadataItem(identifier: .commonIdentifierDescription,
                                           value: Self.infoPanelSummary(summary)))
        }
        return items
    }

    /// Cap the description fed to the system ⓘ Info tab. That card gives the description as
    /// many lines as the text wants and pushes the TITLE off the top of the panel when a Plex
    /// summary runs long (verified live) — the system only ellipsizes well past the point
    /// where the layout has already broken. 240 still clipped the title (5 wrapped lines);
    /// 150 keeps it to ~3 so the whole card fits. Word-boundary cut, then an ellipsis.
    private static func infoPanelSummary(_ summary: String, limit: Int = 150) -> String {
        guard summary.count > limit else { return summary }
        let cut = summary.prefix(limit)
        let trimmed = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return trimmed + "…"
    }

    /// Construct a single string-valued `AVMetadataItem` for the given common identifier.
    private static func metadataItem(identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    /// Configure the one artwork request used by AVPlayerItem metadata and visionOS Now Playing.
    /// Called before `start()`; the immutable descriptor carries the exact authenticated/local
    /// ownership generation and the pipeline joins matching system-surface consumers.
    func configureExternalArtwork(descriptor: ArtworkRequestDescriptor?,
                                  pipeline: ArtworkPipeline?) {
        externalArtworkDescriptor = descriptor
        externalArtworkPipeline = pipeline
    }

    /// Build an artwork `AVMetadataItem` from original encoded bytes. Preserve the true ImageIO
    /// type instead of claiming all bytes are JPEG (PNG/WebP inputs must never be mislabeled).
    private static func artworkMetadataItem(data: Data,
                                            typeIdentifier: String?) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierArtwork
        item.value = data as NSData
        item.dataType = typeIdentifier
        item.extendedLanguageTag = "und"
        return item
    }

    /// Populate `playerItem.externalMetadata` so the player chrome / Now Playing shows the
    /// real title + artwork instead of a filename. Sets the text items synchronously, then
    /// fetches the poster image off the main actor (best-effort) and appends it once it
    /// arrives. Never blocks playback: on any failure the chrome simply shows no artwork.
    ///
    /// Streaming sessions fetch through `/photo/:/transcode`; downloaded playback reads the
    /// poster side asset already cached beside the media file. Older downloads without a cached
    /// poster keep the text-only fallback.
    private func attachExternalMetadata(to playerItem: AVPlayerItem,
                                        observedPlaybackGeneration: Int) {
        #if os(macOS)
        // `externalMetadata` is unavailable on native macOS AVPlayerItem; keep playback
        // functional and let the Mac playback slice design Now Playing/player metadata.
        return
        #else
        let textItems = textExternalMetadata()
        playerItem.externalMetadata = textItems
        #if os(visionOS)
        videoNowPlayingCoordinator?.applyInitialMetadata(to: playerItem,
                                                         mediaItem: item,
                                                         durationMilliseconds: knownDurationMs,
                                                         elapsedMilliseconds: currentResumeMs,
                                                         playbackRate: currentNowPlayingPlaybackRate,
                                                         defaultPlaybackRate: Double(playbackSpeed))
        #endif

        guard let descriptor = externalArtworkDescriptor,
              let pipeline = externalArtworkPipeline else { return }

        Task { [weak self, weak playerItem] in
            guard let response = try? await pipeline.fetch(descriptor, priority: .visible),
                  !Task.isCancelled,
                  let self,
                  let playerItem,
                  self.isCurrentPlaybackLifecycle(observedPlaybackGeneration),
                  self.externalArtworkDescriptor?.taskIdentity == descriptor.taskIdentity,
                  self.player.currentItem === playerItem else { return }
            playerItem.externalMetadata = textItems + [Self.artworkMetadataItem(
                data: response.encodedData,
                typeIdentifier: response.encodedTypeIdentifier)]
            #if os(visionOS)
            self.videoNowPlayingCoordinator?.applyInitialMetadata(
                to: playerItem,
                mediaItem: self.item,
                durationMilliseconds: self.knownDurationMs,
                elapsedMilliseconds: self.currentResumeMs,
                playbackRate: self.currentNowPlayingPlaybackRate,
                defaultPlaybackRate: Double(self.playbackSpeed),
                artworkImage: response.image)
            #endif
        }
        #endif
    }

    /// Builds a request for a chapter thumbnail key, sized 16:9 landscape. Plex images
    /// authenticate in the transcode URL; MediaBrowser chapter images authenticate through the
    /// same headers that opened the remote stream, so tokens stay out of image URLs.
    ///
    /// The Chapters info-tab rail can't use `PosterImage` (which reads `AppModel`
    /// from the SwiftUI environment): AVKit hosts each info tab in its own
    /// `UIHostingController`, outside that environment. The controller already
    /// holds the server + token, so it vends the URL directly instead.
    func chapterThumbnailRequest(for imagePath: String?, chapterIndex: Int) -> URLRequest? {
        // Offline playback (#88): there is no server to transcode against, so resolve the chapter's
        // cached local image keyed by its index (the position in `chapters`, the same enumeration
        // the download-time cache used). A `file://` URL loads in `AsyncImage` exactly like a remote
        // one. Index-keying covers Plex too, whose chapter `thumb` key carries no index.
        if sessionSource.kind == .offline {
            return offlineChapterImageURLs[chapterIndex].map { URLRequest(url: $0) }
        }

        guard let imagePath, !imagePath.isEmpty else { return nil }

        // Jellyfin chapters are carried through PMSKit's shared `Chapter.thumb` as a synthetic
        // stable key. The player is the only place that has the resolved remote HLS URL, so it
        // derives the server base here and asks Jellyfin's native chapter-image endpoint for a
        // 16:9 thumbnail. Keep this purely an image URL translation; do not touch playback state.
        if MediaBrowserSyntheticChapterImageRef.parse(imagePath, scheme: JellyfinFlavor.syntheticScheme) != nil,
           let base = remoteStreamURL.flatMap(jellyfinServerBaseURL(from:)) {
            guard let url = try? JellyfinLibrary.chapterImageRequestURL(syntheticRef: imagePath,
                                                                        server: base,
                                                                        width: 480,
                                                                        height: 270) else { return nil }
            return mediaBrowserChapterImageRequest(url: url)
        }

        // Emby mirrors the Jellyfin synthetic-chapter scheme (`emby://item/{id}/Chapter/{index}?tag=`).
        // Resolve it through Emby's native chapter-image endpoint, deriving the server base from the
        // resolved remote HLS URL exactly as the Jellyfin branch does (the /videos/ + /items/ split is
        // case-insensitive and already covers Emby's lowercase playable paths).
        if MediaBrowserSyntheticChapterImageRef.parse(imagePath, scheme: EmbyFlavor.syntheticScheme) != nil,
           let base = remoteStreamURL.flatMap(jellyfinServerBaseURL(from:)) {
            guard let url = try? EmbyLibrary.chapterImageRequestURL(syntheticRef: imagePath,
                                                                    server: base,
                                                                    width: 480,
                                                                    height: 270) else { return nil }
            return mediaBrowserChapterImageRequest(url: url)
        }

        guard let server, let token else { return nil }
        return PlexPhotoTranscode.url(server: server,
                                      token: token,
                                      imagePath: imagePath,
                                      width: 480,
                                      height: 270).map { URLRequest(url: $0) }
    }

    private func mediaBrowserChapterImageRequest(url: URL?) -> URLRequest? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        for (field, value) in remoteHTTPHeaders {
            req.setValue(value, forHTTPHeaderField: field)
        }
        req.setValue("image/jpeg,*/*", forHTTPHeaderField: "Accept")
        return req
    }

    private func jellyfinServerBaseURL(from streamURL: URL) -> URL? {
        guard var comps = URLComponents(url: streamURL, resolvingAgainstBaseURL: false) else { return nil }
        let lowerPath = comps.percentEncodedPath.lowercased()
        if let range = lowerPath.range(of: "/videos/") {
            comps.percentEncodedPath = String(comps.percentEncodedPath[..<range.lowerBound])
        } else if let range = lowerPath.range(of: "/items/") {
            comps.percentEncodedPath = String(comps.percentEncodedPath[..<range.lowerBound])
        } else {
            comps.percentEncodedPath = ""
        }
        comps.percentEncodedQuery = nil
        comps.fragment = nil
        return comps.url
    }

    // MARK: - Shared load + observers

    private func load(_ playerItem: AVPlayerItem, resumeOffsetMs: Int?) {
        // A replacement item is a new callback authority even when it belongs to the same
        // control-plane start/reopen operation.
        playbackGeneration += 1
        let observedPlaybackGeneration = playbackGeneration
        // Reset per-item state for the new player item: a fresh load is a fresh resume
        // (didSeek), a fresh readiness gate, and a clean error surface (P2/P3/P8).
        didSeek = false
        timeline.isReadyForReporting = false
        didApplySavedSubtitle = false
        didApplyAudioPreference = false
        hdrProbeConclusive = false
        setPendingResumeMs(resumeOffsetMs, cause: .load)
        didLogResumeClockDesync = false
        // Echo baseline: the resume seek's own `timeJumpedNotification` lands at this offset;
        // suppress nearby jumps so a rebuild does not immediately schedule another rebuild.
        lastPrimedOffsetMs = resumeOffsetMs ?? 0
        hasObservedPlayback = false
        currentTimeControlStatus = .paused
        hasObservedTimeControlStatus = false
        // Fresh item, fresh zombie-clock baseline: a reload that resumes at the same parked
        // position must not inherit the previous item's "clock hasn't moved" countdown.
        zombieClockBaselineMs = nil
        zombieClockBaselineAt = nil
        playbackError.clear()
        offlineSubtitleOverlay.set(nil)
        updateTransportStatus()
        // GH #196: when the DV P5 guard forced this session onto a tone-map transcode,
        // label the decision and start the first-frame deadline.
        diagnostics.dvGuardReason = dvGuardReason
        cancelDVGuardWatchdog()
        if dvGuardReason != nil {
            armDVGuardWatchdog()
        }
        // Clear any active Skip affordance for the (re)loaded item. The skip RANGES are
        // unchanged across a Quality reload (same `item`), so we only reset the live UI
        // state here; the new fine-grained observer will re-derive the active marker.
        skipMarker.clear()
        // Configure + activate the shared audio session before the item starts (#17), and
        // register the interruption / route-change / background observers once. Both are
        // idempotent across a Quality reload (which re-enters here): the session is already
        // active and `installObservers()` no-ops on its second call.
        audioSession.activate()
        // Reinstall for every item so the observer closures capture this item's authority.
        // Removal alone cannot retract a notification whose MainActor continuation is queued.
        audioSession.reinstallObservers { [weak self] in
            self?.isCurrentPlaybackLifecycle(observedPlaybackGeneration) == true
        }
        // Forward-buffer tuning (#21 / #43 / #175). Normal remote-HLS VOD playback should keep
        // an airplane-safe cushion. The short buffer is reserved for actual out-of-buffer seek
        // reopens, where Jellyfin may only mint segments around realtime and a deep target can
        // wedge first-frame resume.
        let preferShortRemoteHLSBuffer = preferShortRemoteHLSBufferForNextLoad
        preferShortRemoteHLSBufferForNextLoad = false
        // Plex lanes (Direct Play / Direct Stream included) are start.m3u8 transcode-session
        // playlists — EVENT-style, so AVPlayer treats them as live-ish and refuses to load
        // while paused unless the live-streaming-while-paused flag is on. Classify by the
        // item's actual URL so those sessions get the same treatment as JF/Emby transcodes;
        // progressive/static lanes (JF/Emby direct, offline files) stay plain VOD. (#195)
        let itemStreamURL = (playerItem.asset as? AVURLAsset)?.url
        let bufferingConfig = PlaybackBufferingPolicy.configuration(
            isRemoteServerEncodedHLS: isRemoteTranscode
                || PlaybackBufferingPolicy.isServerEncodedHLSPlaylist(url: itemStreamURL),
            preferShortRemoteHLSBuffer: preferShortRemoteHLSBuffer)
        configureAdaptiveBitratePolicy(usesShortRemoteBuffer: bufferingConfig.usesShortRemoteHLSBuffer)
        activeForwardBufferTargetSeconds = bufferingConfig.preferredForwardBufferSeconds
        playerItem.preferredForwardBufferDuration = bufferingConfig.preferredForwardBufferSeconds
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused =
            bufferingConfig.canUseNetworkResourcesForLiveStreamingWhilePaused
        player.automaticallyWaitsToMinimizeStalling = bufferingConfig.automaticallyWaitsToMinimizeStalling
        activateVideoNowPlayingSessionIfNeeded()
        // Populate Now Playing / cinema-chrome metadata (title + summary now, artwork async).
        // Done for both streaming and local-file paths so the player shows the real title.
        attachExternalMetadata(to: playerItem,
                               observedPlaybackGeneration: observedPlaybackGeneration)
        nextPlayerItemGeneration += 1
        currentPlayerItemGeneration = nextPlayerItemGeneration
        ignoredRecoverableFailedToEndCount = 0
        let itemGeneration = currentPlayerItemGeneration
        player.replaceCurrentItem(with: playerItem)
        refreshVideoNowPlayingMetadata(elapsedMillisecondsOverride: resumeOffsetMs)
        // Resolve Up Next under the replacement item's lifecycle. A response released after
        // stop/reload must not repopulate the card for a dead item.
        upNextTask?.cancel()
        upNextTask = Task { [weak self] in
            await self?.resolveNextItem(observedPlaybackGeneration: observedPlaybackGeneration)
        }
        playbackItemLoadSpan?.end(result: "superseded", fields: ["path_mode": performancePathMode])
        playbackItemLoadSpan = PerformanceInstrumentation.begin(.playbackItemLoad,
                                                                backend: performanceBackendLabel,
                                                                fields: [
                                                                    "path_mode": performancePathMode,
                                                                    "resume": resumeOffsetMs ?? 0,
                                                                    "quality_kbps": maxVideoBitrateKbps,
                                                                ])
        recordPlaybackDiagnostic("playback.item_loaded", fields: [
            "resume": .millisecondsBucket(resumeOffsetMs),
            "preferred_forward_buffer_seconds": .int(Int(bufferingConfig.preferredForwardBufferSeconds)),
            "automatically_waits_to_minimize_stalling": .bool(player.automaticallyWaitsToMinimizeStalling),
            "short_remote_hls_buffer": .bool(bufferingConfig.usesShortRemoteHLSBuffer),
            "item_generation": .int(itemGeneration),
        ])
        installObservers(for: playerItem,
                         resumeOffsetMs: resumeOffsetMs,
                         itemGeneration: itemGeneration,
                         observedPlaybackGeneration: observedPlaybackGeneration)
        startDiagnosticsSampling(playerItem: playerItem,
                                 itemGeneration: itemGeneration,
                                 observedPlaybackGeneration: observedPlaybackGeneration)
        if userWantsPaused {
            player.pause()
            transport.set(paused: true)
        } else {
            player.play()
        }
        // GH #33 first-start net: while still inside the preparation window (streaming lanes;
        // local files never enter it) arm the post-attach watchdog so a cold hang that never
        // fires a KVO or an error converts to Retry instead of an eternal spinner. Cancelled
        // by the same signals that end preparation.
        if itemPreparationInProgress {
            armItemPreparationWatchdog()
        }
        updateTransportStatus()
    }

    /// Poll the player's access/error logs ~1s for the Stats overlay. A repeating
    /// `Timer` is used (rather than the timeline observer) so the numbers tick even
    /// while paused and at a finer cadence than the 10s heartbeat.
    private func startDiagnosticsSampling(playerItem: AVPlayerItem,
                                          itemGeneration: Int,
                                          observedPlaybackGeneration: Int) {
        diagnosticsObservers.reset()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.isCurrentObservedItem(playerItem,
                                                 itemGeneration: itemGeneration,
                                                 observedPlaybackGeneration: observedPlaybackGeneration) else { return }
                self.diagnostics.sample(player: self.player)
                self.runHDRProbeIfNeeded()
                self.maintainForwardBufferTarget()
                self.maybeAdaptBitrateAfterHealthyPlayback()
                self.maybeRecordDiagnosticSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsObservers.storeTimer(timer)
    }

    /// Run the runtime HDR probe (#195) for the current item and publish the result to
    /// Stats. Fired on `.readyToPlay` and retried from the 1s diagnostics tick until the
    /// probe sees real format descriptions — HLS items expose none until segments load.
    private func runHDRProbeIfNeeded() {
        guard !hdrProbeConclusive, let item = player.currentItem else { return }
        let eligible = AVPlayer.eligibleForHDRPlayback
        let observedPlaybackGeneration = playbackGeneration
        Task { @MainActor [weak self] in
            let result = await PlaybackHDRProbe.probe(playerItem: item, eligibleForHDRPlayback: eligible)
            guard let self, self.player.currentItem === item,
                  self.isCurrentPlaybackLifecycle(observedPlaybackGeneration) else { return }
            self.diagnostics.applyRuntimeHDRProbe(result)
            self.hdrProbeConclusive = result.sawVideoFormatDescriptions
        }
    }

    private func maintainForwardBufferTarget() {
        guard isRemoteTranscode,
              activeForwardBufferTargetSeconds > PlaybackBufferingPolicy.remoteHLSSeekReopenForwardBufferSeconds,
              let currentItem = player.currentItem else { return }

        if currentItem.preferredForwardBufferDuration != activeForwardBufferTargetSeconds {
            currentItem.preferredForwardBufferDuration = activeForwardBufferTargetSeconds
        }
        if !currentItem.canUseNetworkResourcesForLiveStreamingWhilePaused {
            currentItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }
        if !player.automaticallyWaitsToMinimizeStalling {
            player.automaticallyWaitsToMinimizeStalling = true
        }
    }

    private func installObservers(for playerItem: AVPlayerItem,
                                  resumeOffsetMs: Int?,
                                  itemGeneration: Int,
                                  observedPlaybackGeneration: Int) {
        // Defensive current-item monitor for reload/reopen edges. The per-item observers below
        // are tied to the AVPlayerItem we intentionally loaded; if AVFoundation drops to nil or a
        // different item without going through our `load(_:)` path, the chrome can otherwise keep
        // reporting the stale pending resume/seek target. Log it for postmortems and force the
        // user-facing clock/status back to the live player state.
        observers.store(player.observe(\.currentItem, options: [.new]) { [weak self] avPlayer, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isCurrentPlaybackLifecycle(observedPlaybackGeneration) else { return }
                let current = avPlayer.currentItem
                let matchesExpectedItem = current === playerItem
                let liveMs = self.livePlaybackClockMs
                let suppressLiveResumeUpdate = liveMs.map {
                    self.isTransientZeroComparedToKnownPlayhead($0)
                } ?? false
                self.recordPlaybackDiagnostic("playback.current_item_changed", fields: [
                    "has_item": .bool(current != nil),
                    "matches_expected_item": .bool(matchesExpectedItem),
                    "item_generation": .int(itemGeneration),
                    "current_item_generation": .int(self.currentPlayerItemGeneration),
                    "observed_playback_generation": .int(observedPlaybackGeneration),
                    "playback_generation": .int(self.playbackGeneration),
                    "live_position": .millisecondsBucket(liveMs),
                    "live_resume_update_suppressed": .bool(suppressLiveResumeUpdate),
                    "pending_resume": .millisecondsBucket(self.pendingResumeMs),
                ])

                guard self.currentPlayerItemGeneration == itemGeneration,
                      self.isCurrentPlaybackLifecycle(observedPlaybackGeneration),
                      !matchesExpectedItem else { return }

                if let liveMs, !suppressLiveResumeUpdate {
                    self.noteResumeClockDesyncIfNeeded(liveMs: liveMs)
                    self.setPendingResumeMs(liveMs, cause: .currentItemChangedLive)
                    self.rememberTrustworthyPlaybackPosition(liveMs,
                                                             cause: .currentItemChangedLive,
                                                             allowsNearZero: false)
                }
                if current == nil {
                    self.timeline.isReadyForReporting = false
                    self.setSeeking(false)
                    if !self.userWantsPaused, !self.playbackError.isFailed {
                        self.beginReconnectStatus()
                    }
                }
                self.updateTransportStatus()
            }
        })

        // Observe item status for its WHOLE lifetime (P4 #8): handle both the resume
        // seek on `.readyToPlay` AND a later `.failed`. The old code self-nilled this
        // observation inside the readyToPlay branch, so a subsequent ready→failed
        // transition (e.g. transcode dies mid-stream) was never seen.
        observers.store(playerItem.observe(\.status, options: [.new]) { [weak self] pItem, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isCurrentObservedItem(pItem,
                                                 itemGeneration: itemGeneration,
                                                 observedPlaybackGeneration: observedPlaybackGeneration) else {
                    self.recordIgnoredPlayerItemEvent("item_status",
                                                      playerItem: pItem,
                                                      itemGeneration: itemGeneration,
                                                      observedPlaybackGeneration: observedPlaybackGeneration)
                    return
                }
                switch pItem.status {
                case .readyToPlay:
                    // Ready item = preparation over, even when a user pause means no
                    // timeControlStatus transition will ever arrive for this item.
                    self.endItemPreparation()
                    self.recordPlaybackDiagnostic("playback.item_status", fields: [
                        "status": .label("readyToPlay"),
                        "duration": .secondsBucket(pItem.duration.seconds),
                    ])
                    self.playbackItemLoadSpan?.end(fields: [
                        "path_mode": self.performancePathMode,
                        "duration_seconds": pItem.duration.seconds.isFinite ? Int(pItem.duration.seconds) : 0,
                    ])
                    self.playbackItemLoadSpan = nil
                    // Gate timeline/scrobble heartbeats until we actually have content +
                    // a real duration (P8 #11) so we don't post duration=0/time≈0.
                    let durSecs = pItem.duration.seconds
                    if durSecs.isFinite && durSecs > 0 {
                        self.timeline.isReadyForReporting = true
                    }
                    // Reapply the user's saved subtitle-language preference to this item's
                    // legible group (once per item; gated inside). Runs on each fresh item —
                    // including after a Quality reload swaps the AVPlayerItem.
                    await self.applySavedSubtitlePreferenceIfNeeded(
                        playerItem: pItem,
                        itemGeneration: itemGeneration,
                        observedPlaybackGeneration: observedPlaybackGeneration)
                    guard self.isCurrentObservedItem(pItem,
                                                     itemGeneration: itemGeneration,
                                                     observedPlaybackGeneration: observedPlaybackGeneration) else { return }
                    // Likewise reapply the saved audio-language preference to this item's
                    // audible group (#3; once per item, gated inside).
                    await self.applySavedAudioPreferenceIfNeeded(
                        playerItem: pItem,
                        itemGeneration: itemGeneration,
                        observedPlaybackGeneration: observedPlaybackGeneration)
                    guard self.isCurrentObservedItem(pItem,
                                                     itemGeneration: itemGeneration,
                                                     observedPlaybackGeneration: observedPlaybackGeneration) else { return }
                    // Reapply the persisted playback speed (R5). A fresh item / Quality reload
                    // resets the player's rate to 1.0, so re-push the user's choice now that the
                    // item is ready — without this a reload would silently drop back to 1.0×.
                    if self.userWantsPaused {
                        self.player.pause()
                        self.buffering.set(false)
                        self.transport.set(paused: true)
                        self.transport.setPauseRequested(false)
                        self.updateTransportStatus()
                        self.recordPlaybackDiagnostic("playback.pause_intent_honored", fields: [
                            "status": .label("readyToPlay"),
                        ])
                    } else {
                        self.applyPlaybackSpeed()
                    }
                    self.refreshVideoNowPlayingMetadata(
                        elapsedMillisecondsOverride: resumeOffsetMs,
                        playbackRateOverride: self.userWantsPaused ? 0 : nil)
                    // Resume seek, exactly once (didSeek). Offset priming is the fast
                    // path; this is the CLIENT-SIDE FALLBACK (P2 #9): if PMS didn't honor
                    // `#EXT-X-START` and we're sitting at ~0 while a resume was requested,
                    // seek there ourselves.
                    if !self.didSeek, let resumeOffsetMs, resumeOffsetMs > 0 {
                        let current = self.player.currentTime().seconds
                        let nearZero = !current.isFinite || current < 1.0
                        if nearZero, !self.isRemoteTranscode {
                            let target = CMTime(value: CMTimeValue(resumeOffsetMs), timescale: 1000)
                            let tolerance: CMTime = .zero
                            self.player.seek(to: target,
                                             toleranceBefore: tolerance,
                                             toleranceAfter: tolerance,
                                             completionHandler: { [weak self = self,
                                                                   weak pItem = pItem,
                                                                   itemGeneration,
                                                                   observedPlaybackGeneration] finished in
                                                 guard finished else { return }
                                                 Task { @MainActor [weak self = self,
                                                                    weak pItem = pItem,
                                                                    itemGeneration,
                                                                    observedPlaybackGeneration] in
                                                     guard let self, let pItem,
                                                           self.isCurrentObservedItem(pItem,
                                                                                      itemGeneration: itemGeneration,
                                                                                      observedPlaybackGeneration: observedPlaybackGeneration),
                                                           !self.userWantsPaused else { return }
                                                     self.applyPlaybackSpeed()
                                                     self.refreshVideoNowPlayingMetadata()
                                                 }
                                             })
                        }
                        self.didSeek = true
                    }
                    // A rebuild/reopen-backed user seek holds the scrubber on its target until the
                    // fresh item is ready at/after that target; release the hold now (GH #110).
                    self.clearSeekHoldIfLanded()
                    self.maybeRecordDiagnosticSnapshot(force: true)
                case .failed:
                    self.recordPlaybackDiagnostic("playback.item_status", fields: [
                        "status": .label("failed"),
                        "error": .error(pItem.error),
                    ])
                    self.playbackItemLoadSpan?.end(result: "failure", fields: ["path_mode": self.performancePathMode])
                    self.playbackItemLoadSpan = nil
                    self.playbackStartupSpan?.end(result: "failure", fields: ["path_mode": self.performancePathMode])
                    self.playbackStartupSpan = nil
                    self.handlePlaybackFailure(pItem.error,
                                               source: .itemStatusFailed,
                                               playerItem: pItem,
                                               itemGeneration: itemGeneration,
                                               observedPlaybackGeneration: observedPlaybackGeneration)
                default:
                    break
                }
            }
        })

        // A start.m3u8 that begins playing but then dies (transcode tears down, segment
        // 404s) fires this rather than flipping item.status (P3 #8). Treat it the same.
        observers.storeNotification(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                guard let self else { return }
                self.handleFailedToPlayToEnd(error,
                                             playerItem: playerItem,
                                             itemGeneration: itemGeneration,
                                             observedPlaybackGeneration: observedPlaybackGeneration)
            }
        })

        // GH #196: AVFoundation's startup-deadline abandonments never flip `item.status` —
        // the item sits at `.unknown` forever while the error LOG records the real story
        // (-12889/-16830 per media file, then terminal -12880 once the only variant is
        // removed). Watch the error log directly: every event is persisted for diagnosis,
        // and the terminal -12880 triggers the one-shot warm retry / accurate failure
        // surface instead of waiting out the stall watchdog with a misleading message.
        observers.storeNotification(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentObservedItem(playerItem,
                                                 itemGeneration: itemGeneration,
                                                 observedPlaybackGeneration: observedPlaybackGeneration) else { return }
                guard let event = playerItem.errorLog()?.events.last else { return }
                self.recordPlaybackDiagnostic("playback.error_log_event", fields: [
                    "error_log_status_code": .int(event.errorStatusCode),
                    "error_log_domain": .label(event.errorDomain),
                    "error_log_comment": .text(event.errorComment),
                ])
                NSLog("PlaybackController: item error log %d (%@) %@",
                      event.errorStatusCode, event.errorDomain, event.errorComment ?? "-")
                // Several entries can be appended before ONE notification posts (seen live:
                // -12880 then -15628 in the same batch), so scan the log rather than trusting
                // `events.last` to be the terminal code.
                let sawVariantsRemoved = (playerItem.errorLog()?.events ?? [])
                    .contains { $0.errorStatusCode == HLSStartupDeadlinePolicy.variantsRemovedCode }
                guard sawVariantsRemoved,
                      self.isCurrentObservedItem(playerItem,
                                                 itemGeneration: itemGeneration,
                                                 observedPlaybackGeneration: observedPlaybackGeneration) else {
                    return
                }
                self.handleStartupVariantAbandonment(playerItem)
            }
        })

        // Final-target rebuild recovery (#33 reset): `timeJumpedNotification` is the only
        // in-process signal of a user seek on visionOS. In-buffer jumps stay native;
        // out-of-buffer jumps are debounced and rebuilt once at the settled target.
        observers.storeNotification(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentObservedItem(playerItem,
                                                 itemGeneration: itemGeneration,
                                                 observedPlaybackGeneration: observedPlaybackGeneration) else {
                    self.recordIgnoredPlayerItemEvent("time_jumped",
                                                      playerItem: playerItem,
                                                      itemGeneration: itemGeneration,
                                                      observedPlaybackGeneration: observedPlaybackGeneration)
                    return
                }
                self.handleSeekJump()
            }
        })

        // Periodic heartbeat ~ every 10s.
        let interval = CMTime(seconds: timelineIntervalSeconds, preferredTimescale: 1)
        observers.storeTimeObserver(player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.lifecycleCallbacks.accepts(.videoHeartbeat, generation: observedPlaybackGeneration),
                      self.isCurrentObservedItem(playerItem,
                                                 itemGeneration: itemGeneration,
                                                 observedPlaybackGeneration: observedPlaybackGeneration) else { return }
                let state: TimelineRequest.State = self.player.timeControlStatus == .paused ? .paused : .playing
                self.timeline.report(state: state, force: false)
                self.recordLocalPlaybackPosition()
                // Progress-based scrobble (P9 #11): capped-HLS viewers often stop short of
                // EOF, so didPlayToEnd never fires and the item stays "unwatched." Mark it
                // watched once we cross ~90%; didPlayToEnd remains the backstop.
                self.timeline.scrobbleIfNearEnd()
            }
        })

        // Marker detection (#14): a finer ~0.5s observer that toggles the Skip
        // Intro/Skip Credits button as the playhead enters/leaves an intro/credits range.
        // Separate from the 10s heartbeat above, which is too coarse for a live button.
        let markerInterval = CMTime(seconds: 0.5, preferredTimescale: 600)
        observers.storeTimeObserver(player.addPeriodicTimeObserver(forInterval: markerInterval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                guard self.lifecycleCallbacks.accepts(.videoMarker, generation: observedPlaybackGeneration),
                      self.isCurrentObservedItem(playerItem,
                                                 itemGeneration: itemGeneration,
                                                 observedPlaybackGeneration: observedPlaybackGeneration) else { return }
                if time.seconds.isFinite {
                    self.rememberTrustworthyPlaybackPosition(Int((max(0, time.seconds) * 1000).rounded()),
                                                             cause: .periodicLive,
                                                             allowsNearZero: false)
                }
                self.updateSkipMarker(at: time.seconds)
                // Drive the Up Next card (#15) off the same fine-grained observer.
                self.updateUpNext(at: time.seconds)
                self.updateOfflineSubtitleOverlay(at: time.seconds)
            }
        })

        // Single observer for `\.timeControlStatus` driving BOTH the transport/diagnostics
        // update and the rebuffer/stall spinner (#21). These were previously two separate
        // `observe()` calls on the same keypath; each hopped to the main actor via its own
        // Task, and FIFO Task ordering meant the transport handler effectively ran before the
        // spinner handler. We preserve that order explicitly here: `handleTimeControlTransport`
        // MUST run before `handleTimeControlBuffering` (the latter clears a surfaced error and
        // signals "playback active", which is conceptually downstream of the transport state).
        observers.store(player.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            guard let self else { return }
            let status = avPlayer.timeControlStatus
            Task { @MainActor in
                guard self.lifecycleCallbacks.accepts(.videoPlaying, generation: observedPlaybackGeneration),
                      self.isCurrentObservedItem(playerItem,
                                                 itemGeneration: itemGeneration,
                                                 observedPlaybackGeneration: observedPlaybackGeneration) else { return }
                self.handleTimeControlTransport(status: status)
                self.handleTimeControlBuffering(status: status)
            }
        })

        // Scrobble on completion.
        observers.storeNotification(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentObservedItem(playerItem,
                                                 itemGeneration: itemGeneration,
                                                 observedPlaybackGeneration: observedPlaybackGeneration) else {
                    self.recordIgnoredPlayerItemEvent("did_play_to_end",
                                                      playerItem: playerItem,
                                                      itemGeneration: itemGeneration,
                                                      observedPlaybackGeneration: observedPlaybackGeneration)
                    return
                }
                // FINDING 7: a seek landing at/near EOF can play straight to the end without the
                // live clock crossing `target - slack` (and possibly without a distinct `.playing`
                // transition the hold observer catches). Reaching end-of-time is a definitive
                // "seek settled" signal, so release any in-flight hold here too rather than leaving
                // it for the 12s ceiling. No-op when not seeking.
                if self.isSeeking { self.setSeeking(false) }
                self.maybeRecordDiagnosticSnapshot(force: true)
                self.recordPlaybackDiagnostic("playback.ended", fields: [
                    "resume": .millisecondsBucket(self.currentResumeMs),
                ])
                self.timeline.report(state: .stopped, force: true)
                self.recordLocalPlaybackPosition()
                self.timeline.scrobble()
                // Play-to-end with a resolved, un-cancelled next item: autoplay it (#15).
                // `advanceToNextItem` re-flushes timeline/scrobble idempotently.
                if self.upNext.nextItem != nil, !self.upNext.isCancelled, self.autoPlayUpNextEnabled {
                    self.advanceToNextItem()
                } else {
                    self.player.pause()
                    self.refreshVideoNowPlayingMetadata(playbackRateOverride: 0)
                    self.stopVideoNowPlayingSession()
                    self.onPlaybackEnded?()
                }
            }
        })
    }

    /// Transport/diagnostics half of the merged `\.timeControlStatus` observation. Runs
    /// BEFORE `handleTimeControlBuffering` (see the observer comment).
    @MainActor
    private func handleTimeControlTransport(status: AVPlayer.TimeControlStatus) {
        currentTimeControlStatus = status
        hasObservedTimeControlStatus = true
        // First live signal from the fresh item: the preparation window is over and the
        // normal timeControlStatus-driven machinery owns the overlay from here.
        endItemPreparation()
        // FINDING 7: a seek near end-of-file can settle at a live clock that never crosses
        // `target - slack` (the file ends first), so the tick-loop "landed" check
        // (`clearSeekHoldIfLanded`) would never release the hold and the label (and
        // `currentResumeMs`, which returns `seekHoldTargetMs` while held) would stay frozen until
        // the 12s ceiling. The player reaching `.playing` after a seek means playback genuinely
        // resumed wherever it landed, so release the hold immediately. Independent of the clock
        // threshold; the ceiling remains only as a last-ditch backstop. Cheap no-op when not
        // seeking (clearSeekHold's own guard handles that).
        if status == .playing, isSeeking {
            NSLog("PlaybackController: seek hold released by timeControlStatus=.playing (target=%@)",
                  seekHoldTargetMs.map { String($0) } ?? "nil")
            setSeeking(false)
        }
        let paused = status == .paused || self.userWantsPaused
        self.timeline.report(state: paused ? .paused : .playing, force: true)
        if paused || status == .playing { self.recordLocalPlaybackPosition() }
        self.transport.set(paused: paused)
        if paused || status == .playing {
            self.transport.setPauseRequested(false)
        }
        refreshVideoNowPlayingMetadata(playbackRateOverride: paused ? 0 : nil)
        if self.lastDiagnosticTimeControlStatus != status {
            self.lastDiagnosticTimeControlStatus = status
            self.recordPlaybackDiagnostic("playback.time_control_status", fields: [
                "status": .label(Self.timeControlStatusLabel(status)),
            ])
        }
        updateTransportStatus()
    }

    /// Rebuffer/stall-spinner half (#21) of the merged `\.timeControlStatus` observation.
    /// `timeControlStatus` is the precise signal: the player is `.waitingToPlayAtSpecifiedRate`
    /// exactly while it's stalled waiting on data (or the initial prime), `.playing` once it has
    /// enough, and `.paused` when the USER pauses — so reading this status alone correctly avoids
    /// showing the spinner on a manual pause. Runs AFTER `handleTimeControlTransport`.
    @MainActor
    private func handleTimeControlBuffering(status: AVPlayer.TimeControlStatus) {
        let isStalled = (status == .waitingToPlayAtSpecifiedRate && !self.userWantsPaused)
        self.buffering.set(isStalled)
        updateTransportStatus()
        // Stall watchdog (#8 hardening): a network-loss stall often never flips
        // item.status to .failed, so arm a timeout while the player is starved and
        // cancel it the instant playback genuinely resumes. We deliberately do NOT
        // cancel on `.paused` — handleStallTimeout's buffer-empty check distinguishes a
        // dead stall from a user pause on already-buffered content.
        if isStalled {
            self.armStallWatchdog()
        } else if status == .playing {
            self.hasObservedPlayback = true
            if let liveMs = self.rawPlayerClockMs {
                self.rememberTrustworthyPlaybackPosition(liveMs,
                                                         cause: .timeControlPlaying,
                                                         allowsNearZero: false)
            }
            self.playbackStartupSpan?.end(fields: ["path_mode": self.performancePathMode])
            self.playbackStartupSpan = nil
            self.cancelStallWatchdog()
            self.cancelDVGuardWatchdog()
            // Real playback = the failure is over. Clear any surfaced error so its
            // Retry/Close affordance can't linger over playing video: a stall we
            // surfaced (handleStallTimeout pauses + sets the error) sometimes recovers
            // and resumes anyway — in the expanded cinema scene the pause doesn't always
            // hold — and without this the AVKit Retry/Close pills stay stuck on screen,
            // reading as dead because the state behind them no longer matches (seen live).
            self.playbackError.clear()
            self.finishReconnectStatus()
            self.updateTransportStatus()
            self.onPlaybackActive?()
        }
    }

    private func removeObservers() {
        // Cancel the stall watchdog so a stale timer can't fire across a reload / Retry /
        // teardown and surface an error against a freshly-loaded item.
        cancelStallWatchdog()
        cancelDVGuardWatchdog()
        // Drop any armed final-target rebuild so a debounced timer can't fire against a freshly-loaded item.
        cancelPendingFinalTargetRebuild()
        // Clear any lingering spinner state across a reload/teardown so it can't get stuck on.
        buffering.set(false)
        updateTransportStatus()
        diagnosticsObservers.reset()
        observers.reset()
    }


    // MARK: - Transport status overlay

    private func beginReconnectStatus() {
        reconnectInProgress = true
        updateTransportStatus()
        armReconnectWatchdog()
    }

    private func finishReconnectStatus() {
        guard reconnectInProgress || reconnectWatchdogTask != nil else { return }
        reconnectInProgress = false
        reconnectWatchdogAuthority.end()
        reconnectWatchdogTask?.cancel()
        reconnectWatchdogTask = nil
        updateTransportStatus()
    }

    private func endReconnectStatus() {
        reconnectInProgress = false
        reconnectWatchdogAuthority.end()
        reconnectWatchdogTask?.cancel()
        reconnectWatchdogTask = nil
        updateTransportStatus()
    }

    private func armReconnectWatchdog() {
        reconnectWatchdogTask?.cancel()
        // Recovery deliberately replaces the player item after this deadline is armed,
        // so its authority must span playbackGeneration changes.
        let token = reconnectWatchdogAuthority.arm()
        reconnectWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self,
                  self.reconnectWatchdogAuthority.accepts(token),
                  self.reconnectInProgress else { return }
            self.surfaceReconnectTimeout()
        }
    }

    // MARK: - Item preparation window (black-screen indicator coverage)

    /// Enter the preparation window: called at the top of every begin/reopen lane so the
    /// buffering overlay covers detach → negotiate → prewarm → proxy standup → load instead
    /// of the stale-KVO `.none` fallthrough. Local-file loads skip this (synchronous attach).
    private func beginItemPreparation() {
        itemPreparationInProgress = true
        updateTransportStatus()
    }

    /// Leave the preparation window. Safe to call repeatedly; cheap no-op when not preparing.
    /// Called on the fresh item's first `timeControlStatus` KVO, on `.readyToPlay` (a
    /// user-paused load never produces a KVO transition), on `surfaceFailure`, and on `stop()`.
    private func endItemPreparation() {
        guard itemPreparationInProgress || itemPreparationWatchdogTask != nil else { return }
        itemPreparationInProgress = false
        itemPreparationWatchdogTask?.cancel()
        itemPreparationWatchdogTask = nil
        itemPreparationProgressBaseline = nil
        updateTransportStatus()
    }

    /// GH #33 first-start coverage: a poisoned cold `start.m3u8` can hang after attach with no
    /// AVPlayer error and no `timeControlStatus` transition, so neither the stall watchdog nor
    /// `handlePlaybackFailure` ever fires. The recovery paths (retry, seek-hold ceiling, zombie
    /// escalation) are protected by the 20s reconnect watchdog; this is the same net for the
    /// preparation window, armed in `load()` once the item is attached. Progress-deferred like
    /// the stall watchdog so a slow-but-working prime is never false-failed.
    private func armItemPreparationWatchdog() {
        itemPreparationWatchdogTask?.cancel()
        itemPreparationProgressBaseline = currentStallProgressSignature()
        let observedPlaybackGeneration = playbackGeneration
        itemPreparationWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.isCurrentPlaybackLifecycle(observedPlaybackGeneration) else { return }
            self.handleItemPreparationTimeout()
        }
    }

    private func handleItemPreparationTimeout() {
        let baseline = itemPreparationProgressBaseline
        itemPreparationWatchdogTask = nil
        itemPreparationProgressBaseline = nil
        guard itemPreparationInProgress, !playbackError.isFailed else { return }
        // A user pause during preparation legitimately never transitions the status; hold the
        // net open rather than failing a session the user asked to wait.
        if userWantsPaused || stallMadeTransportProgress(since: baseline) {
            recordPlaybackDiagnostic("playback.item_preparation_watchdog_deferred", fields: [
                "user_wants_paused": .bool(userWantsPaused),
            ])
            armItemPreparationWatchdog()
            return
        }
        recordPlaybackDiagnostic("playback.item_preparation_watchdog_fired", fields: [
            "resume": .millisecondsBucket(currentResumeMs),
        ])
        NSLog("PlaybackController: item preparation watchdog timed out, surfacing failure (#33 first start)")
        surfaceFailure(ReconnectTimeoutError())
    }

    private func updateTransportStatus() {
        let nextStatus = resolvedTransportStatus()
        transportStatus.set(nextStatus)
        guard nextStatus != lastLoggedTransportStatus else { return }
        lastLoggedTransportStatus = nextStatus
        recordPlaybackDiagnostic("playback.transport_status", fields: [
            "status": .label(nextStatus.diagnosticLabel),
            "time_control_status": .label(Self.timeControlStatusLabel(currentTimeControlStatus)),
            "has_observed_time_control_status": .bool(hasObservedTimeControlStatus),
            "user_wants_paused": .bool(userWantsPaused),
            "has_observed_playback": .bool(hasObservedPlayback),
            "reconnecting": .bool(reconnectInProgress),
            "item_preparing": .bool(itemPreparationInProgress),
            "failed": .bool(playbackError.isFailed),
        ])
    }

    private func resolvedTransportStatus() -> PlaybackTransportStatus {
        let isPaused = userWantsPaused || transport.pauseRequested || transport.isPaused
        // Preparation window: a begin/reopen lane is producing a fresh item, so the cached
        // KVO fields below hold the PREVIOUS item's last value (usually `.playing`) until
        // `load()` resets them — both the waiting-status guard and the isSeeking branch are
        // defeated by that staleness, and the viewer would get dead chrome over a black,
        // detached surface for the whole negotiate/prewarm/proxy window. A rebuild-backed user
        // seek has the same gap after replacing its item and before the first KVO callback.
        let isAwaitingFreshItemObservation = isSeeking && !hasObservedTimeControlStatus
        let isWaitingForMedia = itemPreparationInProgress
            || (hasObservedTimeControlStatus
                && currentTimeControlStatus == .waitingToPlayAtSpecifiedRate)
            || isAwaitingFreshItemObservation

        return PlaybackTransportPresentationPolicy.status(.init(
            source: sessionSource.kind == .offline ? .localFile : .remote,
            isFailed: playbackError.isFailed,
            failureMessage: playbackError.message,
            isReconnecting: reconnectInProgress,
            isWaitingForMedia: isWaitingForMedia,
            isPaused: isPaused,
            hasObservedPlayback: hasObservedPlayback
        ))
    }

    // MARK: - Skip markers (#14)

    /// Update the live Skip affordance for the given playhead time (seconds). Shows the
    /// button while the playhead sits inside an intro/credits range — minus a small tail
    /// before the end so it doesn't flicker off right at the boundary — and clears it
    /// otherwise. The first matching range wins (intro and credits never overlap in
    /// practice). No-op when the item carries no intro/credits markers, so the button
    /// simply never appears.
    private func updateSkipMarker(at seconds: Double) {
        guard seconds.isFinite, !skipRanges.isEmpty else {
            if skipMarker.active != nil { skipMarker.clear() }
            return
        }
        let match = skipRanges.first { range in
            seconds >= range.startSeconds
                && seconds < max(range.startSeconds, range.endSeconds - skipMarkerTailSeconds)
        }
        if let match {
            let mode = skipMode(for: match.kind)
            switch mode {
            case .disabled:
                skipMarker.clear()
            case .manual:
                skipMarker.set(kind: match.kind, seekTargetSeconds: match.endSeconds)
            case .automatic:
                performUserSeek(toMs: Int(match.endSeconds * 1000))
                skipMarker.clear()
            }
        } else if skipMarker.active != nil {
            skipMarker.clear()
        }
    }

    /// Seek the player to the active marker's end and dismiss the Skip button. Uses
    /// zero tolerance so we land precisely past the intro/credits boundary. No-op when no
    /// marker is currently active.
    func skipCurrentMarker() {
        guard let active = skipMarker.active else { return }
        performUserSeek(toMs: Int(active.seekTargetSeconds * 1000))
        skipMarker.clear()
    }

    // MARK: - Up Next (#15)

    /// Seconds-before-end at which the Up Next card appears when the item carries no
    /// credits marker. (When a credits marker IS present, its start is used instead.)
    private let upNextTailSeconds: Double = 30

    /// Countdown (seconds) shown on the Up Next card before it autoplays the next item.
    private var upNextCountdownStart: Int {
        PlaybackPreferences.upNextCountdownSeconds()
    }

    private var autoPlayUpNextEnabled: Bool {
        PlaybackPreferences.autoPlayUpNext()
    }

    private func skipMode(for kind: SkipMarkerState.Kind) -> PlaybackPreferences.SkipMode {
        PlaybackPreferences.skipMode(intro: kind == .intro)
    }

    /// The most recent integer second at which the countdown was ticked, so the 0.5s marker
    /// observer only decrements once per wall-clock second (it fires twice per second).
    private var upNextLastCountdownSecond: Int = -1

    /// Resolve the next item to play after the current one (#15). ONLY for episodes — for
    /// movies (and anything without a "next") there is no Up Next, which is correct and
    /// graceful. Uses the Plex play-queue API (`POST /playQueues` with `continuous=1`),
    /// which returns an ORDERED queue with the current item selected; the entry right after
    /// the selected offset is the next episode (PMS resolves season/show boundaries for us,
    /// so we don't need grandparent/index fields that `MediaItem` doesn't expose). The
    /// resolved item is a Sendable Codable model, so it crosses back to the main actor
    /// cleanly. Best-effort: any failure leaves `upNext.nextItem` nil and the card hidden.
    private func resolveNextItem(observedPlaybackGeneration: Int) async {
        guard item.type == "episode" else { return }
        guard let server, let token, let machineIdentifier else { return }

        let req = PlayQueue.createRequest(server: server,
                                          token: token,
                                          identity: identity,
                                          machineIdentifier: machineIdentifier,
                                          ratingKey: item.ratingKey,
                                          type: "video",
                                          continuous: true)
        guard let resp = try? await client.send(req, as: PlayQueueResponse.self) else { return }
        guard isCurrentPlaybackLifecycle(observedPlaybackGeneration) else { return }

        let queue = resp.mediaContainer.metadata
        guard !queue.isEmpty else { return }

        // Find the current item in the queue. Prefer the server-reported selected offset;
        // fall back to locating our ratingKey directly (PMS doesn't always echo an offset).
        let currentIndex: Int? = {
            if let offset = resp.mediaContainer.playQueueSelectedItemOffset,
               queue.indices.contains(offset),
               queue[offset].ratingKey == item.ratingKey {
                return offset
            }
            return queue.firstIndex { $0.ratingKey == item.ratingKey }
        }()

        guard let idx = currentIndex, queue.indices.contains(idx + 1) else {
            // No next item (e.g. last episode of the series). Leave the card hidden.
            return
        }
        let next = queue[idx + 1]
        // Only auto-advance within the same kind (episode → episode); skip any trailing
        // non-episode queue entry just in case.
        guard next.type == "episode" else { return }
        guard isCurrentPlaybackLifecycle(observedPlaybackGeneration) else { return }
        upNext.setNextItem(next)
    }

    /// Drive the Up Next card from the playhead (called by the 0.5s marker observer). Shows
    /// the card once the playhead enters the "near end" window — the credits marker start if
    /// present, else the last `upNextTailSeconds` — and ticks the countdown once per second
    /// while shown. At zero (or on play-to-end) it advances, unless the user cancelled.
    private func updateUpNext(at seconds: Double) {
        // Nothing to show if there's no resolved next item or the user dismissed it.
        guard upNext.nextItem != nil, !upNext.isCancelled, autoPlayUpNextEnabled else { return }
        guard seconds.isFinite else { return }

        let durSecs = player.currentItem?.duration.seconds ?? 0
        guard durSecs.isFinite, durSecs > 0 else { return }

        // Trigger point: prefer the credits marker start; otherwise the last N seconds.
        let creditsStart = skipRanges.first { $0.kind == .credits }?.startSeconds
        let triggerAt = creditsStart ?? max(0, durSecs - upNextTailSeconds)

        guard seconds >= triggerAt else {
            // Before the window: ensure the card is hidden (e.g. user seeked backwards).
            if upNext.isShown {
                upNext.hide()
                upNextLastCountdownSecond = -1
            }
            return
        }

        // Inside the window: show the card and start/continue the countdown.
        if !upNext.isShown {
            let countdown = max(0, upNextCountdownStart)
            if countdown == 0 {
                advanceToNextItem()
                return
            }
            upNext.show(countdown: countdown)
            upNextLastCountdownSecond = Int(seconds)
            return
        }

        // Tick the countdown at most once per wall-clock second.
        let nowSecond = Int(seconds)
        if nowSecond != upNextLastCountdownSecond {
            upNextLastCountdownSecond = nowSecond
            let remaining = upNext.countdown - 1
            if remaining <= 0 {
                advanceToNextItem()
            } else {
                upNext.setCountdown(remaining)
            }
        }
    }

    /// User tapped "Play Now" on the Up Next card: advance immediately.
    func playNextNow() {
        advanceToNextItem()
    }

    /// User dismissed the Up Next card: suppress autoplay for THIS item (the card won't
    /// reappear until the next item rebuilds the controller).
    func cancelUpNext() {
        upNext.cancel()
        upNextLastCountdownSecond = -1
    }

    /// Advance to the resolved next item. Flushes a final timeline + scrobble for the
    /// finishing episode (so Continue Watching / watched state is correct) before handing
    /// the next item to the presenter, which swaps the presented item and rebuilds this
    /// view/controller. Idempotent via `upNext.isAdvancing`.
    private func advanceToNextItem() {
        guard let next = upNext.nextItem, !upNext.isAdvancing else { return }
        upNext.beginAdvancing()
        // Make sure the finished episode's progress is reported before we tear down.
        timeline.report(state: .stopped, force: true)
        timeline.scrobble()
        player.pause()
        refreshVideoNowPlayingMetadata(playbackRateOverride: 0)
        onAdvanceToNext?(next)
    }

    // MARK: - Failure handling

    private func isCurrentObservedItem(_ observedItem: AVPlayerItem,
                                       itemGeneration: Int,
                                       observedPlaybackGeneration: Int) -> Bool {
        player.currentItem === observedItem &&
            currentPlayerItemGeneration == itemGeneration &&
            isCurrentPlaybackLifecycle(observedPlaybackGeneration)
    }

    private func isCurrentPlaybackLifecycle(_ observedPlaybackGeneration: Int) -> Bool {
        VideoPlaybackLifecyclePolicy.accepts(
            capturedGeneration: observedPlaybackGeneration,
            currentGeneration: playbackGeneration,
            isCancelled: Task.isCancelled)
    }

    private func recordIgnoredPlayerItemEvent(_ event: String,
                                              playerItem: AVPlayerItem,
                                              itemGeneration: Int,
                                              observedPlaybackGeneration: Int) {
        recordPlaybackDiagnostic("playback.item_event_ignored", fields: [
            "event": .label(event),
            "reason": .label("stale_item"),
            "current_item": .bool(player.currentItem === playerItem),
            "item_generation": .int(itemGeneration),
            "current_item_generation": .int(currentPlayerItemGeneration),
            "observed_playback_generation": .int(observedPlaybackGeneration),
            "playback_generation": .int(playbackGeneration),
        ])
    }

    private func handleFailedToPlayToEnd(_ error: Error?,
                                         playerItem: AVPlayerItem,
                                         itemGeneration: Int,
                                         observedPlaybackGeneration: Int) {
        let snapshot = playbackFailureSnapshot(source: .failedToPlayToEnd,
                                               playerItem: playerItem,
                                               error: error)
        var fields = playbackFailureDiagnosticFields(snapshot: snapshot,
                                                     playerItem: playerItem,
                                                     error: error)
        fields["item_generation"] = .int(itemGeneration)
        fields["observed_playback_generation"] = .int(observedPlaybackGeneration)
        guard isCurrentObservedItem(playerItem,
                                    itemGeneration: itemGeneration,
                                    observedPlaybackGeneration: observedPlaybackGeneration) else {
            fields["policy_action"] = .label(PlaybackFailureAction.ignoreStaleItem.rawValue)
            fields["reason"] = .label("stale_item")
            recordPlaybackDiagnostic("playback.failed_to_end", fields: fields)
            recordPlaybackDiagnostic("playback.failed_to_end_ignored", fields: fields)
            return
        }
        let action = PlaybackFailurePolicy.action(for: snapshot)
        fields["policy_action"] = .label(action.rawValue)
        recordPlaybackDiagnostic("playback.failed_to_end", fields: fields)

        switch action {
        case .ignoreStaleItem:
            fields["reason"] = .label("stale_item")
            recordPlaybackDiagnostic("playback.failed_to_end_ignored", fields: fields)
        case .ignoreRecoverableBufferedRemoteHLS:
            ignoredRecoverableFailedToEndCount += 1
            fields["reason"] = .label("buffered_remote_hls_ready_playing")
            recordPlaybackDiagnostic("playback.failed_to_end_ignored", fields: fields)
        case .surface:
            handlePlaybackFailure(error,
                                  source: .failedToPlayToEnd,
                                  playerItem: playerItem,
                                  itemGeneration: itemGeneration,
                                  observedPlaybackGeneration: observedPlaybackGeneration,
                                  contextFields: fields)
        }
    }

    private func playbackFailureSnapshot(source: PlaybackFailureSource,
                                         playerItem: AVPlayerItem?,
                                         error: Error?) -> PlaybackFailureSnapshot {
        let itemIsCurrent = playerItem.map { player.currentItem === $0 } ?? true
        let nsError = error.map { $0 as NSError }
        let itemError = playerItem?.error.map { $0 as NSError }
        let playerError = player.error.map { $0 as NSError }
        let isRemoteHLS = sessionSource.kind == .mediaBrowser && remotePlayMethod != .directPlay
        return PlaybackFailureSnapshot(
            source: source,
            path: isRemoteHLS ? .remoteHLS : .other,
            isCurrentItem: itemIsCurrent,
            isItemReadyToPlay: playerItem?.status == .readyToPlay,
            isPlayerPlaying: player.timeControlStatus == .playing,
            bufferedAheadSeconds: playerItem.map(bufferedAheadSeconds) ?? diagnostics.bufferedAheadSeconds,
            notificationErrorCode: nsError?.code,
            itemErrorCode: itemError?.code,
            playerErrorCode: playerError?.code,
            ignoredRecoverableFailureCount: ignoredRecoverableFailedToEndCount)
    }

    private func playbackFailureDiagnosticFields(snapshot: PlaybackFailureSnapshot,
                                                 playerItem: AVPlayerItem?,
                                                 error: Error?) -> [String: DiagnosticFieldValue] {
        var fields: [String: DiagnosticFieldValue] = [
            "error": .error(error),
            "failure_source": .label(snapshot.source.rawValue),
            "failure_path": .label(snapshot.path.rawValue),
            "current_item": .bool(snapshot.isCurrentItem),
            "item_ready": .bool(snapshot.isItemReadyToPlay),
            "player_playing": .bool(snapshot.isPlayerPlaying),
            "item_status": .label(playerItem.map { Self.itemStatusLabel($0.status) }),
            "player_status": .label(Self.playerStatusLabel(player.status)),
            "time_control_status": .label(Self.timeControlStatusLabel(player.timeControlStatus)),
            "buffer_ahead_seconds": .double(snapshot.bufferedAheadSeconds),
            "likely_to_keep_up": .bool(playerItem?.isPlaybackLikelyToKeepUp ?? false),
            "ignored_recoverable_failed_to_end": .int(snapshot.ignoredRecoverableFailureCount),
            "item_error": .error(playerItem?.error),
            "player_error": .error(player.error),
        ]
        if let code = snapshot.notificationErrorCode {
            fields["notification_error_code"] = .int(code)
        }
        if let nsError = error.map({ $0 as NSError }) {
            fields["notification_error_domain"] = .label(nsError.domain)
            fields["notification_error_domain_family"] = .label(Self.errorDomainFamily(nsError.domain))
        }
        if let code = snapshot.itemErrorCode {
            fields["item_error_code"] = .int(code)
        }
        if let itemError = playerItem?.error.map({ $0 as NSError }) {
            fields["item_error_domain_family"] = .label(Self.errorDomainFamily(itemError.domain))
        }
        if let code = snapshot.playerErrorCode {
            fields["player_error_code"] = .int(code)
        }
        if let playerError = player.error.map({ $0 as NSError }) {
            fields["player_error_domain_family"] = .label(Self.errorDomainFamily(playerError.domain))
        }
        if let errorEvent = playerItem?.errorLog()?.events.last {
            fields["error_log_status_code"] = .int(errorEvent.errorStatusCode)
            fields["error_log_domain"] = .label(errorEvent.errorDomain)
            fields["error_log_comment"] = .text(errorEvent.errorComment)
            fields["error_log_uri_shape"] = .urlShape(errorEvent.uri.flatMap(URL.init(string:)))
        }
        return fields
    }

    private func bufferedAheadSeconds(for playerItem: AVPlayerItem) -> Double {
        let now = player.currentTime().seconds
        guard now.isFinite else { return 0 }
        var bestAhead = 0.0
        for value in playerItem.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            guard start.isFinite, end.isFinite, end >= now else { continue }
            if now >= start - 1 {
                bestAhead = max(bestAhead, max(0, end - now))
            }
        }
        return bestAhead
    }

    /// Surface a playback failure to the UI. No silent auto-retry: a failed PMS stream must not
    /// become a hidden restart loop that can hammer the server. Retry is an explicit user action.
    private func handlePlaybackFailure(_ error: Error?,
                                       source: PlaybackFailureSource = .playerFailure,
                                       playerItem: AVPlayerItem? = nil,
                                       itemGeneration: Int? = nil,
                                       observedPlaybackGeneration: Int? = nil,
                                       contextFields: [String: DiagnosticFieldValue] = [:]) {
        guard !playbackError.isFailed else { return }
        if let playerItem,
           let itemGeneration,
           let observedPlaybackGeneration,
           !isCurrentObservedItem(playerItem,
                                  itemGeneration: itemGeneration,
                                  observedPlaybackGeneration: observedPlaybackGeneration) {
            recordIgnoredPlayerItemEvent(source.rawValue,
                                         playerItem: playerItem,
                                         itemGeneration: itemGeneration,
                                         observedPlaybackGeneration: observedPlaybackGeneration)
            return
        }
        // Direct Play / Maximum, playback-time fallback: a committed direct-play stream that
        // fails to load isn't a hard failure — PMS agreed to copy the video, but AVFoundation
        // couldn't play the resulting literal direct-play HLS rendition. Retry ONCE through
        // production HLS (resuming at the live playhead) instead of surfacing a dead-end. That
        // production path may still Direct Stream/video-copy; it only becomes a maximum transcode
        // when PMS cannot copy video. Armed only while a direct-play stream is live and consumed
        // here, so the rebuild — or any later failure — surfaces normally; the rebuild can't loop
        // back into another direct-play start.
        if directPlayFallbackArmed {
            directPlayFallbackArmed = false
            suppressDirectPlayProbe = true
            let snapshot = playheadSnapshotForRestart(cause: .directPlayRuntimeFallback)
            let resumeMs = snapshot.positionMs
            rejectedDirectPlayStartKeys.insert(Self.directPlayStartRejectionKey(
                metadataKey: item.key ?? "/library/metadata/\(item.ratingKey)",
                mediaIndex: mediaIndex,
                partIndex: 0))
            var fields = positionSnapshotDiagnosticFields(snapshot)
            fields["error"] = .error(error)
            fields["resume"] = .millisecondsBucket(resumeMs)
            fields["fallback"] = .label("production_hls")
            recordTranscodeDiagnostic("transcode.direct_play_runtime_fallback", fields: fields)
            NSLog("PlaybackController: direct-play stream failed to load (%@); falling back to production HLS",
                  Self.safeErrorSummary(error))
            setPendingResumeMs(resumeMs, cause: .directPlayRuntimeFallback, allowsNearZero: true)
            rememberTrustworthyPlaybackPosition(resumeMs,
                                                cause: .directPlayRuntimeFallback,
                                                allowsNearZero: true)
            finalTargetRebuildPolicy.reset()
            removeObservers()
            beginStreaming(resumeOffsetMsOverride: resumeMs)
            return
        }
        // A sibling failure callback on the same dead direct-play item (status `.failed` and
        // `failedToPlayToEndTime` can both fire) — the fallback rebuild is already in flight, so
        // don't surface over it. `suppressDirectPlayProbe` stays set until that rebuild's
        // `startStreaming` consumes it, well before any new item could fail.
        if suppressDirectPlayProbe { return }
        // GH #196: startup-deadline failures also arrive HERE on the MediaBrowser lanes —
        // there the item genuinely flips `.failed` with the CoreMedia code (seen live: an
        // Emby transcode reopen at a deep offset died with -12889 "No response for media
        // file in 6s"). Same one-shot recovery as the error-log path: retry once (backend
        // reopen / warm Plex session), then surface normally. Still no retry LOOP — the
        // one-shot only re-arms after real playback is observed.
        var deadlineCodes = playerItem.map(Self.startupDeadlineCodes(in:)) ?? []
        if let code = (error as NSError?)?.code,
           HLSStartupDeadlinePolicy.isStartupDeadlineCode(code),
           !deadlineCodes.contains(code) {
            deadlineCodes.append(code)
        }
        if !deadlineCodes.isEmpty,
           attemptStartupDeadlineRetry(codes: deadlineCodes, trigger: source.rawValue) {
            return
        }
        var fields = contextFields
        fields["error"] = .error(error)
        fields["failure_source"] = .label(source.rawValue)
        if let itemGeneration {
            fields["item_generation"] = .int(itemGeneration)
        }
        if let observedPlaybackGeneration {
            fields["observed_playback_generation"] = .int(observedPlaybackGeneration)
        }
        recordPlaybackDiagnostic("playback.player_failure", fields: fields)
        NSLog("PlaybackController: playback failed, surfacing to UI (%@)",
              Self.safeErrorSummary(error))
        surfaceFailure(error)
    }

    /// Pause the player, then surface the failure to the UI. Pausing FIRST is what makes the
    /// error/Retry overlay stand alone: while stalled the player sits in
    /// `.waitingToPlayAtSpecifiedRate`, so AVKit paints its own buffering glyph AND our #21
    /// stall spinner (`isBuffering`) stays up — both would render on top of the dialog. Pausing
    /// flips `timeControlStatus` to `.paused`, so AVKit swaps in the static play button and our
    /// `BufferingState` clears (it reports `false` on `.paused`). Recovery still rebuilds the
    /// player from `currentResumeMs` on Retry, so pausing here never strands the playhead.
    private func surfaceFailure(_ error: Error?) {
        // Any surfaced failure ends the in-flight seek — release the scrubber hold so the label
        // can't freeze on the unreachable target (GH #110).
        setSeeking(false)
        cancelPendingFinalTargetRebuild()
        if let activeFinalTargetRebuildGeneration {
            finalTargetRebuildPolicy.cancelRebuild(generation: activeFinalTargetRebuildGeneration)
            self.activeFinalTargetRebuildGeneration = nil
        }
        maybeRecordDiagnosticSnapshot(force: true)
        recordPlaybackDiagnostic("playback.failure_surfaced", fields: [
            "error": .error(error),
            "resume": .millisecondsBucket(currentResumeMs),
        ])
        player.pause()
        refreshVideoNowPlayingMetadata(playbackRateOverride: 0)
        stopVideoNowPlayingSession()
        playbackError.set(error)
        endReconnectStatus()
        endItemPreparation()
        updateTransportStatus()
    }

    /// Surface a "couldn't reconnect" failure when a recovery rebuild outlasts the View's
    /// reconnect watchdog (GH #33). A poisoned pooled connection can make the cold `start.m3u8`
    /// hang with no AVPlayer error and without ever entering `.waitingToPlayAtSpecifiedRate`, so
    /// neither `handlePlaybackFailure` nor the stall watchdog fires — the "Reconnecting…" spinner
    /// would hang forever. PlayerView calls this to convert that dead spinner into the same
    /// Retry/Close overlay every other failure uses. Idempotent.
    func surfaceReconnectTimeout() {
        guard !playbackError.isFailed else { return }
        recordPlaybackDiagnostic("playback.reconnect_watchdog_fired", fields: [
            "resume": .millisecondsBucket(currentResumeMs),
        ])
        NSLog("PlaybackController: reconnect watchdog timed out, surfacing failure (#33)")
        surfaceFailure(ReconnectTimeoutError())
    }

    // MARK: - Stall watchdog (#8 hardening)

    /// How long (seconds) a continuous stall may last before we treat it as a failure. Generous
    /// enough not to trip a slow-but-working initial prime, short enough to replace AVKit's dead
    /// placeholder glyph with a recoverable Retry promptly.
    private let stallTimeoutSeconds: TimeInterval = 15
    private let directPlayMaximumStallTimeoutSeconds: TimeInterval = 90
    private let remoteTranscodeStallTimeoutSeconds: TimeInterval = 45

    private struct StallProgressSignature: Equatable {
        let transferredBytes: Int64
        let loadedEndMs: Int
    }

    private var stallProgressBaseline: StallProgressSignature?

    private var isRemoteTranscode: Bool {
        sessionSource.kind == .mediaBrowser && remotePlayMethod == .transcode
    }

    private var activeStallTimeoutSeconds: TimeInterval {
        if isRemoteTranscode {
            return remoteTranscodeStallTimeoutSeconds
        }
        // Direct Play / Maximum can legally be a very high-bitrate HEVC remux. Initial fMP4
        // segments for 4K remuxes can be tens of MB and the simulator/media plane can take a long
        // time to reach ready/keep-up even when PMS is serving valid video-copy bytes. Do not trip
        // the generic 15s watchdog or convert this explicit user choice into a capped transcode.
        if maxVideoBitrateKbps <= 0 {
            return directPlayMaximumStallTimeoutSeconds
        }
        return stallTimeoutSeconds
    }

    /// Arm the stall watchdog if it isn't already running and no error is being shown. Idempotent
    /// so repeated `.waitingToPlayAtSpecifiedRate` callbacks don't reset the countdown.
    private func armStallWatchdog() {
        guard stallWatchdogObservers.isEmpty, !playbackError.isFailed else { return }
        stallProgressBaseline = currentStallProgressSignature()
        recordPlaybackDiagnostic("playback.stall_watchdog_armed", fields: [
            "timeout_seconds": .int(Int(activeStallTimeoutSeconds)),
            "baseline_bytes": .int(Int(min(stallProgressBaseline?.transferredBytes ?? 0,
                                           Int64(Int.max)))),
            "baseline_loaded_end_ms": .int(stallProgressBaseline?.loadedEndMs ?? 0),
        ])
        let observedPlaybackGeneration = playbackGeneration
        let timer = Timer(timeInterval: activeStallTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.isCurrentPlaybackLifecycle(observedPlaybackGeneration) else { return }
                self.handleStallTimeout()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallWatchdogObservers.storeTimer(timer)
    }

    // MARK: - DV guard first-frame watchdog (GH #196)

    /// Arm the first-frame deadline for a DV-P5-guard-forced transcode. Jellyfin's own P5
    /// tone-map stalled server-side in live testing (segments never arrived, SEGPUMP -12889
    /// retry loop), so "force a transcode" alone can strand the viewer on a spinner. If real
    /// playback isn't observed within the deadline, surface a DV-specific failure.
    private func armDVGuardWatchdog() {
        guard dvGuardWatchdogObservers.isEmpty, !playbackError.isFailed else { return }
        dvGuardProgressBaseline = currentStallProgressSignature()
        recordPlaybackDiagnostic("playback.dv_guard_watchdog_armed", fields: [
            "timeout_seconds": .int(Int(DolbyVisionGuard.firstFrameTimeoutSeconds)),
        ])
        let observedPlaybackGeneration = playbackGeneration
        let timer = Timer(timeInterval: DolbyVisionGuard.firstFrameTimeoutSeconds,
                          repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.isCurrentPlaybackLifecycle(observedPlaybackGeneration) else { return }
                self.handleDVGuardTimeout()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dvGuardWatchdogObservers.storeTimer(timer)
    }

    private func cancelDVGuardWatchdog() {
        dvGuardWatchdogObservers.reset()
        dvGuardProgressBaseline = nil
    }

    private func handleDVGuardTimeout() {
        let baseline = dvGuardProgressBaseline
        dvGuardWatchdogObservers.reset()
        dvGuardProgressBaseline = nil
        // Any observed real playback cancels this watchdog at the `.playing` transition,
        // so firing means the forced transcode never produced a first frame.
        guard !playbackError.isFailed, !hasObservedPlayback else { return }
        // A slow-but-working tone-map prime (Emby re-priming a 4K transcode at a deep
        // offset was seen taking >20s live) keeps bytes flowing; only a wedged server
        // (the Jellyfin SEGPUMP no-segments loop) shows zero transport progress. Defer
        // while progress is being made rather than false-failing a working transcode.
        if stallMadeTransportProgress(since: baseline) {
            recordPlaybackDiagnostic("playback.dv_guard_watchdog_deferred")
            armDVGuardWatchdog()
            return
        }
        var fields = runtimeSnapshotFields()
        fields["dv_guard"] = .bool(true)
        recordPlaybackDiagnostic("playback.dv_guard_watchdog_fired", fields: fields)
        NSLog("PlaybackController: DV guard first-frame deadline expired, surfacing failure (#196)")
        surfaceFailure(NSError(domain: "Labstream.Playback",
                               code: -196,
                               userInfo: [NSLocalizedDescriptionKey: DolbyVisionGuard.failureMessage]))
    }

    /// Cancel the stall watchdog (genuine resume, teardown, or retry).
    private func cancelStallWatchdog() {
        if !stallWatchdogObservers.isEmpty {
            recordPlaybackDiagnostic("playback.stall_watchdog_cancelled")
        }
        stallWatchdogObservers.reset()
        stallProgressBaseline = nil
    }

    /// Fired when a stall outlasts `stallTimeoutSeconds`. Confirm the player is genuinely starved
    /// — still TRYING to play (`.waitingToPlayAtSpecifiedRate`, so not a deliberate user pause)
    /// yet unable to keep up — then surface the failure. We deliberately do NOT also require
    /// `isPlaybackBufferEmpty`: a stream that primes a little and then wedges reaches
    /// `readyToPlay` with a frozen frame and a NON-empty buffer (seen live on a 503-ing server,
    /// expanded cinema), so the old empty-buffer condition let that case slip through — the
    /// watchdog cancelled itself without surfacing and stranded the viewer on AVKit's spinner
    /// with no Retry. Keying on `timeControlStatus` still spares a normal pause (which reports
    /// `.paused`, not `.waitingToPlayAtSpecifiedRate`).
    /// First tries a bounded client-driven ABR downshift for reopenable Plex/MediaBrowser streams:
    /// if the server only gave AVPlayer one rendition, a lower-cap reopen is the cheapest
    /// approximation of a bitrate downshift. Once the session reaches the lowest rung (or for
    /// non-reopenable/static streams), the same visible Retry failure path remains terminal.
    private func handleStallTimeout() {
        let baseline = stallProgressBaseline
        stallWatchdogObservers.reset()
        stallProgressBaseline = nil
        guard !playbackError.isFailed, let current = player.currentItem else { return }
        // Not waiting anymore → genuine resume or pause; the next `.waiting` KVO transition
        // re-arms. But still-waiting with `isPlaybackLikelyToKeepUp` is a transient AVFoundation
        // state (the flag usually flips just before `.playing`): if we bail WITHOUT re-arming
        // and the player never resumes, no KVO transition ever comes and the safety net is
        // silently gone — unbounded spinner with no Retry. Re-arm instead.
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        if current.isPlaybackLikelyToKeepUp {
            recordPlaybackDiagnostic("playback.stall_watchdog_rearmed_keep_up")
            armStallWatchdog()
            return
        }
        var fields = runtimeSnapshotFields()
        fields["keep_up"] = .bool(current.isPlaybackLikelyToKeepUp)
        fields["adaptive_bitrate_enabled"] = .bool(adaptiveBitrateEnabled)

        if stallMadeTransportProgress(since: baseline) {
            fields["stall_progress_deferred"] = .bool(true)
            if let baseline {
                fields["baseline_bytes"] = .int(Int(min(baseline.transferredBytes, Int64(Int.max))))
                fields["baseline_loaded_end_ms"] = .int(baseline.loadedEndMs)
            }
            let currentSignature = currentStallProgressSignature()
            fields["current_bytes"] = .int(Int(min(currentSignature.transferredBytes,
                                                   Int64(Int.max))))
            fields["current_loaded_end_ms"] = .int(currentSignature.loadedEndMs)
            recordPlaybackDiagnostic("playback.stall_watchdog_deferred", fields: fields)
            armStallWatchdog()
            return
        }

        if attemptAdaptiveBitrateFallback(fields: fields) {
            return
        }

        if let underlying = current.error {
            fields["error"] = .error(underlying)
            recordPlaybackDiagnostic("playback.stall_watchdog_fired", fields: fields)
            NSLog("PlaybackController: stream stalled, surfacing failure (%@)",
                  Self.safeErrorSummary(underlying))
            surfaceFailure(underlying)
        } else {
            // GH #196: a "stall with no item error" is often not a stall at all — the item
            // error LOG (never `item.error` on this path) records AVFoundation abandoning
            // the copy lane's only variant after its hard startup deadlines
            // (-12889/-16830 → -12880). Surface the real story (and try the one-shot warm
            // retry) instead of the misleading capacity hint.
            let deadlineCodes = Self.startupDeadlineCodes(in: current)
            if let lastEvent = current.errorLog()?.events.last {
                fields["error_log_status_code"] = .int(lastEvent.errorStatusCode)
                fields["error_log_domain"] = .label(lastEvent.errorDomain)
                fields["error_log_comment"] = .text(lastEvent.errorComment)
            }
            if !deadlineCodes.isEmpty, attemptStartupDeadlineRetry(codes: deadlineCodes,
                                                                   trigger: "stall_watchdog") {
                return
            }
            if maxVideoBitrateKbps <= 0 {
                fields["failure_hint"] = .label("direct_play_capacity_or_player_limit")
            }
            recordPlaybackDiagnostic("playback.stall_watchdog_fired", fields: fields)
            let message: String
            if !deadlineCodes.isEmpty {
                message = HLSStartupDeadlinePolicy.failureMessage(errorLogCodes: deadlineCodes)
                NSLog("PlaybackController: stall watchdog found startup-deadline error log; surfacing deadline failure (#196)")
            } else if maxVideoBitrateKbps <= 0 {
                message = "Direct Play / Maximum stalled before playback could start. The stream may be above this network or player path's capacity. Tap Retry, or choose a transcoded/lower quality."
                NSLog("PlaybackController: Direct Play / Maximum stalled with no item error; surfacing capacity hint")
            } else {
                message = "Playback stalled. The server or network may be unreachable. Tap Retry once your connection is back."
                NSLog("PlaybackController: stream stalled with no item error; surfacing generic failure")
            }
            surfaceFailure(NSError(
                domain: "Labstream.Playback", code: -1001,
                userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }

    // MARK: - Startup-deadline recovery (GH #196)

    /// The startup-deadline CoreMedia codes recorded in the item's error log, oldest-first.
    private static func startupDeadlineCodes(in playerItem: AVPlayerItem) -> [Int] {
        (playerItem.errorLog()?.events ?? [])
            .map(\.errorStatusCode)
            .filter(HLSStartupDeadlinePolicy.isStartupDeadlineCode)
    }

    /// One-shot retry after AVFoundation abandoned the stream on its startup deadlines.
    /// Plex lane: rebuild against the SAME session — transcoder deliberately NOT stopped —
    /// because the failed attempt already made PMS write the first segments, so the retry
    /// starts against media that now exists. MediaBrowser (Emby/Jellyfin) lane: renegotiate
    /// via the backend reopener at the current playhead (their sessions are re-minted per
    /// PlaybackInfo, so a fresh negotiation IS the retry). Returns true when launched.
    private func attemptStartupDeadlineRetry(codes: [Int], trigger: String) -> Bool {
        guard !startupDeadlineRetryAttempted else { return false }
        let codesLabel = codes.map(String.init).joined(separator: ",")
        if sessionSource.kind == .mediaBrowser {
            startupDeadlineRetryAttempted = true
            let snapshot = playheadSnapshotForRestart(cause: .startupDeadlineRetry)
            let resumeMs = snapshot.positionMs
            var fields = positionSnapshotDiagnosticFields(snapshot)
            fields["trigger"] = .label(trigger)
            fields["lane"] = .label("remote_reopen")
            fields["error_log_codes"] = .text(codesLabel)
            fields["resume"] = .millisecondsBucket(resumeMs)
            recordPlaybackDiagnostic("playback.startup_deadline_retry", fields: fields)
            NSLog("PlaybackController: startup deadlines missed (%@); reopening remote stream once (#196)",
                  codesLabel)
            finalTargetRebuildPolicy.reset()
            reopenRemoteStream(offsetMs: resumeMs, bitrateKbps: maxVideoBitrateKbps)
            return true
        }
        guard isStreaming else { return false }
        startupDeadlineRetryAttempted = true
        let snapshot = playheadSnapshotForRestart(cause: .startupDeadlineRetry)
        let resumeMs = snapshot.positionMs
        var fields = positionSnapshotDiagnosticFields(snapshot)
        fields["trigger"] = .label(trigger)
        fields["lane"] = .label("plex_warm_session")
        fields["error_log_codes"] = .text(codesLabel)
        fields["resume"] = .millisecondsBucket(resumeMs)
        recordPlaybackDiagnostic("playback.startup_deadline_retry", fields: fields)
        NSLog("PlaybackController: startup deadlines missed (%@); retrying once against the warm session (#196)",
              codesLabel)
        setPendingResumeMs(resumeMs, cause: .startupDeadlineRetry, allowsNearZero: true)
        rememberTrustworthyPlaybackPosition(resumeMs,
                                            cause: .startupDeadlineRetry,
                                            allowsNearZero: true)
        finalTargetRebuildPolicy.reset()
        removeObservers()
        // The abandoned item is dead weight; detach it so nothing it still requests can
        // disturb the warm session the retry is about to reuse.
        player.replaceCurrentItem(with: nil)
        beginStreaming(resumeOffsetMsOverride: resumeMs, stoppingPreviousTranscode: false)
        return true
    }

    /// Terminal `-12880` seen in the error log: the only variant was removed, so the item will
    /// never recover (nor flip `item.status`) on its own. Retry warm once, else surface an
    /// accurate failure now instead of letting the stall watchdog time out into a generic hint.
    private func handleStartupVariantAbandonment(_ playerItem: AVPlayerItem) {
        guard !playbackError.isFailed else { return }
        let codes = Self.startupDeadlineCodes(in: playerItem)
        if attemptStartupDeadlineRetry(codes: codes, trigger: "error_log") { return }
        var fields = runtimeSnapshotFields()
        fields["error_log_codes"] = .text(codes.map(String.init).joined(separator: ","))
        recordPlaybackDiagnostic("playback.startup_deadline_failure", fields: fields)
        NSLog("PlaybackController: variant abandoned after startup deadlines and retry exhausted; surfacing failure (#196)")
        surfaceFailure(NSError(
            domain: "Labstream.Playback",
            code: HLSStartupDeadlinePolicy.variantsRemovedCode,
            userInfo: [NSLocalizedDescriptionKey: HLSStartupDeadlinePolicy.failureMessage(errorLogCodes: codes)]))
    }

    private func currentStallProgressSignature() -> StallProgressSignature {
        guard let item = player.currentItem else {
            return StallProgressSignature(transferredBytes: 0, loadedEndMs: 0)
        }
        let transferredBytes = item.accessLog()?.events.reduce(Int64(0)) { total, event in
            total + max(0, Int64(event.numberOfBytesTransferred))
        } ?? 0
        let loadedEnd = item.loadedTimeRanges
            .map(\.timeRangeValue)
            .map { ($0.start + $0.duration).seconds }
            .filter(\.isFinite)
            .max() ?? 0
        return StallProgressSignature(transferredBytes: transferredBytes,
                                      loadedEndMs: Int(max(0, loadedEnd * 1000)))
    }

    private func stallMadeTransportProgress(since baseline: StallProgressSignature?) -> Bool {
        // Any network lane defers on progress — Plex (`isStreaming`) AND backend-resolved
        // Jellyfin/Emby remote streams, whose sessions carry no Plex server/token. Gating on
        // `isStreaming` alone made this permanently false for MediaBrowser backends, so the
        // slow-but-working deferral (Emby re-priming a deep-offset 4K transcode >20s) never
        // applied to the very case it documents. Local files still bypass: their "transport"
        // is disk I/O and a stall there should escalate on the plain timeout.
        guard sessionSource.kind != .offline, let baseline else { return false }
        let current = currentStallProgressSignature()
        return current.transferredBytes > baseline.transferredBytes
            || current.loadedEndMs > baseline.loadedEndMs
    }

    private func attemptAdaptiveBitrateFallback(fields baseFields: [String: DiagnosticFieldValue]) -> Bool {
        guard adaptiveBitrateEnabled else { return false }
        guard supportsQualityReload else { return false }
        // Do not silently convert an explicit Direct Play / Maximum selection into a capped
        // video transcode. That is worse than the user's chosen direct/remux path on fast links
        // and was the source of the apparent ~20 Mbps fallback. If Direct Play / Maximum truly
        // cannot play, surface Retry rather than automatically abandoning video-copy.
        guard maxVideoBitrateKbps > 0 else { return false }
        guard let decision = adaptiveBitratePolicy.recordStall(
            now: ProcessInfo.processInfo.systemUptime,
            currentKbps: maxVideoBitrateKbps,
            userSelectedMaximumKbps: userSelectedMaxVideoBitrateKbps) else { return false }
        return applyAdaptiveBitrateDecision(decision, baseFields: baseFields)
    }

    private func maybeAdaptBitrateAfterHealthyPlayback() {
        guard adaptiveBitrateEnabled else { return }
        guard supportsQualityReload, !playbackError.isFailed, !userWantsPaused,
              player.timeControlStatus == .playing else { return }
        guard let decision = adaptiveBitratePolicy.recordHealthyPlayback(
            now: ProcessInfo.processInfo.systemUptime,
            currentKbps: maxVideoBitrateKbps,
            userSelectedMaximumKbps: userSelectedMaxVideoBitrateKbps,
            bufferedAheadSeconds: diagnostics.bufferedAheadSeconds,
            likelyToKeepUp: diagnostics.likelyToKeepUp,
            observedBitrateKbps: diagnostics.currentObservedBitrateForAdaptationKbps) else { return }
        _ = applyAdaptiveBitrateDecision(decision, baseFields: runtimeSnapshotFields())
    }

    private func configureAdaptiveBitratePolicy(usesShortRemoteBuffer: Bool) {
        // Remote-HLS seek reopens intentionally use a short buffer (#43). If the ABR policy kept
        // the normal upshift-buffer requirement on that path, Jellyfin could downshift after a
        // stall but practically never climb back up. Keep the anti-oscillation time gates, but
        // align the buffer threshold with the active remote-HLS buffer mode.
        adaptiveBitratePolicy.configuration.minimumBufferedAheadForUpshift = usesShortRemoteBuffer
            ? Self.remoteTranscodeAdaptiveUpshiftBufferSeconds
            : Self.defaultAdaptiveUpshiftBufferSeconds
    }

    private func applyAdaptiveBitrateDecision(_ decision: AdaptiveBitratePolicy.Decision,
                                              baseFields: [String: DiagnosticFieldValue]) -> Bool {
        guard decision.targetKbps != maxVideoBitrateKbps else { return false }
        let previousActiveKbps = maxVideoBitrateKbps
        let snapshot = playheadSnapshotForRestart(cause: .adaptiveBitrate)
        let resumeMs = snapshot.positionMs
        var fields = baseFields
        fields.merge(positionSnapshotDiagnosticFields(snapshot)) { _, new in new }
        fields["direction"] = .label(decision.direction.rawValue)
        fields["reason"] = .label(decision.reason)
        fields["from_quality"] = .label(StreamingQuality.label(kbps: previousActiveKbps))
        fields["to_quality"] = .label(StreamingQuality.label(kbps: decision.targetKbps))
        fields["from_kbps"] = .int(previousActiveKbps)
        fields["to_kbps"] = .int(decision.targetKbps)
        fields["user_selected_cap_kbps"] = .int(userSelectedMaxVideoBitrateKbps)
        fields["resume"] = .millisecondsBucket(resumeMs)
        fields["uses_remote_reopener"] = .bool(sessionSource.kind == .mediaBrowser)
        recordPlaybackDiagnostic("playback.adaptive_bitrate_change", fields: fields)
        recordTranscodeDiagnostic("transcode.adaptive_bitrate_change", fields: fields)
        NSLog("PlaybackController: adaptive bitrate %@ from %@ to %@",
              decision.direction.rawValue,
              StreamingQuality.label(kbps: previousActiveKbps),
              StreamingQuality.label(kbps: decision.targetKbps))

        maxVideoBitrateKbps = decision.targetKbps
        restartAtCurrentPosition(offsetMs: resumeMs,
                                 bitrateKbps: decision.targetKbps,
                                 intent: .adaptiveBitrate)
        return true
    }

    // MARK: - Seek final-target rebuild (#33 reset)

    /// Handle a playhead jump on the current item. If the target is already buffered or the stream is
    /// local/static/range-friendly, AVKit owns the seek natively. If it is outside a server-encoded
    /// HLS window, record the target and debounce so a drag collapses to one final-target rebuild.
    private func handleSeekJump() {
        guard !playbackError.isFailed else { return }
        let now = player.currentTime().seconds
        guard now.isFinite, now >= 0 else { return }
        let targetMs = Int(now * 1000)

        if abs(targetMs - lastPrimedOffsetMs) <= Self.finalTargetEchoEpsilonMs {
            return
        }

        // Device-only AVFoundation behavior seen on Vision Pro hardware: after loading a
        // start.m3u8 primed at a non-zero offset, the item can emit an early
        // `timeJumpedNotification` at/near 0 before playback has settled at the primed offset.
        // The custom player already owns real user seek intent through `performUserSeek(toMs:)`;
        // treating this transient 0 as intent immediately rebuilds the stream back to 0:00 and
        // breaks resume, chapter jumps, and scrubber commits on capped transcodes.
        if lastPrimedOffsetMs > Self.finalTargetEchoEpsilonMs,
           targetMs <= Self.finalTargetEchoEpsilonMs {
            playbackLog.notice("seek: ignoring transient zero timeJump after primed offset targetMs=\(targetMs, privacy: .public) primedMs=\(self.lastPrimedOffsetMs, privacy: .public)")
            return
        }
        rememberTrustworthyPlaybackPosition(targetMs,
                                            cause: .timeJump,
                                            allowsNearZero: false)

        let targetIsWithinLoadedRange = isWithinLoadedRanges(seconds: now)
        let seekMode = RemoteSeekModePolicy.seekMode(streamKind: seekStreamKind,
                                                     targetIsWithinLoadedRange: targetIsWithinLoadedRange)
        guard seekMode == .reopenStreamAtTarget else {
            cancelPendingFinalTargetRebuild()
            return
        }

        scheduleFinalTargetRebuild(toMs: targetMs)
    }

    /// True if `seconds` falls within (a small slack around) any of the item's loaded time
    /// ranges — i.e. AVKit already has data there and can seek natively.
    private func isWithinLoadedRanges(seconds: Double) -> Bool {
        guard let item = player.currentItem else { return false }
        for value in item.loadedTimeRanges {
            let r = value.timeRangeValue
            let start = r.start.seconds
            let end = (r.start + r.duration).seconds
            guard start.isFinite, end.isFinite else { continue }
            if seconds >= start - 1, seconds <= end + 1 { return true }
        }
        return false
    }

    /// Arm (or re-arm) the debounced final-target rebuild. Each out-of-buffer jump during a drag
    /// records the latest target; only the settled target gets a PMS restart or backend re-open.
    private func scheduleFinalTargetRebuild(toMs targetMs: Int) {
        // Hold the scrubber on this target and make even the fallback branch of `currentResumeMs`
        // return it (instead of the stale pre-seek offset) for the whole rebuild window (GH #110).
        setSeeking(true, targetMs: targetMs)
        setPendingResumeMs(targetMs, cause: .seekRebuildTarget, allowsNearZero: true)
        rememberTrustworthyPlaybackPosition(targetMs,
                                            cause: .seekRebuildTarget,
                                            allowsNearZero: true)
        finalTargetRebuildPolicy.recordFinalTarget(offsetMs: targetMs)
        finalTargetSettleTask?.cancel()
        let observedPlaybackGeneration = playbackGeneration
        finalTargetSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.finalTargetSettleNanos)
            guard let self else { return }
            // Any early-out here means the rebuild won't actually run, so release the hold to
            // avoid freezing the label. Cancellation = superseded by a newer seek (which set its
            // own hold) or stop(); leave the hold to the new owner / stop's reset.
            guard self.isCurrentPlaybackLifecycle(observedPlaybackGeneration) else { return }
            guard self.supportsSeekReprime, !self.playbackError.isFailed else {
                self.setSeeking(false); return
            }
            guard let target = self.finalTargetRebuildPolicy.consumePendingTarget() else {
                self.setSeeking(false); return
            }
            self.finalTargetSettleTask = nil
            // Keep the hold target aligned with the settled (possibly newer) target.
            self.setSeeking(true, targetMs: target)
            self.setPendingResumeMs(target, cause: .seekRebuildSettledTarget, allowsNearZero: true)
            self.rememberTrustworthyPlaybackPosition(target,
                                                     cause: .seekRebuildSettledTarget,
                                                     allowsNearZero: true)
            if self.sessionSource.kind == .mediaBrowser {
                self.reopenRemoteStream(offsetMs: target, bitrateKbps: self.maxVideoBitrateKbps)
            } else {
                guard self.isStreaming else { self.setSeeking(false); return }
                self.beginFinalTargetRebuild(toMs: target)
            }
        }
    }

    /// Centralized in-place restart at a known playhead. The typed intent supplies an ordered
    /// preparation plan so track, quality, Retry, and ABR callers cannot assemble Boolean recipes
    /// independently. Backend replacement ordering remains here and is unchanged: MediaBrowser
    /// uses its reopener, while Plex optionally refreshes the recovery control client before
    /// entering `beginStreaming`.
    private func restartAtCurrentPosition(offsetMs: Int,
                                          bitrateKbps: Int,
                                          intent: PlaybackRestartIntent) {
        setPendingResumeMs(offsetMs, cause: .restartTarget, allowsNearZero: true)
        rememberTrustworthyPlaybackPosition(offsetMs,
                                            cause: .restartTarget,
                                            allowsNearZero: true)
        refreshVideoNowPlayingMetadata(elapsedMillisecondsOverride: offsetMs,
                                       playbackRateOverride: 0)
        let plan = intent.plan
        for step in plan.preparationSteps {
            switch step {
            case .resetFinalTarget:
                finalTargetRebuildPolicy.reset()
            case .resetAdaptiveBitrate:
                adaptiveBitratePolicy.reset()
            case .rearmStartupDeadlineRetry:
                // Every existing intentional restart re-arms the GH #196 one-shot allowance.
                startupDeadlineRetryAttempted = false
            case .clearPlaybackError:
                playbackError.clear()
                updateTransportStatus()
            case .removeObservers:
                removeObservers()
            }
        }
        if sessionSource.kind == .mediaBrowser {
            reopenRemoteStream(offsetMs: offsetMs,
                               bitrateKbps: bitrateKbps,
                               preferShortRemoteHLSBuffer: false)
        } else {
            if plan.plexControlClient == .refreshForRecovery {
                switchToRecoveryControlClient()
            }
            beginStreaming(resumeOffsetMsOverride: offsetMs)
        }
    }

    private func reopenRemoteStream(offsetMs: Int,
                                    bitrateKbps: Int,
                                    preferShortRemoteHLSBuffer: Bool = true) {
        guard let session = mediaBrowserSession else { return }
        let remoteStreamReopener = session.reopener
        beginItemPreparation()
        // Hold the scrubber on the reopen target across the detach→renegotiate→ready window so the
        // label can't fall back to the stale offset while the item is nil (GH #110).
        setSeeking(true, targetMs: offsetMs)
        setPendingResumeMs(offsetMs, cause: .remoteReopenTarget, allowsNearZero: true)
        rememberTrustworthyPlaybackPosition(offsetMs,
                                            cause: .remoteReopenTarget,
                                            allowsNearZero: true)
        playbackTask?.cancel()
        playbackGeneration += 1
        let generation = playbackGeneration
        lastPrimedOffsetMs = offsetMs
        let priorStop = didStopRemoteSession ? nil : onStopRemoteSession
        let priorPlaySessionId = remotePlaySessionId
        // Detach the old AVPlayerItem before asking the remote backend for a replacement stream. The
        // simulator logs for #43 showed AVPlayer surfacing NSURLErrorDomain -1008 immediately
        // after we deleted the active remote encoding during a seek/reopen; stale init/segment
        // loads can outlive observer teardown. Replacing the item first stops those resource
        // loads from racing with the new playlist.
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playbackLog.notice("seek: remote stream re-open targetMs=\(offsetMs, privacy: .public) bitrateKbps=\(bitrateKbps, privacy: .public)")
        recordPlaybackDiagnostic("playback.remote_reopen", fields: [
            "target": .millisecondsBucket(offsetMs),
            "quality": .label(StreamingQuality.label(kbps: bitrateKbps)),
            "detached_prior_item": .bool(true),
            "deferred_prior_session_stop": .bool(priorStop != nil),
        ])
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let request = RemoteStreamReopenRequest(offsetMs: offsetMs,
                                                        bitrateKbps: bitrateKbps,
                                                        audioStreamIndex: effectiveRemoteAudioStreamIndex(),
                                                        subtitleStreamIndex: effectiveRemoteSubtitleStreamIndex())
                let reopened = try await remoteStreamReopener(request)
                guard RemoteStreamLifecyclePolicy.acceptsReopenResult(
                    capturedGeneration: generation,
                    currentGeneration: self.playbackGeneration,
                    isCancelled: Task.isCancelled) else {
                    reopened.onStop?()
                    return
                }
                let nextPlayMethod = reopened.playMethod ?? self.remotePlayMethod
                guard let playableURL = await self.playableRemoteStreamURL(reopened.url,
                                                                           headers: reopened.headers,
                                                                           resumeOffsetMs: offsetMs,
                                                                           playMethod: nextPlayMethod,
                                                                           generation: generation),
                      RemoteStreamLifecyclePolicy.acceptsReopenResult(
                          capturedGeneration: generation,
                          currentGeneration: self.playbackGeneration,
                          isCancelled: Task.isCancelled) else {
                    reopened.onStop?()
                    return
                }
                self.remoteHTTPHeaders = reopened.headers
                self.remotePlaySessionId = reopened.playSessionId
                if var progressSession = self.mediaBrowserProgressSession {
                    if let playSessionId = reopened.playSessionId {
                        progressSession.playSessionID = playSessionId
                    }
                    if let mediaSourceId = reopened.mediaSourceId {
                        progressSession.mediaSourceID = mediaSourceId
                    }
                    if let nextPlayMethod {
                        progressSession.playMethod = nextPlayMethod
                    }
                    self.mediaBrowserProgressSession = progressSession
                }
                if let sourceMetadata = reopened.sourceMetadata {
                    self.remoteSourceMetadata = sourceMetadata
                }
                if let playMethod = reopened.playMethod {
                    self.remotePlayMethod = playMethod
                }
                if let transcodeReasons = reopened.transcodeReasons {
                    self.remoteTranscodeReasons = transcodeReasons
                }
                self.onStopRemoteSession = reopened.onStop
                self.didStopRemoteSession = false
                self.preferShortRemoteHLSBufferForNextLoad = preferShortRemoteHLSBuffer
                self.loadRemoteStream(playableURL, headers: reopened.headers, resumeOffsetMs: offsetMs)
                switch RemoteStreamLifecyclePolicy.priorSessionStopDecision(
                    priorPlaySessionID: priorPlaySessionId,
                    reopenedPlaySessionID: reopened.playSessionId) {
                case .skip(let reason):
                    self.recordPlaybackDiagnostic("playback.remote_stop_skipped", fields: [
                        "reason": .label(reason),
                    ])
                case .deferStop(let reason):
                    self.scheduleDeferredRemoteSessionStop(priorStop,
                                                           reason: reason,
                                                           delaySeconds: 2.0)
                }
            } catch {
                guard RemoteStreamLifecyclePolicy.acceptsReopenResult(
                    capturedGeneration: generation,
                    currentGeneration: self.playbackGeneration,
                    isCancelled: Task.isCancelled) else { return }
                self.recordPlaybackDiagnostic("playback.remote_reopen_failed", fields: [
                    "error": .error(error),
                    "target": .millisecondsBucket(offsetMs),
                ])
                NSLog("PlaybackController: remote stream reopen failed (%@)", Self.safeErrorSummary(error))
                self.surfaceFailure(NSError(
                    domain: "Labstream.Playback", code: -1004,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Couldn't reopen the stream at that position. Tap Retry or try a lower quality setting."]))
                self.didStopRemoteSession = true
                self.onStopRemoteSession = nil
                self.remotePlaySessionId = nil
                self.mediaBrowserProgressSession = nil
                self.scheduleDeferredRemoteSessionStop(priorStop,
                                                       reason: "reopen_failed_after_detach",
                                                       delaySeconds: 2.0)
            }
        }
    }

    private func scheduleDeferredRemoteSessionStop(_ stop: (() -> Void)?,
                                                   reason: String,
                                                   delaySeconds: TimeInterval) {
        guard let stop else { return }
        recordPlaybackDiagnostic("playback.remote_stop_deferred", fields: [
            "reason": .label(reason),
            "delay_seconds": .double(delaySeconds),
        ])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delaySeconds))
            stop()
        }
    }

    private func beginFinalTargetRebuild(toMs targetMs: Int) {
        switch finalTargetRebuildPolicy.beginRebuild(offsetMs: targetMs,
                                                     now: ProcessInfo.processInfo.systemUptime) {
        case .start(let generation, let offsetMs):
            lastPrimedOffsetMs = offsetMs
            // Hold the scrubber on the Plex rebuild target across the restart (GH #110).
            setSeeking(true, targetMs: offsetMs)
            setPendingResumeMs(offsetMs, cause: .plexRebuildTarget, allowsNearZero: true)
            rememberTrustworthyPlaybackPosition(offsetMs,
                                                cause: .plexRebuildTarget,
                                                allowsNearZero: true)
            recordPlaybackDiagnostic("playback.seek_rebuild_start", fields: [
                "target": .millisecondsBucket(offsetMs),
                "generation": .int(generation),
            ])
            removeObservers()
            beginStreaming(resumeOffsetMsOverride: offsetMs,
                           finalTargetRebuildGeneration: generation)
        case .alreadyRebuilding:
            recordPlaybackDiagnostic("playback.seek_rebuild_deferred", fields: [
                "reason": .label("already_rebuilding"),
                "target": .millisecondsBucket(targetMs),
            ])
            break
        case .deferred(let remaining):
            recordPlaybackDiagnostic("playback.seek_rebuild_deferred", fields: [
                "reason": .label("cooldown"),
                "remaining_seconds": .double(remaining),
                "target": .millisecondsBucket(targetMs),
            ])
            finalTargetSettleTask?.cancel()
            let observedPlaybackGeneration = playbackGeneration
            finalTargetSettleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard let self,
                      self.isCurrentPlaybackLifecycle(observedPlaybackGeneration) else { return }
                guard let target = self.finalTargetRebuildPolicy.consumePendingTarget() else {
                    // Cooldown elapsed but nothing left to rebuild — release the hold so the
                    // label doesn't freeze (GH #110).
                    self.setSeeking(false); return
                }
                self.finalTargetSettleTask = nil
                self.beginFinalTargetRebuild(toMs: target)
            }
        case .escalate:
            recordPlaybackDiagnostic("playback.seek_rebuild_escalated", fields: [
                "target": .millisecondsBucket(targetMs),
            ])
            surfaceFailure(NSError(
                domain: "Labstream.Playback", code: -1002,
                userInfo: [NSLocalizedDescriptionKey:
                    "Playback keeps falling behind the server. Tap Retry to rebuild the stream, or lower the quality setting."]))
        }
    }

    private func cancelPendingFinalTargetRebuild() {
        finalTargetSettleTask?.cancel()
        finalTargetSettleTask = nil
    }

    // MARK: - Opt-in diagnostic event helpers

    private func recordPlaybackDiagnostic(_ name: String,
                                          fields: [String: DiagnosticFieldValue] = [:]) {
        AppDiagnostics.record(.playback, name, fields: diagnosticFields(fields))
    }

    private func recordTranscodeDiagnostic(_ name: String,
                                           fields: [String: DiagnosticFieldValue] = [:]) {
        AppDiagnostics.record(.transcode, name, fields: diagnosticFields(fields))
    }

    private var performanceBackendLabel: String {
        switch sessionSource {
        case .offline: return "Local"
        case .mediaBrowser(let session): return session.backendLabel
        case .plex: return "Plex"
        }
    }

    private var performancePathMode: String {
        sessionSource.pathMode
    }

    private static func directPlayStartRejectionKey(metadataKey: String,
                                                    mediaIndex: Int,
                                                    partIndex: Int) -> String {
        "\(metadataKey)#media=\(mediaIndex)#part=\(partIndex)"
    }

    private static func httpStatus(from error: Error) -> Int? {
        if case PlexError.http(let status) = error { return status }
        return nil
    }

    private static func safeErrorSummary(_ error: Error?) -> String {
        DiagnosticRedactor.safeErrorSummary(error)
    }

    private func maybeRecordDiagnosticSnapshot(force: Bool = false) {
        guard AppDiagnostics.isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastDiagnosticSnapshotUptime >= Self.diagnosticSnapshotIntervalSeconds else {
            return
        }
        lastDiagnosticSnapshotUptime = now
        recordPlaybackDiagnostic("playback.snapshot", fields: runtimeSnapshotFields())
    }

}

/// Observable failure surface for a `PlaybackController`. Modeled as its own object
/// (mirroring `PlaybackDiagnostics`) so PlayerView/DetailView can react to a failure and
/// show an error + Retry without the whole controller needing to be `@Observable`.
/// Error surfaced when a failure-recovery rebuild can't reach playback within the View's
/// reconnect watchdog window (GH #33). Its message is controlled by Labstream and safe for the
/// Retry/Close overlay.
struct ReconnectTimeoutError: LocalizedError {
    var errorDescription: String? {
        "Couldn't reconnect to the server. It may be busy or briefly unreachable — try again."
    }
}


@Observable
@MainActor
final class OfflineSubtitleOverlayState {
    var text: String?
    func set(_ value: String?) { text = value }
}

@Observable
@MainActor
final class PlaybackError {
    /// True when playback has failed and the UI should present the error + Retry.
    private(set) var isFailed = false
    /// A human-readable description of the failure, if AVFoundation provided one.
    private(set) var message: String?

    /// Mark a failure for display. Raw framework/server error strings are collapsed to a safe
    /// message; only Labstream-authored playback messages are surfaced verbatim.
    func set(_ error: Error?) {
        isFailed = true
        message = Self.safeDisplayMessage(for: error)
    }

    /// Clear the failure state (on (re)start / retry).
    func clear() {
        isFailed = false
        message = nil
    }

    private static func safeDisplayMessage(for error: Error?) -> String? {
        guard let error else { return nil }
        if let reconnect = error as? ReconnectTimeoutError {
            return reconnect.errorDescription
        }
        let nsError = error as NSError
        if nsError.domain == "Labstream.Playback" {
            return nsError.userInfo[NSLocalizedDescriptionKey] as? String
        }
        return DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Playback")
    }
}

/// User-facing transport overlay state derived inside `PlaybackController` from AVPlayer status,
/// user intent, retry lifecycle, and surfaced failures. Kept as a value enum so SwiftUI surfaces
/// render one mutually-exclusive overlay instead of composing several booleans.
enum PlaybackTransportStatus: Equatable {
    case none
    case buffering
    case pausedBuffering
    case preparingLocal(isPaused: Bool, hasObservedPlayback: Bool)
    case reconnecting
    case failed(message: String?)

    var diagnosticLabel: String {
        switch self {
        case .none: return "none"
        case .buffering: return "buffering"
        case .pausedBuffering: return "paused_buffering"
        case .preparingLocal(let isPaused, let hasObservedPlayback):
            if isPaused { return "paused_local_preparation" }
            return hasObservedPlayback ? "local_media_wait" : "local_initial_preparation"
        case .reconnecting: return "reconnecting"
        case .failed: return "failed"
        }
    }

    var keepsChromeVisible: Bool {
        switch self {
        case .none, .buffering, .pausedBuffering, .preparingLocal:
            false
        case .reconnecting, .failed:
            true
        }
    }
}

@Observable
@MainActor
final class PlaybackTransportStatusState {
    static let localInitialPreparationDelay: Duration = .milliseconds(750)

    private(set) var status: PlaybackTransportStatus = .none
    @ObservationIgnored private var pendingStatus: PlaybackTransportStatus?
    @ObservationIgnored private var pendingStatusTask: Task<Void, Never>?
    @ObservationIgnored private let initialPreparationDelay: Duration

    init(initialPreparationDelay: Duration = localInitialPreparationDelay) {
        self.initialPreparationDelay = initialPreparationDelay
    }

    var activeStatus: PlaybackTransportStatus? {
        status == .none ? nil : status
    }

    var keepsChromeVisible: Bool {
        status.keepsChromeVisible
    }

    func set(_ value: PlaybackTransportStatus) {
        if case .preparingLocal(_, false) = value {
            guard status != value else { return }
            guard pendingStatus != value else { return }
            pendingStatusTask?.cancel()
            pendingStatus = value
            if status != .none { status = .none }
            let delay = initialPreparationDelay
            pendingStatusTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.pendingStatus == value else { return }
                self.pendingStatus = nil
                self.pendingStatusTask = nil
                if self.status != value { self.status = value }
            }
            return
        }

        pendingStatusTask?.cancel()
        pendingStatusTask = nil
        pendingStatus = nil
        if status != value { status = value }
    }
}

/// Observable state for the playback-speed selection (R5). Modeled as its own object
/// (mirroring `PlaybackError`/`SkipMarkerState`) so the Speed menu renders the
/// active-rate checkmark and reacts to a programmatic reapply (e.g. after a Quality reload)
/// without making the whole controller observable.
@Observable
@MainActor
final class PlaybackSpeedState {
    /// The active playback rate (1.0 == normal). Seeded from the persisted choice.
    var speed: Float = 1.0
}

/// Observable state for the rebuffer/stall spinner (#21). Modeled as its own object
/// (mirroring `PlaybackError`/`PlaybackSpeedState`) so PlayerView's overlay can show/hide a
/// centered loading indicator without making the whole controller observable. Driven from KVO
/// on `AVPlayer.timeControlStatus`: `isBuffering` is true exactly while the player is
/// `.waitingToPlayAtSpecifiedRate` (stalled / initial prime) and false while `.playing` or
/// (crucially) while the USER has `.paused` — so a manual pause never shows the spinner.
@Observable
@MainActor
final class BufferingState {
    /// True while playback is stalled waiting for data (or the initial prime).
    private(set) var isBuffering = false

    /// Set the buffering flag. Idempotent so a duplicate `timeControlStatus` callback doesn't
    /// churn the observable.
    func set(_ value: Bool) {
        if isBuffering != value { isBuffering = value }
    }
}

/// Observable mirror of the player's paused state. Modeled as its own object (mirroring
/// `BufferingState`) so `PlayerControlSurface` can gate the "✕ Close" contextual action on
/// pause without making the whole controller observable. `.waitingToPlayAtSpecifiedRate`
/// (stall/prime) deliberately counts as NOT paused — a starved stream shouldn't surface
/// Close; the failure path does that explicitly once the watchdog fires.
@Observable
@MainActor
final class TransportState {
    /// True exactly while `timeControlStatus == .paused`.
    private(set) var isPaused = false
    /// True after the user taps Pause while AVPlayer is still loading/priming and before KVO
    /// catches up to `.paused`. The chrome should present Play immediately in this state.
    private(set) var pauseRequested = false

    var showsPausedControl: Bool {
        isPaused || pauseRequested
    }

    /// Set the paused flag. Idempotent so duplicate KVO callbacks don't churn the observable.
    func set(paused: Bool) {
        if isPaused != paused { isPaused = paused }
        if paused {
            pauseRequested = false
        }
    }

    func setPauseRequested(_ value: Bool) {
        if pauseRequested != value { pauseRequested = value }
    }
}

/// Observable state for the Skip Intro / Skip Credits affordance (#14). Modeled as its own
/// object (mirroring `PlaybackError`) so PlayerView's overlay can react to a marker becoming
/// active/inactive without making the whole controller observable. `active` is `nil` when the
/// playhead is outside every intro/credits range; otherwise it carries the marker kind (which
/// labels the button) and the seek target (the marker's end, in seconds).
@Observable
@MainActor
final class SkipMarkerState {
    /// Which skippable marker kind is active. Drives the button label/icon.
    enum Kind: Equatable {
        case intro
        case credits

        /// Button label, e.g. "Skip Intro".
        var label: String {
            switch self {
            case .intro: return "Skip Intro"
            case .credits: return "Skip Credits"
            }
        }

        /// SF Symbol for the button.
        var systemImage: String {
            switch self {
            case .intro: return "forward.end.alt"
            case .credits: return "forward.frame"
            }
        }
    }

    /// The currently-active skippable marker, or `nil` when none.
    struct Active: Equatable {
        let kind: Kind
        /// Where Skip seeks the playhead to (the marker's end), in seconds.
        let seekTargetSeconds: Double
    }

    /// The active marker, if the playhead is inside an intro/credits range. `nil` otherwise.
    private(set) var active: Active?

    /// Show (or update) the Skip affordance for `kind`, seeking to `seekTargetSeconds` on tap.
    /// Idempotent: a no-op when the same active state is already set, so a 0.5s observer tick
    /// doesn't churn the observable.
    func set(kind: Kind, seekTargetSeconds: Double) {
        let next = Active(kind: kind, seekTargetSeconds: seekTargetSeconds)
        if active != next { active = next }
    }

    /// Hide the Skip affordance.
    func clear() {
        if active != nil { active = nil }
    }
}

/// Observable state for the "Up Next" card (#15). Modeled as its own object (mirroring
/// `SkipMarkerState`) so PlayerView's overlay can react to the card showing/hiding and the
/// countdown ticking without making the whole controller observable.
///
/// Lifecycle for one item: the controller resolves `nextItem` in the background; once the
/// playhead reaches the near-end window it calls `show(countdown:)`; the countdown is ticked
/// down via `setCountdown`; reaching zero (or play-to-end) advances. `cancel()` suppresses
/// the card for the rest of the current item. `isAdvancing` guards a double-advance.
@Observable
@MainActor
final class UpNextState {
    /// The resolved next item (an episode), or `nil` when none exists / not yet resolved.
    private(set) var nextItem: MediaItem?
    /// Whether the card is currently on screen.
    private(set) var isShown = false
    /// Seconds remaining before autoplay, shown on the card.
    private(set) var countdown = 0
    /// True once the user dismissed the card; suppresses autoplay for this item.
    private(set) var isCancelled = false
    /// True once an advance is in flight, so we don't fire it twice (countdown + play-to-end).
    private(set) var isAdvancing = false

    /// Record the resolved next item (called from the background resolver).
    func setNextItem(_ item: MediaItem) {
        nextItem = item
    }

    /// Show the card and start the countdown.
    func show(countdown seconds: Int) {
        guard !isShown else { return }
        isShown = true
        countdown = seconds
    }

    /// Update the live countdown value.
    func setCountdown(_ value: Int) {
        if countdown != value { countdown = value }
    }

    /// Hide the card without cancelling (e.g. the user seeked back out of the window).
    func hide() {
        if isShown { isShown = false }
    }

    /// User dismissed the card: hide it and suppress autoplay for the rest of this item.
    func cancel() {
        isShown = false
        isCancelled = true
    }

    /// Mark that an advance is underway (idempotency guard).
    func beginAdvancing() {
        isAdvancing = true
    }
}
