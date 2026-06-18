import Foundation
import AVKit
import AVFAudio
import UIKit
import os
import PMSKit

struct RemoteStreamOpenResult {
    let url: URL
    let headers: [String: String]
    let playSessionId: String?
    let sourceMetadata: JellyfinPlaybackSourceMetadata?
    let playMethod: JellyfinPlayMethod?
    let onStop: (() -> Void)?

    init(url: URL,
         headers: [String: String],
         playSessionId: String? = nil,
         sourceMetadata: JellyfinPlaybackSourceMetadata? = nil,
         playMethod: JellyfinPlayMethod? = nil,
         onStop: (() -> Void)? = nil) {
        self.url = url
        self.headers = headers
        self.playSessionId = playSessionId
        self.sourceMetadata = sourceMetadata
        self.playMethod = playMethod
        self.onStop = onStop
    }
}

struct RemoteStreamReopenRequest: Sendable {
    let offsetMs: Int
    let bitrateKbps: Int
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?

    init(offsetMs: Int,
         bitrateKbps: Int,
         audioStreamIndex: Int? = nil,
         subtitleStreamIndex: Int? = nil) {
        self.offsetMs = offsetMs
        self.bitrateKbps = bitrateKbps
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
    }
}

typealias RemoteStreamReopener = (RemoteStreamReopenRequest) async throws -> RemoteStreamOpenResult

/// Persistent (`.notice`-level, disk-backed) log for the playback session lifecycle.
/// Used sparingly for events worth diagnosing after the fact — e.g. the transcode-stop
/// before an in-place restart (#27), which guards against the server-OOM job pile-up.
let playbackLog = Logger(subsystem: "com.jlipworth.VisionPlex", category: "Playback")

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
    private let item: MediaItem
    private var client: PlexClient
    private let identity: ClientIdentity

    /// Streaming context. `nil` for local-file playback (no timeline reporting then,
    /// since there is no server session/token to report against).
    private let server: URL?
    private let token: String?

    /// The local file URL, when playing offline content.
    private let localFile: URL?

    /// Already-resolved remote media URL, when a non-Plex backend (currently Jellyfin) has
    /// performed its own playback negotiation and only needs the custom player to open the
    /// resulting stream. This keeps the player surface agnostic: Plex owns its transcode resolver,
    /// while other backends can hand us a concrete stream URL and a re-open hook for quality/seek.
    private let remoteStreamURL: URL?

    /// Optional HTTP headers required by `remoteStreamURL`. Jellyfin playback tokens must stay in
    /// headers rather than URL query parameters so client logs/history never capture URL tokens.
    private var remoteHTTPHeaders: [String: String]
    private var remoteSourceMetadata: JellyfinPlaybackSourceMetadata?
    private var remotePlayMethod: JellyfinPlayMethod?
    private var remotePlaySessionId: String?
    private var onStopRemoteSession: (() -> Void)?
    private let remoteStreamReopener: RemoteStreamReopener?
    private var didStopRemoteSession = false

    /// The server's machine identifier (== the Plex resource `clientIdentifier`), used to
    /// build a play queue for "Up Next" resolution (#15). `nil` when unavailable (offline
    /// playback, or a caller that didn't thread it), in which case Up Next never resolves.
    private let machineIdentifier: String?

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
    private let qualityDefaultsKey: String
    var qualityPreferenceDefaultsKey: String { qualityDefaultsKey }

    /// Per-playback transcode session id (also reused as the timeline session).
    private let sessionID = "plex-avp-" + UUID().uuidString

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

    /// Observable surface for the rebuffer/stall spinner (#21). Modeled as its own
    /// `@Observable` object (mirroring `playbackError`/`skipMarker`) so PlayerView can float a
    /// centered loading indicator while playback is stalled, without making the whole
    /// controller observable. Driven from KVO on the player's `timeControlStatus`.
    let buffering = BufferingState()

    /// Observable mirror of the player's paused state, driven from the same
    /// `timeControlStatus` KVO as the timeline reporting. `PlayerControlSurface` uses it to
    /// offer the "✕ Close" contextual action only while PAUSED (or failed) — visionOS has no
    /// transport-bar-visibility callback (`API_UNAVAILABLE(visionos)`), so this is the only
    /// signal that keeps the pill off the video during normal playback.
    let transport = TransportState()

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
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var bufferingObservation: NSKeyValueObservation?
    private var didEndObserver: NSObjectProtocol?
    private var diagnosticsTimer: Timer?
    private var lastDiagnosticSnapshotUptime: TimeInterval = 0
    private var lastDiagnosticTimeControlStatus: AVPlayer.TimeControlStatus?
    private var failedToEndObserver: NSObjectProtocol?
    private var currentPlayerItemGeneration = 0
    private var nextPlayerItemGeneration = 0
    private var ignoredRecoverableFailedToEndCount = 0
    /// Watchdog for a stalled stream (#8 hardening). HLS network loss frequently manifests as a
    /// PERMANENT stall — the player sits in `.waitingToPlayAtSpecifiedRate` with an empty buffer
    /// and never flips `AVPlayerItem.status` to `.failed` (AVKit paints its own placeholder glyph
    /// from the error log, but neither the status observer nor `failedToPlayToEnd` fires). This
    /// timer is the catch-all: armed while the player is starved, it surfaces the error+Retry
    /// overlay if the stall outlasts `stallTimeoutSeconds`, turning a dead-end into a recoverable
    /// state. Cancelled the moment playback genuinely resumes (`.playing`).
    private var stallWatchdog: Timer?
    private var bufferingDelayTask: Task<Void, Never>?
    /// Observer for `AVPlayerItem.timeJumpedNotification` — the only in-process signal of a user
    /// seek on visionOS (#25): AVKit's user-navigation delegate callbacks
    /// (`willResumePlaybackAfterUserNavigatedFromTime:toTime:`) are `API_UNAVAILABLE(visionos)`,
    /// checked in the XROS 26.5 AVPlayerViewController.h.
    private var timeJumpedObserver: NSObjectProtocol?
    private var started = false
    private var playbackTask: Task<Void, Never>?
    private var upNextTask: Task<Void, Never>?
    private var playbackGeneration = 0
    private var jellyfinHLSProxy: MediaSessionProxy?
    private var jellyfinHLSProxyGeneration: Int?
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
    /// degrade once to the maximum transcode instead of surfacing a dead-end.
    /// `suppressDirectPlayProbe` is the one-shot that makes that rebuild skip the probe (so it
    /// takes the transcode path) and also marks "a fallback is in flight" so a sibling failure
    /// callback on the same dead item doesn't surface over it. Both are reset/consumed at the
    /// top of every `startStreaming`.
    private var directPlayFallbackArmed = false
    private var suppressDirectPlayProbe = false

    /// Server-safe final-target rebuild policy (#33 reset). A drag can emit many
    /// `timeJumpedNotification`s, but PMS must only see one intentional rebuild at the final
    /// settled target. The pure policy is unit-tested in PMSKit; the controller owns the timer and
    /// the actual player-item replacement.
    private var finalTargetRebuildPolicy = FinalTargetRebuildPolicy()
    private var finalTargetSettleTask: Task<Void, Never>?
    private var activeFinalTargetRebuildGeneration: Int?
    private static let finalTargetSettleNanos: UInt64 = 500_000_000
    private static let diagnosticSnapshotIntervalSeconds: TimeInterval = 15
    /// Offset we most recently primed via `start.m3u8?offset=...`; suppress nearby programmatic
    /// resume seeks so a rebuild does not immediately schedule another rebuild.
    private var lastPrimedOffsetMs = 0
    private static let finalTargetEchoEpsilonMs = 2000

    // MARK: - Extracted collaborators

    /// Audio-session config + interruption / route-change / background handling (#17, P5).
    /// Activated and observer-registered once per controller lifetime (both idempotent
    /// across a Quality reload); torn down in `stop()`.
    private lazy var audioSession = AudioSessionCoordinator(player: player)

    /// Timeline heartbeats + scrobble reporting to PMS. Spans Quality reloads (its
    /// one-shot scrobble guard deliberately survives a stream rebuild); its readiness
    /// gate is reset per item in `load(_:)`.
    private lazy var timeline = TimelineReporter(item: item,
                                                 server: server,
                                                 token: token,
                                                 identity: identity,
                                                 client: client,
                                                 player: player)

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

    /// One-shot guard so the saved-audio-language auto-select runs once per item (#3). Reset in
    /// `load(_:)` alongside `didApplySavedSubtitle` so a Quality reload re-applies the preference
    /// to the new audible group.
    private var didApplyAudioPreference = false

    /// `@AppStorage` keys for the persisted subtitle preference. Mirrors `PlayerView`'s
    /// `maxVideoBitrateKbps` pattern (UserDefaults-backed) so the controller — which can't be
    /// a SwiftUI view — and any future settings UI share one source of truth.
    private enum SubtitlePrefKey {
        /// BCP-47 / ISO language code of the user's last chosen subtitle track (e.g. "en").
        static let language = PlaybackPreferenceKeys.preferredSubtitleLanguage
        /// `true` once the user has explicitly chosen "Off"; suppresses auto-select.
        static let off = PlaybackPreferenceKeys.subtitlesOff
    }

    /// `@AppStorage`-style key for the persisted audio-language preference (#3). Mirrors
    /// `SubtitlePrefKey`, but there is no "Off" — a video always plays some soundtrack.
    private enum AudioPrefKey {
        /// BCP-47 / ISO language code of the user's last chosen audio track (e.g. "en").
        static let language = PlaybackPreferenceKeys.preferredAudioLanguage
    }

    /// Every UserDefaults key this controller persists across sessions, for the Settings
    /// "Reset playback preferences" row (#26). Deliberately EXCLUDES `maxVideoBitrateKbps`,
    /// which has its own Streaming-quality picker. Keep in sync with the key enums above.
    static let persistedPreferenceKeys: [String] = [
        playbackSpeedKey,
        SubtitlePrefKey.language,
        SubtitlePrefKey.off,
        AudioPrefKey.language,
        PlaybackPreferenceKeys.subtitleAutoSelectMode,
        PlaybackPreferenceKeys.subtitleBurnMode,
    ]

    /// Resume target (ms) for the current item, retained so the status observer can do a
    /// client-side seek fallback if PMS's `#EXT-X-START` priming didn't land (P2 #9).
    private var pendingResumeMs: Int?

    /// One-time resume target (ms) applied on the FIRST `start()` instead of the item's saved
    /// `viewOffset`. Set when the player view controller is REBUILT to recover from a wedged
    /// AVKit state after a failure (see `PlayerView`'s rebuild path): the fresh controller must
    /// resume at the live playhead we captured, not the stale on-disk offset.
    private let initialResumeMsOverride: Int?

    /// Best-effort current playhead (ms), used to rebuild the player after a failure without
    /// losing the user's position. Prefers the live time when it's valid, then the pending
    /// resume target, then the item's saved offset, then 0.
    var currentResumeMs: Int {
        let secs = player.currentTime().seconds
        if secs.isFinite, secs > 0 { return Int(secs * 1000) }
        return pendingResumeMs ?? item.viewOffset ?? 0
    }

    /// Whether this session is streaming (vs local file). Drives which menus the
    /// player surface offers (quality reload only makes sense for streaming).
    var isStreaming: Bool { localFile == nil && server != nil && token != nil }

    /// Whether this session can reopen its media stream at a new offset/quality.
    /// Plex uses the media-session proxy; backend-resolved playback (Jellyfin) can
    /// provide a reopener closure without pretending to be a Plex timeline session.
    var supportsQualityReload: Bool { isStreaming || remoteStreamReopener != nil }

    /// Whether the Audio tab should use backend/container metadata instead of AVFoundation's
    /// currently-loaded audible group. Plex and Jellyfin both expose alternate tracks in media
    /// metadata and require a stream reopen/rebuild to switch tracks; local downloads still use
    /// AVFoundation because the whole playable file is already on disk.
    var supportsMetadataAudioSelection: Bool { isStreaming || remoteStreamReopener != nil }

    private var supportsSeekReprime: Bool { isStreaming || remoteStreamReopener != nil }

    /// Chapter markers for the current item, if Plex provided any. Empty when none —
    /// the player hides the Chapters info-panel tab in that case.
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
        let req = BrowseAPI.metadata(server: server, token: token,
                                     identity: identity, ratingKey: item.ratingKey)
        guard let resp = try? await client.send(req, as: MetadataResponse.self),
              let full = resp.mediaContainer.metadata.first else { return false }
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

    /// Separate, fine-grained time observer for marker detection. The 10s timeline
    /// heartbeat is far too coarse to drive an on-screen Skip button, so we add a ~0.5s
    /// observer dedicated to updating `skipMarker`.
    private var markerTimeObserver: Any?

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
         qualityDefaultsKey: String = PlaybackPreferences.Keys.legacyQualityKbps,
         mediaIndex: Int = 0,
         machineIdentifier: String? = nil,
         initialResumeMsOverride: Int? = nil) {
        self.item = item
        self.server = server
        self.token = token
        self.identity = identity
        self.client = client
        self.localFile = nil
        self.remoteStreamURL = nil
        self.remoteHTTPHeaders = [:]
        self.remoteSourceMetadata = nil
        self.remotePlayMethod = nil
        self.remotePlaySessionId = nil
        self.onStopRemoteSession = nil
        self.remoteStreamReopener = nil
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.qualityDefaultsKey = qualityDefaultsKey
        self.mediaIndex = mediaIndex
        self.machineIdentifier = machineIdentifier
        self.initialResumeMsOverride = initialResumeMsOverride
        self.chapters = item.chapters ?? []
        self.speedState.speed = self.playbackSpeed
    }

    /// Local-file initializer (offline playback of a downloaded title).
    init(localFile: URL,
         item: MediaItem,
         identity: ClientIdentity,
         client: PlexClient,
         maxVideoBitrateKbps: Int = 8000,
         qualityDefaultsKey: String = PlaybackPreferences.Keys.legacyQualityKbps) {
        self.item = item
        self.localFile = localFile
        self.identity = identity
        self.client = client
        self.server = nil
        self.token = nil
        self.remoteStreamURL = nil
        self.remoteHTTPHeaders = [:]
        self.remoteSourceMetadata = nil
        self.remotePlayMethod = nil
        self.remotePlaySessionId = nil
        self.onStopRemoteSession = nil
        self.remoteStreamReopener = nil
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.qualityDefaultsKey = qualityDefaultsKey
        // A local file is already one concrete version on disk; no version selection.
        self.mediaIndex = 0
        // Offline playback has no server session to build a play queue against.
        self.machineIdentifier = nil
        // Local files resume from the item's saved offset; no rebuild override.
        self.initialResumeMsOverride = nil
        self.chapters = item.chapters ?? []
        self.speedState.speed = self.playbackSpeed
    }

    /// Resolved remote-stream initializer for non-Plex backends. The caller owns
    /// backend-specific auth/playback negotiation; this controller only loads the supplied stream
    /// into AVKit and reuses the same player UI, observers, buffering, diagnostics and metadata.
    init(remoteStreamURL: URL,
         item: MediaItem,
         identity: ClientIdentity,
         client: PlexClient,
         httpHeaders: [String: String] = [:],
         remotePlaySessionId: String? = nil,
         sourceMetadata: JellyfinPlaybackSourceMetadata? = nil,
         playMethod: JellyfinPlayMethod? = nil,
         onStopRemoteSession: (() -> Void)? = nil,
         remoteStreamReopener: RemoteStreamReopener? = nil,
         maxVideoBitrateKbps: Int = 0,
         qualityDefaultsKey: String = PlaybackPreferences.Keys.legacyQualityKbps) {
        self.item = item
        self.localFile = nil
        self.remoteStreamURL = remoteStreamURL
        self.remoteHTTPHeaders = httpHeaders
        self.remotePlaySessionId = remotePlaySessionId
        self.remoteSourceMetadata = sourceMetadata
        self.remotePlayMethod = playMethod
        self.onStopRemoteSession = onStopRemoteSession
        self.remoteStreamReopener = remoteStreamReopener
        self.identity = identity
        self.client = client
        self.server = nil
        self.token = nil
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.qualityDefaultsKey = qualityDefaultsKey
        // A backend-resolved URL is already one concrete stream.
        self.mediaIndex = 0
        // Non-Plex playback has no Plex play queue to resolve against.
        self.machineIdentifier = nil
        // The backend spike starts at the server-selected offset for now.
        self.initialResumeMsOverride = nil
        self.chapters = item.chapters ?? []
        self.speedState.speed = self.playbackSpeed
    }

    // MARK: - Lifecycle

    /// Begin playback. Safe to call once; subsequent calls are ignored.
    func start() {
        guard !started else { return }
        started = true
        var fields: [String: DiagnosticFieldValue] = [
            "path_mode": .label(localFile != nil ? "local_file" : (remoteStreamURL != nil ? "remote_stream" : "plex_stream")),
            "initial_resume": .millisecondsBucket(initialResumeMsOverride ?? item.viewOffset),
        ]
        fields.merge(sourceDiagnosticFields()) { _, new in new }
        recordPlaybackDiagnostic("playback.session_start", fields: fields)
        if let localFile {
            loadLocalFile(localFile)
        } else if let remoteStreamURL {
            loadRemoteStream(remoteStreamURL, headers: remoteHTTPHeaders)
        } else {
            // Use the rebuild resume override on first start when present (recovering from a
            // wedged player); otherwise startStreaming falls back to the item's saved offset.
            // First start of this controller: no previous job under this sessionID to stop.
            beginStreaming(resumeOffsetMsOverride: initialResumeMsOverride,
                           stoppingPreviousTranscode: false)
        }
        // Resolve the next episode in the background (#15). Network-bound and entirely
        // best-effort: if it fails or there is no next item, the Up Next card simply never
        // appears. Only meaningful for episodes; the resolver returns early otherwise.
        upNextTask = Task { await self.resolveNextItem() }
    }

    /// Tear down observers and report a final `stopped` timeline. Call from the
    /// view's `dismantle`.
    func stop() {
        maybeRecordDiagnosticSnapshot(force: true)
        recordPlaybackDiagnostic("playback.session_stop", fields: [
            "resume": .millisecondsBucket(currentResumeMs),
            "sent_transcode_stop": .bool(sentTranscodeStop),
        ])
        playbackTask?.cancel()
        playbackTask = nil
        upNextTask?.cancel()
        upNextTask = nil
        playbackGeneration += 1
        if let proxy = jellyfinHLSProxy, let generation = jellyfinHLSProxyGeneration {
            Task { await proxy.stop(generation: generation) }
            jellyfinHLSProxy = nil
            jellyfinHLSProxyGeneration = nil
        }
        timeline.report(state: .stopped, force: true)
        sendTranscodeStop()
        stopRemoteSessionIfNeeded()
        cancelPendingFinalTargetRebuild()
        if let activeFinalTargetRebuildGeneration {
            finalTargetRebuildPolicy.cancelRebuild(generation: activeFinalTargetRebuildGeneration)
            self.activeFinalTargetRebuildGeneration = nil
        }
        finalTargetRebuildPolicy.reset()
        player.pause()
        removeObservers()
        // Tear down the session/lifecycle observers (kept separate from the per-item
        // observers above) and release the audio session, notifying other apps so they can
        // resume (#17).
        audioSession.removeObservers()
        audioSession.deactivate()
    }

    private func stopRemoteSessionIfNeeded() {
        guard remoteStreamURL != nil, !didStopRemoteSession else { return }
        didStopRemoteSession = true
        onStopRemoteSession?()
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
        // Build human-readable labels from each option, de-duplicating collisions (e.g. two
        // distinct "English" renditions) with a trailing index only when needed.
        var seenCounts: [String: Int] = [:]
        for (index, option) in group.options.enumerated() {
            var label = Self.subtitleLabel(for: option)
            let priorCount = seenCounts[label, default: 0]
            seenCounts[label] = priorCount + 1
            if priorCount > 0 { label += " \(priorCount + 1)" }
            tracks.append(SubtitleTrack(id: index, displayName: label, option: option))
        }

        // Resolve the active selection so the tab can render a checkmark. A `nil`
        // selected option (or a group not currently selected) means "Off" (id -1).
        let current = playerItem.currentMediaSelection.selectedMediaOption(in: group)
        let selectedID = current.flatMap { selected in
            group.options.firstIndex(of: selected)
        } ?? -1

        return (tracks, selectedID)
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
    static func subtitleLabel(for option: AVMediaSelectionOption) -> String {
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
            if let title = titles.first?.stringValue, !title.isEmpty {
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

    /// Auto-apply the persisted subtitle-language preference to the current item's legible
    /// group, once per item (gated by `didApplySavedSubtitle`). If the user previously chose
    /// "Off" we leave captions disabled and do NOT override it. Otherwise we select the first
    /// legible option whose language matches the saved code. No-op when nothing is saved or no
    /// match exists (the HLS default selection stands).
    ///
    /// Invoked on `.readyToPlay`; stays on the @MainActor since it reads the non-`Sendable`
    /// `AVMediaSelectionOption`s.
    private func applySavedSubtitlePreferenceIfNeeded() async {
        guard !didApplySavedSubtitle else { return }
        let defaults = UserDefaults.standard

        // No preference at all (neither Off nor a language): nothing to do, but don't burn
        // the one-shot gate yet — leave the HLS default and let a future pick start fresh.
        let wantsOff = defaults.bool(forKey: SubtitlePrefKey.off)
        let savedLang = defaults.string(forKey: SubtitlePrefKey.language)
        let mode = SubtitleAutoSelectMode(rawValue: defaults.string(forKey: PlaybackPreferenceKeys.subtitleAutoSelectMode) ?? "")
            ?? .manual
        guard wantsOff || (mode != .manual && savedLang?.isEmpty == false) else { return }

        if mode == .foreignAudio && !sourceAudioIsForeign(toPreferredLanguage: defaults) {
            didApplySavedSubtitle = true
            return
        }

        // Load the legible group once. If the HLS carries no legible renditions, there's
        // nothing to apply on this item — mark applied so we don't re-probe each readyToPlay.
        guard let playerItem = player.currentItem,
              let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible),
              !group.options.isEmpty else {
            didApplySavedSubtitle = true
            return
        }

        if wantsOff {
            // Honor an explicit "Off": disable captions and do NOT auto-select anything.
            playerItem.select(nil, in: group)
            didApplySavedSubtitle = true
            return
        }

        // Select the first legible option whose language matches the saved code. No match →
        // leave the HLS default selection in place.
        if let saved = savedLang {
            let match = group.options.first { option in
                option.extendedLanguageTag == saved
                    || option.locale?.language.languageCode?.identifier == saved
            }
            if let match {
                playerItem.select(match, in: group)
            }
        }
        didApplySavedSubtitle = true
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
        // Remember this choice (language code, or the "Off" flag) so it's reapplied to the
        // next item. A manual pick is authoritative for this session too: mark the auto-select
        // gate spent so a later readyToPlay (e.g. mid-stream re-ready) won't override the user.
        persistSubtitlePreference(for: track.option)
        didApplySavedSubtitle = true
    }

    // MARK: - Audio (soundtrack / language)

    /// A selectable audio track surfaced by the HLS audible media-selection group (#3).
    ///
    /// Mirrors `SubtitleTrack`: we model the picker over `AVMediaSelectionOption`s because the
    /// HLS transcode exposes its audio renditions as an audible `AVMediaSelectionGroup`, and
    /// switching between them is instantaneous (`playerItem.select(_:in:)`) — no transcode
    /// reload. Unlike subtitles there is no "Off" row: a video always plays some soundtrack.
    struct AudioTrack: Identifiable {
        /// Stable identity for SwiftUI (the option's index within the audible group).
        let id: Int
        let displayName: String
        let option: AVMediaSelectionOption
    }

    /// Load the current item's audible (soundtrack) selection group and its options, plus which
    /// one is active. Returns `nil` for the group when the HLS carries fewer than two audible
    /// renditions — with nothing to choose between, the Audio tab shows a graceful empty state
    /// rather than a pointless one-row list.
    ///
    /// Async because `AVAsset.loadMediaSelectionGroup(for:)` is the modern, non-blocking accessor
    /// (the synchronous `mediaSelectionGroup(forMediaCharacteristic:)` is deprecated on visionOS).
    func loadAudioTracks() async -> (tracks: [AudioTrack], selectedID: Int)? {
        guard let playerItem = player.currentItem else { return nil }
        let asset = playerItem.asset
        guard let group = try? await asset.loadMediaSelectionGroup(for: .audible),
              group.options.count > 1 else {
            return nil
        }

        // Build human-readable labels, de-duplicating collisions (e.g. two distinct "English"
        // renditions) with a trailing index only when needed — mirrors `loadSubtitleTracks`.
        var tracks: [AudioTrack] = []
        var seenCounts: [String: Int] = [:]
        for (index, option) in group.options.enumerated() {
            var label = Self.audioLabel(for: option)
            let priorCount = seenCounts[label, default: 0]
            seenCounts[label] = priorCount + 1
            if priorCount > 0 { label += " \(priorCount + 1)" }
            tracks.append(AudioTrack(id: index, displayName: label, option: option))
        }

        // Resolve the active selection so the tab can render a checkmark. Audio is never "off";
        // if AVFoundation reports no explicit selection yet, fall back to the first option.
        let current = playerItem.currentMediaSelection.selectedMediaOption(in: group)
        let selectedID = current.flatMap { selected in
            group.options.firstIndex(of: selected)
        } ?? 0

        return (tracks, selectedID)
    }

    /// Derive a human-readable label for an audible `AVMediaSelectionOption`.
    ///
    /// Name resolution mirrors `subtitleLabel(for:)` (first non-empty wins): the option's locale
    /// language, then `option.displayName`, then its `.commonMetadataTitle`, then "Unknown".
    /// Appends " (AD)" for an audio-description track (spoken narration of on-screen action for
    /// accessibility). The Forced/SDH qualifiers are subtitle-specific and intentionally omitted.
    ///
    /// `@MainActor` because it touches a non-`Sendable` `AVMediaSelectionOption`.
    static func audioLabel(for option: AVMediaSelectionOption) -> String {
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
            if let title = titles.first?.stringValue, !title.isEmpty {
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
        let code = option.extendedLanguageTag
            ?? option.locale?.language.languageCode?.identifier
        let defaults = UserDefaults.standard
        if let code, !code.isEmpty {
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
    private func applySavedAudioPreferenceIfNeeded() async {
        guard !didApplyAudioPreference else { return }
        let savedLang = UserDefaults.standard.string(forKey: AudioPrefKey.language)
        // No preference saved: leave the HLS default and don't burn the one-shot gate yet, so a
        // future pick starts fresh.
        guard let savedLang, !savedLang.isEmpty else { return }

        // Load the audible group once. If the HLS carries no audible renditions there's nothing
        // to apply on this item — mark applied so we don't re-probe each readyToPlay.
        guard let playerItem = player.currentItem,
              let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible),
              !group.options.isEmpty else {
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

    private func selectedBurnSubtitleStreamIDForCurrentPreferences() -> Int? {
        let defaults = UserDefaults.standard
        let burnMode = SubtitleBurnMode(rawValue: defaults.string(forKey: PlaybackPreferenceKeys.subtitleBurnMode) ?? "")
            ?? .automatic
        guard burnMode != .automatic else { return nil }

        let autoMode = SubtitleAutoSelectMode(rawValue: defaults.string(forKey: PlaybackPreferenceKeys.subtitleAutoSelectMode) ?? "")
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
        let preferredAudio = defaults.string(forKey: AudioPrefKey.language)
            ?? Locale.current.language.languageCode?.identifier
        guard let preferredAudio, !preferredAudio.isEmpty,
              let part = sourcePartForCurrentMedia(),
              let sourceAudio = part.audioStreams.first(where: { $0.selected == true })
                ?? part.audioStreams.first(where: { $0.isDefault == true })
                ?? part.audioStreams.first else {
            return false
        }
        return !Self.languageMatches(languageTag: sourceAudio.languageTag,
                                     languageCode: sourceAudio.languageCode,
                                     language: sourceAudio.language,
                                     preferredLanguage: preferredAudio)
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

    private static func languageMatches(languageTag: String?,
                                        languageCode: String?,
                                        language: String?,
                                        preferredLanguage: String) -> Bool {
        let preferred = normalizedLanguageCodes(for: preferredLanguage)
        guard !preferred.isEmpty else { return false }
        let candidates = [languageTag, languageCode, language]
            .compactMap { $0 }
            .flatMap { normalizedLanguageCodes(for: $0) }
        return candidates.contains { preferred.contains($0) }
    }

    private static func normalizedLanguageCodes(for raw: String) -> Set<String> {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return [] }
        let base = value.split(separator: "-").first.map(String.init) ?? value
        var codes: Set<String> = [value, base]
        if let twoLetter = iso639ThreeToTwo[base] {
            codes.insert(twoLetter)
        }
        if let localized = Locale.current.localizedString(forLanguageCode: base)?.lowercased() {
            codes.insert(localized)
        }
        return codes
    }

    private static let iso639ThreeToTwo: [String: String] = [
        "eng": "en", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de",
        "ita": "it", "por": "pt", "jpn": "ja", "kor": "ko", "chi": "zh", "zho": "zh",
        "dut": "nl", "nld": "nl", "swe": "sv", "nor": "no", "dan": "da", "fin": "fi",
    ]

    /// Apply an audio selection chosen in the Audio tab. A soft switch on the live `AVPlayerItem`
    /// — no reload. Persists the choice (language code) so it's reapplied to the next item, and
    /// marks the auto-select gate spent so a later readyToPlay won't override this manual pick.
    func selectAudio(_ track: AudioTrack) async {
        guard let playerItem = player.currentItem else { return }
        guard let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible) else {
            return
        }
        playerItem.select(track.option, in: group)
        persistAudioPreference(for: track.option)
        didApplyAudioPreference = true
    }

    // MARK: - Audio (metadata-driven, streaming) — GH #3

    /// A selectable audio track sourced from Plex part metadata (`Stream`, streamType=2).
    ///
    /// Streaming sessions can't use the AVMediaSelection path above: PMS muxes only the
    /// part's *selected* audio track into the HLS transcode, so the audible group never
    /// lists alternates. The real track list lives in the item's metadata, and switching
    /// means PUTting the new `audioStreamID` on the part and rebuilding the transcode.
    struct AudioStreamChoice: Identifiable, Sendable {
        /// PMS `Stream.id` — what `audioStreamID` expects.
        let id: Int
        let displayName: String
        let isSelected: Bool
    }

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
    private var subtitleStreamIndexOverride: Int?

    /// Build the Audio tab's track list from part metadata. Synchronous — pure reads of the
    /// decoded item. Returns an empty array when the metadata carries no audio streams (the
    /// tab then falls back to its empty state).
    func loadAudioStreamChoices() -> [AudioStreamChoice] {
        guard let part = streamingPart else { return [] }
        let streams = part.audioStreams
        guard !streams.isEmpty else { return [] }

        // Active track: a live override from a switch this session, else the PMS `selected`
        // flag (sent only on the active track), else the container default, else the first.
        let selectedID = audioStreamIDOverride
            ?? streams.first { $0.selected == true }?.id
            ?? streams.first { $0.isDefault == true }?.id
            ?? streams[0].id

        // Label preference: displayTitle ("English (AAC Stereo)") is PMS's purpose-built
        // short label; fall back through the longer/raw fields, then a positional name.
        var choices: [AudioStreamChoice] = []
        var seenCounts: [String: Int] = [:]
        for (index, stream) in streams.enumerated() {
            var label = stream.displayTitle
                ?? stream.extendedDisplayTitle
                ?? stream.language
                ?? "Track \(index + 1)"
            let priorCount = seenCounts[label, default: 0]
            seenCounts[label] = priorCount + 1
            if priorCount > 0 { label += " \(priorCount + 1)" }
            choices.append(AudioStreamChoice(id: stream.id,
                                             displayName: label,
                                             isSelected: stream.id == selectedID))
        }
        return choices
    }

    /// Switch the active audio track for a streaming session: persist the selection on the
    /// part server-side, then rebuild the transcode at the live playhead (same mechanics as
    /// the Quality reload — PMS can't swap audio mid-session, so the stream must restart).
    /// Also persists the language preference so the next item auto-selects it.
    func selectAudioStream(_ choice: AudioStreamChoice) async {
        guard supportsMetadataAudioSelection, let part = streamingPart else { return }
        guard !choice.isSelected else { return }

        if isStreaming, let server, let token {
            let request = StreamSelectionRequest.selectAudioStream(server: server,
                                                                   token: token,
                                                                   identity: identity,
                                                                   partID: part.id,
                                                                   audioStreamID: choice.id)
            do {
                try await client.send(request)
            } catch {
                NSLog("PlaybackController: audio stream selection failed: %@", String(describing: error))
                return
            }
        }

        audioStreamIDOverride = choice.id
        if let lang = part.audioStreams.first(where: { $0.id == choice.id })?.languageTag
            ?? part.audioStreams.first(where: { $0.id == choice.id })?.language,
           !lang.isEmpty {
            UserDefaults.standard.set(lang, forKey: AudioPrefKey.language)
        }

        // Restart/reopen where the viewer is — same UX as Quality reload. Plex persists the
        // stream selection above; Jellyfin carries the stream index in the reopen request.
        let resumeMs = currentResumeMs
        finalTargetRebuildPolicy.reset()
        removeObservers()
        if remoteStreamReopener != nil {
            reopenRemoteStream(offsetMs: resumeMs, bitrateKbps: maxVideoBitrateKbps)
        } else {
            beginStreaming(resumeOffsetMsOverride: resumeMs)
        }
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
        timeline.report(state: .paused, force: true)
        recordPlaybackDiagnostic("playback.pause_requested", fields: [
            "status": .label(Self.timeControlStatusLabel(player.timeControlStatus)),
            "item_ready": .bool(player.currentItem?.status == .readyToPlay),
        ])
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
    /// Only valid for reopenable sessions; a no-op for local files/static streams.
    func reload(bitrateKbps: Int) {
        guard supportsQualityReload else { return }
        guard bitrateKbps != maxVideoBitrateKbps else { return }
        recordPlaybackDiagnostic("playback.quality_change", fields: [
            "from_quality": .label(StreamingQuality.label(kbps: maxVideoBitrateKbps)),
            "to_quality": .label(StreamingQuality.label(kbps: bitrateKbps)),
            "resume": .millisecondsBucket(currentResumeMs),
        ])
        maxVideoBitrateKbps = bitrateKbps
        // Snapshot position so we can resume where the viewer was.
        let resumeMs = Int(player.currentTime().seconds.isFinite ? player.currentTime().seconds * 1000 : 0)
        // A reload is explicit user intent: reset the final-target rebuild budget.
        // (didScrobble is intentionally NOT reset — the same content shouldn't re-scrobble.)
        finalTargetRebuildPolicy.reset()
        removeObservers()
        if remoteStreamReopener != nil {
            reopenRemoteStream(offsetMs: resumeMs, bitrateKbps: bitrateKbps)
        } else {
            beginStreaming(resumeOffsetMsOverride: resumeMs)
        }
    }

    // MARK: - Failure / retry

    /// User-initiated retry after a surfaced playback failure (P3 #8). Re-runs the
    /// streaming start path from the last known playhead so a transient bad start.m3u8
    /// (or a recovered network blip) gets one fresh, user-requested session rather than a
    /// permanent black screen or hidden restart loop. Remote backend sessions use their re-open
    /// hook so Jellyfin gets the same visible Retry affordance as Plex. No-op for local-file
    /// sessions/static remote streams (nothing to re-fetch).
    func retry() {
        guard isStreaming || remoteStreamReopener != nil else { return }
        let resumeMs = currentResumeMs
        recordPlaybackDiagnostic("playback.retry", fields: [
            "resume": .millisecondsBucket(resumeMs),
            "uses_remote_reopener": .bool(remoteStreamReopener != nil),
        ])
        finalTargetRebuildPolicy.reset()
        playbackError.clear()
        removeObservers()
        if remoteStreamReopener != nil {
            reopenRemoteStream(offsetMs: resumeMs, bitrateKbps: maxVideoBitrateKbps)
        } else {
            switchToRecoveryControlClient()
            beginStreaming(resumeOffsetMsOverride: resumeMs)
        }
    }

    /// App-owned scrubber commit hook for the experimental custom player path (#38).
    ///
    /// Native AVKit scrubber callbacks are unavailable on visionOS, so `PlayerView` has to infer
    /// user intent from `AVPlayerItem.timeJumpedNotification`. The fallback player owns the
    /// scrubber directly and can pass the user's intended target here. In-buffer targets still use
    /// a native `AVPlayer.seek`; out-of-buffer streaming targets bypass the doomed native seek and
    /// enter the same server-safe final-target rebuild policy that current `main` uses for #33/#25.
    func performUserSeek(toMs targetMs: Int) {
        let clamped = max(0, targetMs)
        let target = CMTime(value: CMTimeValue(clamped), timescale: 1000)
        let seconds = Double(clamped) / 1000

        guard supportsSeekReprime, !playbackError.isFailed else {
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }

        if isWithinLoadedRanges(seconds: seconds) {
            cancelPendingFinalTargetRebuild()
            recordPlaybackDiagnostic("playback.user_seek", fields: [
                "seek_mode": .label("native_buffered"),
                "target": .millisecondsBucket(clamped),
            ])
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            recordPlaybackDiagnostic("playback.user_seek", fields: [
                "seek_mode": .label("server_rebuild"),
                "target": .millisecondsBucket(clamped),
            ])
            scheduleFinalTargetRebuild(toMs: clamped)
        }
    }

    /// App-owned relative seek hook for fixed transport jumps (±10/±30). It deliberately
    /// funnels into `performUserSeek(toMs:)` so button jumps get the same in-buffer native seek
    /// vs. out-of-buffer final-target rebuild behavior as the custom scrubber.
    @discardableResult
    func performRelativeUserSeek(bySeconds deltaSeconds: Int,
                                 from baseMs: Int? = nil,
                                 durationMs: Int? = nil) -> Int {
        let base = baseMs ?? currentResumeMs
        let deltaMs = deltaSeconds * 1000
        let upperBound = durationMs.flatMap { $0 > 0 ? $0 : nil } ?? knownDurationMs
        let unclamped = base + deltaMs
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
        }
        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"

        // "Maximum / Original" (the no-cap sentinel) maps to a very high ceiling so PMS still
        // emits a playable HLS rendition rather than rejecting an absent cap — the same
        // ceiling "Maximum (transcoded)" uses, and the transcode fallback when an Original
        // pick can't be copied.
        let requestedCap = maxVideoBitrateKbps <= 0 ? StreamingQuality.maxTranscodedKbps : maxVideoBitrateKbps

        // Resume position. Tell PMS to PRIME the transcode here (seconds) so it emits
        // `#EXT-X-START:TIME-OFFSET` and the first segment at the playhead is produced
        // immediately. Without this PMS transcodes from 0 and a deep client seek stalls
        // waiting on a segment the transcoder hasn't reached yet.
        let resumeMs = resumeOffsetMsOverride ?? item.viewOffset

        let offsetSeconds: Int? = if let resumeMs, resumeMs > 0 { resumeMs / 1000 } else { nil }
        let burnSubtitleStreamID = selectedBurnSubtitleStreamIDForCurrentPreferences()

        let transcode = TranscodeRequest(server: server,
                                         token: token,
                                         identity: identity,
                                         metadataKey: metadataKey,
                                         maxVideoBitrateKbps: requestedCap,
                                         sessionID: sessionID,
                                         mediaIndex: mediaIndex,
                                         partIndex: 0,
                                         burnSubtitleStreamID: burnSubtitleStreamID,
                                         startOffsetSeconds: offsetSeconds)

        var requestFields: [String: DiagnosticFieldValue] = [
            "requested_cap_kbps": .int(requestedCap),
            "selected_quality": .label(StreamingQuality.label(kbps: maxVideoBitrateKbps)),
            "resume": .millisecondsBucket(resumeMs),
            "start_offset": .secondsBucket(offsetSeconds.map(Double.init)),
            "part_index": .int(0),
            "profile": .label("visionos-hls"),
            "stop_previous": .bool(stoppingPreviousTranscode),
            "subtitle_auto_select": .label(UserDefaults.standard.string(forKey: PlaybackPreferenceKeys.subtitleAutoSelectMode) ?? SubtitleAutoSelectMode.manual.rawValue),
            "subtitle_burn_mode": .label(UserDefaults.standard.string(forKey: PlaybackPreferenceKeys.subtitleBurnMode) ?? SubtitleBurnMode.automatic.rawValue),
            "burning_subtitles": .bool(burnSubtitleStreamID != nil),
        ]
        requestFields.merge(sourceDiagnosticFields()) { _, new in new }
        recordPlaybackDiagnostic("playback.start_streaming", fields: requestFields)
        recordTranscodeDiagnostic("transcode.request", fields: requestFields)

        var decision: DecisionResponse?
        var streamURL = transcode.startM3U8URL()
        // This build decides afresh whether it commits to direct play, so disarm any prior
        // fallback and consume the one-shot probe suppression. `suppressDirectPlayProbe` is set
        // by the playback-time fallback below: when a committed direct-play stream fails to
        // load, the rebuild skips the probe and takes the maximum-transcode path instead.
        directPlayFallbackArmed = false
        let skipDirectPlayProbe = suppressDirectPlayProbe
        suppressDirectPlayProbe = false
        // "Direct Play / Maximum" asks PMS to direct-play the source bits when it can copy the
        // video; if it can't (or the probe fails) we fall through to the maximum transcode
        // below. Every capped rung — including "Maximum (transcoded)" — skips the probe and
        // transcodes. The user picks the path by picking the quality; there is no separate
        // toggle or pre-flight bandwidth gate (#31 superseded).
        if maxVideoBitrateKbps <= 0, !skipDirectPlayProbe, burnSubtitleStreamID == nil {
            do {
                let probe = try await client.send(transcode.directPlayProbeRequest(), as: DecisionResponse.self)
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                if probe.savesVideoEncode {
                    NSLog("PlaybackController: Direct Play / Maximum — PMS will copy video; committing direct-play start.m3u8")
                    var fields = decisionDiagnosticFields(probe)
                    fields["probe_result"] = .label("commit_direct_play")
                    recordTranscodeDiagnostic("transcode.direct_play_probe", fields: fields)
                    decision = probe
                    streamURL = transcode.directPlayStartM3U8URL()
                    // Arm the playback-time fallback: PMS agreed to copy, but the resulting HLS
                    // rendition may still fail to load (e.g. HEVC-in-TS AVFoundation won't play).
                    // If it does, degrade once to the maximum transcode rather than dead-ending.
                    directPlayFallbackArmed = true
                    #if DEBUG
                    // Log what PMS decided for this title (probe vs production), so a Debug build
                    // can tell whole-file direct play (mde=1000) from Direct Stream (video=copy)
                    // at a glance. DEBUG-only; never compiled into Release.
                    logDirectPlayDecision(transcode: transcode, probe: probe)
                    #endif
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
                    "fallback": .label("maximum_transcode"),
                ])
                NSLog("PlaybackController: direct-play probe failed (%@); using maximum transcode", String(describing: error))
            }
        }

        if decision == nil {
            do {
                let response = try await client.send(transcode.decisionRequest(), as: DecisionResponse.self)
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                decision = response
                recordTranscodeDiagnostic("transcode.decision", fields: decisionDiagnosticFields(response))
                if case .unsupported = response.decision {
                    recordTranscodeDiagnostic("transcode.unsupported", fields: decisionDiagnosticFields(response))
                    NSLog("PlaybackController: transcode decision unsupported: %@", String(describing: response.generalDecisionText))
                }
            } catch {
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                recordTranscodeDiagnostic("transcode.decision_failed", fields: [
                    "error": .error(error),
                    "fallback": .label("attempt_start_m3u8"),
                ])
                NSLog("PlaybackController: decision call failed (%@); attempting start.m3u8 anyway", String(describing: error))
            }
        }

        diagnostics.applyStatic(item: item,
                                mediaIndex: mediaIndex,
                                decision: decision,
                                server: server,
                                targetBitrateKbps: maxVideoBitrateKbps)
        var selectedFields: [String: DiagnosticFieldValue] = [
            "stream_url_shape": .urlShape(streamURL),
            "direct_play_fallback_armed": .bool(directPlayFallbackArmed),
            "decision_present": .bool(decision != nil),
        ]
        if let decision {
            selectedFields.merge(decisionDiagnosticFields(decision)) { _, new in new }
        }
        recordPlaybackDiagnostic("playback.stream_selected", fields: selectedFields)

        let asset = AVURLAsset(url: streamURL)
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
                NSLog("PlaybackController[dp-diag]: prod-decision  failed %@", String(describing: error))
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
            diagnostics.applyJellyfinSource(remoteSourceMetadata,
                                            playMethod: remotePlayMethod)
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
        fields.merge(jellyfinSourceDiagnosticFields(remoteSourceMetadata)) { _, new in new }
        recordPlaybackDiagnostic("playback.start_path", fields: fields)

        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        load(playerItem, resumeOffsetMs: resumeOffsetMs ?? item.viewOffset)
    }

    private func playableRemoteStreamURL(_ url: URL, resumeOffsetMs: Int?) async -> URL {
        guard remotePlayMethod == .transcode,
              let resumeOffsetMs, resumeOffsetMs > 0,
              let primedURL = jellyfinHLSURL(url, startTimeTicks: resumeOffsetMs * 10_000)
        else { return url }

        let proxy = MediaSessionProxy(controlSend: { _ in Data() },
                                      strippedPlaylistQueryItemNames: ["starttimeticks"],
                                      injectedPlaylistStartTimeOffsetSeconds: Double(resumeOffsetMs) / 1000.0)
        do {
            let handle = try await proxy.standUpLoopback(forStream: primedURL)
            if let oldProxy = jellyfinHLSProxy, let oldGeneration = jellyfinHLSProxyGeneration {
                await oldProxy.stop(generation: oldGeneration)
            }
            jellyfinHLSProxy = proxy
            jellyfinHLSProxyGeneration = handle.generation
            recordPlaybackDiagnostic("playback.remote_hls_proxy_open", fields: [
                "target": .millisecondsBucket(resumeOffsetMs),
                "strips_start_time_ticks": .bool(true),
            ])
            return handle.localURL
        } catch {
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

    /// Build an artwork `AVMetadataItem` (`.commonIdentifierArtwork`) from raw image data.
    private static func artworkMetadataItem(data: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierArtwork
        item.value = data as NSData
        item.dataType = kCMMetadataBaseDataType_JPEG as String
        item.extendedLanguageTag = "und"
        return item
    }

    /// Populate `playerItem.externalMetadata` so the player chrome / Now Playing shows the
    /// real title + artwork instead of a filename. Sets the text items synchronously, then
    /// fetches the poster image off the main actor (best-effort) and appends it once it
    /// arrives. Never blocks playback: on any failure the chrome simply shows no artwork.
    ///
    /// Artwork is only fetched for streaming sessions (where we have the server + token to hit
    /// `/photo/:/transcode`); local-file playback gets the text items only.
    private func attachExternalMetadata(to playerItem: AVPlayerItem) {
        let textItems = textExternalMetadata()
        playerItem.externalMetadata = textItems

        guard let server, let token else { return }
        let imagePath = item.thumb ?? item.art
        guard let imagePath, !imagePath.isEmpty,
              let url = Self.posterTranscodeURL(imagePath: imagePath, server: server, token: token)
        else { return }

        Task { [weak self, weak playerItem] in
            // Fetch returns Sendable Data off-actor; metadata is then built/set on the main
            // actor where AVMetadataItem / AVPlayerItem live.
            guard let data = await Self.fetchArtworkData(url: url) else { return }
            await MainActor.run {
                guard let self, let playerItem else { return }
                // Only attach if this is still the player's current item (a Quality reload may
                // have swapped it out from under the in-flight fetch).
                guard self.player.currentItem === playerItem else { return }
                playerItem.externalMetadata = textItems + [Self.artworkMetadataItem(data: data)]
            }
        }
    }

    /// Best-effort artwork fetch. Returns `nil` (never throws) on any failure so it can't
    /// black-hole playback. `nonisolated` + returns Sendable `Data`.
    private nonisolated static func fetchArtworkData(url: URL) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) { return nil }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    /// Build the `/photo/:/transcode` URL for an image path, mirroring `PosterImage` /
    /// `DownloadManager`. Requests a poster-sized image so the chrome artwork stays small.
    private nonisolated static func posterTranscodeURL(imagePath: String, server: URL, token: String) -> URL? {
        guard var comps = URLComponents(url: server.appendingPathComponent("/photo/:/transcode"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        PlexURLQueryEncoder.replaceQueryItems([
            .init(name: "url", value: imagePath),
            .init(name: "width", value: "600"),
            .init(name: "height", value: "900"),
            .init(name: "minSize", value: "1"),
            .init(name: "upscale", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ], in: &comps)
        return comps.url
    }

    /// Builds a `/photo/:/transcode` URL for a chapter thumbnail key, sized 16:9
    /// landscape. Returns nil when offline (no server/token) or the key is empty.
    ///
    /// The Chapters info-tab rail can't use `PosterImage` (which reads `AppModel`
    /// from the SwiftUI environment): AVKit hosts each info tab in its own
    /// `UIHostingController`, outside that environment. The controller already
    /// holds the server + token, so it vends the URL directly instead.
    func chapterThumbnailURL(for imagePath: String?) -> URL? {
        guard let imagePath, !imagePath.isEmpty else { return nil }

        // Jellyfin chapters are carried through PMSKit's shared `Chapter.thumb` as a synthetic
        // stable key. The player is the only place that has the resolved remote HLS URL, so it
        // derives the server base here and asks Jellyfin's native chapter-image endpoint for a
        // 16:9 thumbnail. Keep this purely an image URL translation; do not touch playback state.
        if let jellyfin = parsedJellyfinChapterImagePath(imagePath),
           let base = remoteStreamURL.flatMap(jellyfinServerBaseURL(from:)) {
            return try? JellyfinLibrary.chapterImageURL(server: base,
                                                        itemId: jellyfin.itemId,
                                                        chapterIndex: jellyfin.index,
                                                        tag: jellyfin.tag,
                                                        width: 480,
                                                        height: 270)
        }

        guard let server, let token else { return nil }
        guard var comps = URLComponents(url: server.appendingPathComponent("/photo/:/transcode"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        PlexURLQueryEncoder.replaceQueryItems([
            .init(name: "url", value: imagePath),
            .init(name: "width", value: "480"),
            .init(name: "height", value: "270"),
            .init(name: "minSize", value: "1"),
            .init(name: "upscale", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ], in: &comps)
        return comps.url
    }

    private func parsedJellyfinChapterImagePath(_ imagePath: String) -> (itemId: String, index: Int, tag: String?)? {
        guard let url = URL(string: imagePath),
              url.scheme == "jellyfin",
              url.host == "item" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "Chapter", let index = Int(parts[2]) else { return nil }
        let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "tag" }?
            .value
        return (parts[0], index, tag)
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
        // Reset per-item state for the new player item: a fresh load is a fresh resume
        // (didSeek), a fresh readiness gate, and a clean error surface (P2/P3/P8).
        didSeek = false
        timeline.isReadyForReporting = false
        didApplySavedSubtitle = false
        didApplyAudioPreference = false
        pendingResumeMs = resumeOffsetMs
        // Echo baseline: the resume seek's own `timeJumpedNotification` lands at this offset;
        // suppress nearby jumps so a rebuild does not immediately schedule another rebuild.
        lastPrimedOffsetMs = resumeOffsetMs ?? 0
        playbackError.clear()
        // Clear any active Skip affordance for the (re)loaded item. The skip RANGES are
        // unchanged across a Quality reload (same `item`), so we only reset the live UI
        // state here; the new fine-grained observer will re-derive the active marker.
        skipMarker.clear()
        // Configure + activate the shared audio session before the item starts (#17), and
        // register the interruption / route-change / background observers once. Both are
        // idempotent across a Quality reload (which re-enters here): the session is already
        // active and `installObservers()` no-ops on its second call.
        audioSession.activate()
        audioSession.installObservers()
        // Forward-buffer tuning (#21 / #43). A deep buffer is useful for Plex/static/direct
        // playback, where AVPlayer can pull media faster than realtime. It is actively harmful
        // for Jellyfin live HLS transcodes after a seek: the transcoder can only mint segments
        // around realtime, and with a 600s target AVPlayer often flips back to `.waiting` after
        // the first post-seek frame even though Jellyfin/ffmpeg are healthy. Keep the deep
        // buffer for non-Jellyfin-transcode paths, but use a small window and let playback run
        // as soon as segments arrive for backend-resolved transcodes.
        let isRemoteTranscode = remoteStreamURL != nil && remotePlayMethod == .transcode
        playerItem.preferredForwardBufferDuration = isRemoteTranscode ? 12 : 600
        player.automaticallyWaitsToMinimizeStalling = !isRemoteTranscode
        // Populate Now Playing / cinema-chrome metadata (title + summary now, artwork async).
        // Done for both streaming and local-file paths so the player shows the real title.
        attachExternalMetadata(to: playerItem)
        nextPlayerItemGeneration += 1
        currentPlayerItemGeneration = nextPlayerItemGeneration
        ignoredRecoverableFailedToEndCount = 0
        let itemGeneration = currentPlayerItemGeneration
        let observedPlaybackGeneration = playbackGeneration
        player.replaceCurrentItem(with: playerItem)
        recordPlaybackDiagnostic("playback.item_loaded", fields: [
            "resume": .millisecondsBucket(resumeOffsetMs),
            "preferred_forward_buffer_seconds": .int(Int(playerItem.preferredForwardBufferDuration)),
            "item_generation": .int(itemGeneration),
        ])
        installObservers(for: playerItem,
                         resumeOffsetMs: resumeOffsetMs,
                         itemGeneration: itemGeneration,
                         observedPlaybackGeneration: observedPlaybackGeneration)
        startDiagnosticsSampling()
        if userWantsPaused {
            player.pause()
            transport.set(paused: true)
        } else {
            player.play()
        }
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
                self.maybeRecordDiagnosticSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsTimer = timer
    }

    private func installObservers(for playerItem: AVPlayerItem,
                                  resumeOffsetMs: Int?,
                                  itemGeneration: Int,
                                  observedPlaybackGeneration: Int) {
        // Observe item status for its WHOLE lifetime (P4 #8): handle both the resume
        // seek on `.readyToPlay` AND a later `.failed`. The old code self-nilled this
        // observation inside the readyToPlay branch, so a subsequent ready→failed
        // transition (e.g. transcode dies mid-stream) was never seen.
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] pItem, _ in
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
                    self.recordPlaybackDiagnostic("playback.item_status", fields: [
                        "status": .label("readyToPlay"),
                        "duration": .secondsBucket(pItem.duration.seconds),
                    ])
                    // Gate timeline/scrobble heartbeats until we actually have content +
                    // a real duration (P8 #11) so we don't post duration=0/time≈0.
                    let durSecs = pItem.duration.seconds
                    if durSecs.isFinite && durSecs > 0 {
                        self.timeline.isReadyForReporting = true
                    }
                    // Reapply the user's saved subtitle-language preference to this item's
                    // legible group (once per item; gated inside). Runs on each fresh item —
                    // including after a Quality reload swaps the AVPlayerItem.
                    await self.applySavedSubtitlePreferenceIfNeeded()
                    // Likewise reapply the saved audio-language preference to this item's
                    // audible group (#3; once per item, gated inside).
                    await self.applySavedAudioPreferenceIfNeeded()
                    // Reapply the persisted playback speed (R5). A fresh item / Quality reload
                    // resets the player's rate to 1.0, so re-push the user's choice now that the
                    // item is ready — without this a reload would silently drop back to 1.0×.
                    if self.userWantsPaused {
                        self.player.pause()
                        self.buffering.set(false)
                        self.transport.set(paused: true)
                        self.transport.setPauseRequested(false)
                        self.recordPlaybackDiagnostic("playback.pause_intent_honored", fields: [
                            "status": .label("readyToPlay"),
                        ])
                    } else {
                        self.applyPlaybackSpeed()
                    }
                    // Resume seek, exactly once (didSeek). Offset priming is the fast
                    // path; this is the CLIENT-SIDE FALLBACK (P2 #9): if PMS didn't honor
                    // `#EXT-X-START` and we're sitting at ~0 while a resume was requested,
                    // seek there ourselves.
                    if !self.didSeek, let resumeOffsetMs, resumeOffsetMs > 0 {
                        let current = self.player.currentTime().seconds
                        let nearZero = !current.isFinite || current < 1.0
                        let isBackendRemoteTranscode = self.remoteStreamURL != nil && self.remotePlayMethod == .transcode
                        if nearZero, !isBackendRemoteTranscode {
                            let target = CMTime(value: CMTimeValue(resumeOffsetMs), timescale: 1000)
                            let tolerance: CMTime = .zero
                            self.player.seek(to: target,
                                             toleranceBefore: tolerance,
                                             toleranceAfter: tolerance,
                                             completionHandler: { [weak self] finished in
                                                 guard finished else { return }
                                                 Task { @MainActor [weak self] in
                                                     guard let self, !self.userWantsPaused else { return }
                                                     self.applyPlaybackSpeed()
                                                 }
                                             })
                        }
                        self.didSeek = true
                    }
                    self.maybeRecordDiagnosticSnapshot(force: true)
                case .failed:
                    self.recordPlaybackDiagnostic("playback.item_status", fields: [
                        "status": .label("failed"),
                        "error": .error(pItem.error),
                    ])
                    self.handlePlaybackFailure(pItem.error,
                                               source: .itemStatusFailed,
                                               playerItem: pItem,
                                               itemGeneration: itemGeneration,
                                               observedPlaybackGeneration: observedPlaybackGeneration)
                default:
                    break
                }
            }
        }

        // A start.m3u8 that begins playing but then dies (transcode tears down, segment
        // 404s) fires this rather than flipping item.status (P3 #8). Treat it the same.
        failedToEndObserver = NotificationCenter.default.addObserver(
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
        }

        // Final-target rebuild recovery (#33 reset): `timeJumpedNotification` is the only
        // in-process signal of a user seek on visionOS. In-buffer jumps stay native;
        // out-of-buffer jumps are debounced and rebuilt once at the settled target.
        timeJumpedObserver = NotificationCenter.default.addObserver(
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
        }

        // Periodic heartbeat ~ every 10s.
        let interval = CMTime(seconds: timelineIntervalSeconds, preferredTimescale: 1)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let state: TimelineRequest.State = self.player.timeControlStatus == .paused ? .paused : .playing
                self.timeline.report(state: state, force: false)
                // Progress-based scrobble (P9 #11): capped-HLS viewers often stop short of
                // EOF, so didPlayToEnd never fires and the item stays "unwatched." Mark it
                // watched once we cross ~90%; didPlayToEnd remains the backstop.
                self.timeline.scrobbleIfNearEnd()
            }
        }

        // Marker detection (#14): a finer ~0.5s observer that toggles the Skip
        // Intro/Skip Credits button as the playhead enters/leaves an intro/credits range.
        // Separate from the 10s heartbeat above, which is too coarse for a live button.
        let markerInterval = CMTime(seconds: 0.5, preferredTimescale: 600)
        markerTimeObserver = player.addPeriodicTimeObserver(forInterval: markerInterval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.updateSkipMarker(at: time.seconds)
                // Drive the Up Next card (#15) off the same fine-grained observer.
                self.updateUpNext(at: time.seconds)
            }
        }

        // Fire on play/pause transitions.
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            guard let self else { return }
            let status = avPlayer.timeControlStatus
            Task { @MainActor in
                let paused = status == .paused || self.userWantsPaused
                self.timeline.report(state: paused ? .paused : .playing, force: true)
                self.transport.set(paused: paused)
                if paused || status == .playing {
                    self.transport.setPauseRequested(false)
                }
                if self.lastDiagnosticTimeControlStatus != status {
                    self.lastDiagnosticTimeControlStatus = status
                    self.recordPlaybackDiagnostic("playback.time_control_status", fields: [
                        "status": .label(Self.timeControlStatusLabel(status)),
                    ])
                }
            }
        }

        // Rebuffer/stall spinner (#21). `timeControlStatus` is the precise signal: the player
        // is `.waitingToPlayAtSpecifiedRate` exactly while it's stalled waiting on data (or the
        // initial prime), `.playing` once it has enough, and `.paused` when the USER pauses —
        // so reading this status alone correctly avoids showing the spinner on a manual pause.
        // We hop to the main actor and pass only a Sendable enum, satisfying strict concurrency.
        bufferingObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            guard let self else { return }
            let status = avPlayer.timeControlStatus
            Task { @MainActor in
                let isStalled = (status == .waitingToPlayAtSpecifiedRate && !self.userWantsPaused)
                self.setBufferingVisible(isStalled)
                // Stall watchdog (#8 hardening): a network-loss stall often never flips
                // item.status to .failed, so arm a timeout while the player is starved and
                // cancel it the instant playback genuinely resumes. We deliberately do NOT
                // cancel on `.paused` — handleStallTimeout's buffer-empty check distinguishes a
                // dead stall from a user pause on already-buffered content.
                if isStalled {
                    self.armStallWatchdog()
                } else if status == .playing {
                    self.cancelStallWatchdog()
                    // Real playback = the failure is over. Clear any surfaced error so its
                    // Retry/Close affordance can't linger over playing video: a stall we
                    // surfaced (handleStallTimeout pauses + sets the error) sometimes recovers
                    // and resumes anyway — in the expanded cinema scene the pause doesn't always
                    // hold — and without this the AVKit Retry/Close pills stay stuck on screen,
                    // reading as dead because the state behind them no longer matches (seen live).
                    self.playbackError.clear()
                    // Real playback = a successful (re)start: clear any "Reconnecting…" overlay
                    // PlayerView raised for a failure-recovery rebuild (GH #33).
                    self.onPlaybackActive?()
                }
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
                guard self.isCurrentObservedItem(playerItem,
                                                 itemGeneration: itemGeneration,
                                                 observedPlaybackGeneration: observedPlaybackGeneration) else {
                    self.recordIgnoredPlayerItemEvent("did_play_to_end",
                                                      playerItem: playerItem,
                                                      itemGeneration: itemGeneration,
                                                      observedPlaybackGeneration: observedPlaybackGeneration)
                    return
                }
                self.maybeRecordDiagnosticSnapshot(force: true)
                self.recordPlaybackDiagnostic("playback.ended", fields: [
                    "resume": .millisecondsBucket(self.currentResumeMs),
                ])
                self.timeline.report(state: .stopped, force: true)
                self.timeline.scrobble()
                // Play-to-end with a resolved, un-cancelled next item: autoplay it (#15).
                // `advanceToNextItem` re-flushes timeline/scrobble idempotently.
                if self.upNext.nextItem != nil, !self.upNext.isCancelled, self.autoPlayUpNextEnabled {
                    self.advanceToNextItem()
                } else {
                    self.player.pause()
                    self.onPlaybackEnded?()
                }
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let markerTimeObserver {
            player.removeTimeObserver(markerTimeObserver)
            self.markerTimeObserver = nil
        }
        statusObservation = nil
        rateObservation = nil
        bufferingObservation = nil
        bufferingDelayTask?.cancel()
        bufferingDelayTask = nil
        // Cancel the stall watchdog so a stale timer can't fire across a reload / Retry /
        // teardown and surface an error against a freshly-loaded item.
        cancelStallWatchdog()
        if let timeJumpedObserver {
            NotificationCenter.default.removeObserver(timeJumpedObserver)
            self.timeJumpedObserver = nil
        }
        // Drop any armed final-target rebuild so a debounced timer can't fire against a freshly-loaded item.
        cancelPendingFinalTargetRebuild()
        // Clear any lingering spinner state across a reload/teardown so it can't get stuck on.
        buffering.set(false)
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        if let didEndObserver {
            NotificationCenter.default.removeObserver(didEndObserver)
            self.didEndObserver = nil
        }
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
    }

    private func setBufferingVisible(_ isBuffering: Bool) {
        bufferingDelayTask?.cancel()
        bufferingDelayTask = nil
        guard isBuffering else {
            buffering.set(false)
            return
        }
        // Show feedback for real initial primes/rebuffers, but don't flash the card for the
        // quick `.waiting → ready` transitions common after Jellyfin HLS seek/reopen.
        bufferingDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self, !Task.isCancelled, !self.userWantsPaused else { return }
            guard self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            self.buffering.set(true)
        }
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
        if UserDefaults.standard.object(forKey: PlaybackPreferences.Keys.upNextCountdownSeconds) == nil {
            return PlaybackPreferences.defaultUpNextCountdownSeconds
        }
        return UserDefaults.standard.integer(forKey: PlaybackPreferences.Keys.upNextCountdownSeconds)
    }

    private var autoPlayUpNextEnabled: Bool {
        if UserDefaults.standard.object(forKey: PlaybackPreferences.Keys.autoPlayUpNext) == nil { return true }
        return UserDefaults.standard.bool(forKey: PlaybackPreferences.Keys.autoPlayUpNext)
    }

    private func skipMode(for kind: SkipMarkerState.Kind) -> PlaybackPreferences.SkipMode {
        let key = kind == .intro ? PlaybackPreferences.Keys.skipIntroMode : PlaybackPreferences.Keys.skipCreditsMode
        let raw = UserDefaults.standard.string(forKey: key) ?? PlaybackPreferences.SkipMode.manual.rawValue
        return PlaybackPreferences.SkipMode(rawValue: raw) ?? .manual
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
    private func resolveNextItem() async {
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
        onAdvanceToNext?(next)
    }

    // MARK: - Failure handling

    private func isCurrentObservedItem(_ observedItem: AVPlayerItem,
                                       itemGeneration: Int,
                                       observedPlaybackGeneration: Int) -> Bool {
        player.currentItem === observedItem &&
            currentPlayerItemGeneration == itemGeneration &&
            playbackGeneration == observedPlaybackGeneration
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
        let isRemoteHLS = remoteStreamReopener != nil && remotePlayMethod != .directPlay
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
        // couldn't play the resulting HLS rendition. Degrade ONCE to the maximum-transcode path
        // (resuming at the live playhead) instead of surfacing a dead-end. Armed only while a
        // direct-play stream is live and consumed here, so the transcode rebuild — or any later
        // failure — surfaces normally; the rebuild can't loop back into another direct play.
        if directPlayFallbackArmed {
            directPlayFallbackArmed = false
            suppressDirectPlayProbe = true
            let resumeMs = currentResumeMs
            recordTranscodeDiagnostic("transcode.direct_play_runtime_fallback", fields: [
                "error": .error(error),
                "resume": .millisecondsBucket(resumeMs),
                "fallback": .label("maximum_transcode"),
            ])
            NSLog("PlaybackController: direct-play stream failed to load (%@); falling back to maximum transcode",
                  String(describing: error))
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
              String(describing: error))
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
        playbackError.set(error)
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
    private let remoteTranscodeStallTimeoutSeconds: TimeInterval = 45

    private var activeStallTimeoutSeconds: TimeInterval {
        remoteStreamURL != nil && remotePlayMethod == .transcode
            ? remoteTranscodeStallTimeoutSeconds
            : stallTimeoutSeconds
    }

    /// Arm the stall watchdog if it isn't already running and no error is being shown. Idempotent
    /// so repeated `.waitingToPlayAtSpecifiedRate` callbacks don't reset the countdown.
    private func armStallWatchdog() {
        guard stallWatchdog == nil, !playbackError.isFailed else { return }
        recordPlaybackDiagnostic("playback.stall_watchdog_armed", fields: [
            "timeout_seconds": .int(Int(activeStallTimeoutSeconds)),
        ])
        let timer = Timer(timeInterval: activeStallTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleStallTimeout()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallWatchdog = timer
    }

    /// Cancel the stall watchdog (genuine resume, teardown, or retry).
    private func cancelStallWatchdog() {
        if stallWatchdog != nil {
            recordPlaybackDiagnostic("playback.stall_watchdog_cancelled")
        }
        stallWatchdog?.invalidate()
        stallWatchdog = nil
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
    /// We surface DIRECTLY (no silent auto-retry): the watchdog already gave the stream 15s to
    /// recover, and over a dead network a retry would just stall again. The overlay's Retry
    /// rebuilds the session once the user's connection is back.
    private func handleStallTimeout() {
        cancelStallWatchdog()
        guard !playbackError.isFailed, let current = player.currentItem else { return }
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              !current.isPlaybackLikelyToKeepUp else { return }
        var fields = runtimeSnapshotFields()
        fields["keep_up"] = .bool(current.isPlaybackLikelyToKeepUp)
        if let underlying = current.error {
            fields["error"] = .error(underlying)
            recordPlaybackDiagnostic("playback.stall_watchdog_fired", fields: fields)
            NSLog("PlaybackController: stream stalled, surfacing failure (%@)",
                  String(describing: underlying))
            surfaceFailure(underlying)
        } else {
            recordPlaybackDiagnostic("playback.stall_watchdog_fired", fields: fields)
            NSLog("PlaybackController: stream stalled with no item error; surfacing generic failure")
            surfaceFailure(NSError(
                domain: "PlexAVPApp.Playback", code: -1001,
                userInfo: [NSLocalizedDescriptionKey:
                    "Playback stalled. The server or network may be unreachable. Tap Retry once your connection is back."]))
        }
    }

    // MARK: - Seek final-target rebuild (#33 reset)

    /// Handle a playhead jump on the current item. Streaming only. If the target is already
    /// buffered, AVKit owns the seek natively. If it is outside the loaded range, record the target
    /// and debounce so a drag collapses to one final-target rebuild.
    private func handleSeekJump() {
        guard supportsSeekReprime, !playbackError.isFailed else { return }
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

        if isWithinLoadedRanges(seconds: now) {
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
        finalTargetRebuildPolicy.recordFinalTarget(offsetMs: targetMs)
        finalTargetSettleTask?.cancel()
        finalTargetSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.finalTargetSettleNanos)
            guard let self, !Task.isCancelled else { return }
            guard self.supportsSeekReprime, !self.playbackError.isFailed else { return }
            guard let target = self.finalTargetRebuildPolicy.consumePendingTarget() else { return }
            self.finalTargetSettleTask = nil
            if self.remoteStreamReopener != nil {
                self.reopenRemoteStream(offsetMs: target, bitrateKbps: self.maxVideoBitrateKbps)
            } else {
                guard self.isStreaming else { return }
                self.beginFinalTargetRebuild(toMs: target)
            }
        }
    }

    private func reopenRemoteStream(offsetMs: Int, bitrateKbps: Int) {
        guard let remoteStreamReopener else { return }
        playbackTask?.cancel()
        playbackGeneration += 1
        let generation = playbackGeneration
        lastPrimedOffsetMs = offsetMs
        let priorStop = didStopRemoteSession ? nil : onStopRemoteSession
        let priorPlaySessionId = remotePlaySessionId
        // Detach the old AVPlayerItem before asking Jellyfin for a replacement stream. The
        // simulator logs for #43 showed AVPlayer surfacing NSURLErrorDomain -1008 immediately
        // after we deleted the active Jellyfin encoding during a seek/reopen; stale init/segment
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
                                                        audioStreamIndex: audioStreamIDOverride,
                                                        subtitleStreamIndex: subtitleStreamIndexOverride)
                let reopened = try await remoteStreamReopener(request)
                guard !Task.isCancelled, generation == self.playbackGeneration else {
                    reopened.onStop?()
                    return
                }
                self.remoteHTTPHeaders = reopened.headers
                self.remotePlaySessionId = reopened.playSessionId
                if let sourceMetadata = reopened.sourceMetadata {
                    self.remoteSourceMetadata = sourceMetadata
                }
                if let playMethod = reopened.playMethod {
                    self.remotePlayMethod = playMethod
                }
                self.onStopRemoteSession = reopened.onStop
                self.didStopRemoteSession = false
                let playableURL = await self.playableRemoteStreamURL(reopened.url,
                                                                      resumeOffsetMs: offsetMs)
                self.loadRemoteStream(playableURL, headers: reopened.headers, resumeOffsetMs: offsetMs)
                let samePlaySession = priorPlaySessionId != nil && priorPlaySessionId == reopened.playSessionId
                if samePlaySession {
                    self.recordPlaybackDiagnostic("playback.remote_stop_skipped", fields: [
                        "reason": .label("same_play_session"),
                    ])
                } else {
                    self.scheduleDeferredRemoteSessionStop(priorStop,
                                                           reason: "after_reopen_item_detached",
                                                           delaySeconds: 2.0)
                }
            } catch {
                guard !Task.isCancelled, generation == self.playbackGeneration else { return }
                self.recordPlaybackDiagnostic("playback.remote_reopen_failed", fields: [
                    "error": .error(error),
                    "target": .millisecondsBucket(offsetMs),
                ])
                NSLog("PlaybackController: remote stream reopen failed (%@)", String(describing: error))
                self.surfaceFailure(NSError(
                    domain: "PlexAVPApp.Playback", code: -1004,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Couldn't reopen the stream at that position. Tap Retry or try a lower quality setting."]))
                self.didStopRemoteSession = true
                self.onStopRemoteSession = nil
                self.remotePlaySessionId = nil
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
            finalTargetSettleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard let self, !Task.isCancelled else { return }
                guard let target = self.finalTargetRebuildPolicy.consumePendingTarget() else { return }
                self.finalTargetSettleTask = nil
                self.beginFinalTargetRebuild(toMs: target)
            }
        case .escalate:
            recordPlaybackDiagnostic("playback.seek_rebuild_escalated", fields: [
                "target": .millisecondsBucket(targetMs),
            ])
            surfaceFailure(NSError(
                domain: "PlexAVPApp.Playback", code: -1002,
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

    private func diagnosticFields(_ fields: [String: DiagnosticFieldValue]) -> [String: DiagnosticFieldValue] {
        var merged: [String: DiagnosticFieldValue] = [
            "session": .identifier(sessionID),
            "item_type": .label(item.type),
            "media_index": .int(mediaIndex),
            "quality_label": .label(StreamingQuality.label(kbps: maxVideoBitrateKbps)),
            "quality_kbps": .int(maxVideoBitrateKbps),
        ]
        merged.merge(fields) { _, new in new }
        return merged
    }

    private func sourceDiagnosticFields() -> [String: DiagnosticFieldValue] {
        let media = item.media.flatMap { mediaItems -> Media? in
            if mediaItems.indices.contains(mediaIndex) { return mediaItems[mediaIndex] }
            return mediaItems.first
        }
        let part = media?.part.first
        var fields: [String: DiagnosticFieldValue] = [
            "source_container": .label(media?.container ?? part?.container),
            "source_video_codec": .label(media?.videoCodec ?? part?.videoStreams.first?.codec),
            "source_audio_codec": .label(media?.audioCodec ?? part?.audioStreams.first?.codec),
            "source_bitrate_kbps": .int(media?.bitrate ?? 0),
            "duration": .millisecondsBucket(media?.duration ?? item.duration),
            "part_index": .int(0),
            "subtitle_mode": .label((part?.subtitleStreams.isEmpty == false) ? "available" : "none"),
        ]
        if let width = media?.width, let height = media?.height {
            fields["source_resolution"] = .label("\(width)x\(height)")
        }
        if let channels = part?.audioStreams.first?.channels {
            fields["source_audio_channels"] = .int(channels)
        }
        return fields
    }

    private func jellyfinSourceDiagnosticFields(_ source: JellyfinPlaybackSourceMetadata?) -> [String: DiagnosticFieldValue] {
        guard let source else { return [:] }
        var fields: [String: DiagnosticFieldValue] = [
            "source_container": .label(source.container),
            "source_video_codec": .label(source.videoCodec),
            "source_audio_codec": .label(source.audioCodec),
            "source_bitrate_kbps": .int(source.bitrate ?? 0),
        ]
        if let width = source.width, let height = source.height {
            fields["source_resolution"] = .label("\(width)x\(height)")
        }
        return fields
    }

    private func decisionDiagnosticFields(_ decision: DecisionResponse) -> [String: DiagnosticFieldValue] {
        var fields: [String: DiagnosticFieldValue] = [
            "pms_decision_mode": .label(Self.decisionModeLabel(decision)),
            "saves_video_encode": .bool(decision.savesVideoEncode),
            "plays_whole_file_directly": .bool(decision.playsWholeFileDirectly),
            "part_decision": .label(decision.partDecision),
            "video_decision": .label(decision.videoDecision),
            "audio_decision": .label(decision.audioDecision),
        ]
        if let code = decision.generalDecisionCode {
            fields["general_decision_code"] = .int(code)
        }
        if let code = decision.mdeDecisionCode {
            fields["mde_decision_code"] = .int(code)
        }
        if let text = decision.generalDecisionText {
            fields["general_decision_text"] = .text(text)
        }
        if let text = decision.mdeDecisionText {
            fields["mde_decision_text"] = .text(text)
        }
        return fields
    }

    private static func decisionModeLabel(_ decision: DecisionResponse) -> String {
        switch decision.decision {
        case .directPlay:
            return "direct_play"
        case .transcode:
            return "transcode"
        case .unsupported:
            return "unsupported"
        }
    }

    private func runtimeSnapshotFields() -> [String: DiagnosticFieldValue] {
        [
            "target_bitrate_kbps": .int(diagnostics.targetBitrateKbps),
            "target_bitrate_label": .label(diagnostics.targetBitrateLabel),
            "source_bitrate_kbps": .int(diagnostics.sourceBitrateKbps),
            "observed_bitrate_kbps": .double(diagnostics.observedBitrateKbps),
            "indicated_bitrate_kbps": .double(diagnostics.indicatedBitrateKbps),
            "required_bitrate_kbps": .double(diagnostics.requiredBitrateKbps),
            "buffer_ahead_seconds": .double(diagnostics.bufferedAheadSeconds),
            "likely_to_keep_up": .bool(diagnostics.likelyToKeepUp),
            "stall_count": .int(diagnostics.stalls),
            "dropped_frames": .int(diagnostics.droppedFrames),
            "is_transcoding": .bool(diagnostics.isTranscoding),
            "decision_summary": .text(diagnostics.decisionText),
        ]
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

    private static func timeControlStatusLabel(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused:
            return "paused"
        case .waitingToPlayAtSpecifiedRate:
            return "waiting"
        case .playing:
            return "playing"
        @unknown default:
            return "unknown"
        }
    }

    private static func itemStatusLabel(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "readyToPlay"
        case .failed:
            return "failed"
        @unknown default:
            return "unknown"
        }
    }

    private static func playerStatusLabel(_ status: AVPlayer.Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .readyToPlay:
            return "readyToPlay"
        case .failed:
            return "failed"
        @unknown default:
            return "unknown"
        }
    }

    private static func errorDomainFamily(_ domain: String) -> String {
        switch domain {
        case NSURLErrorDomain:
            return "nsurl"
        case AVFoundationErrorDomain:
            return "avfoundation"
        case NSOSStatusErrorDomain:
            return "osstatus"
        case CocoaError.errorDomain:
            return "cocoa"
        case POSIXError.errorDomain:
            return "posix"
        default:
            let lower = domain.lowercased()
            if lower.contains("coremedia") { return "coremedia" }
            if lower.contains("fig") { return "fig" }
            if lower.contains("audio") { return "audio" }
            return "other"
        }
    }

}

/// Observable failure surface for a `PlaybackController`. Modeled as its own object
/// (mirroring `PlaybackDiagnostics`) so PlayerView/DetailView can react to a failure and
/// show an error + Retry without the whole controller needing to be `@Observable`.
/// Error surfaced when a failure-recovery rebuild can't reach playback within the View's
/// reconnect watchdog window (GH #33). Its `localizedDescription` becomes the Retry/Close
/// overlay's message, so it's written for the viewer, not the log.
struct ReconnectTimeoutError: LocalizedError {
    var errorDescription: String? {
        "Couldn't reconnect to the server. It may be busy or briefly unreachable — try again."
    }
}

@Observable
@MainActor
final class PlaybackError {
    /// True when playback has failed and the UI should present the error + Retry.
    private(set) var isFailed = false
    /// A human-readable description of the failure, if AVFoundation provided one.
    private(set) var message: String?

    /// Mark a failure for display. Stores the localized description when available.
    func set(_ error: Error?) {
        isFailed = true
        message = error?.localizedDescription
    }

    /// Clear the failure state (on (re)start / retry).
    func clear() {
        isFailed = false
        message = nil
    }
}

/// Observable state for the playback-speed selection (R5). Modeled as its own object
/// (mirroring `PlaybackError`/`SkipMarkerState`) so the Speed info-panel tab renders the
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
