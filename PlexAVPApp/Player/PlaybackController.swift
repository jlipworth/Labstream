import Foundation
import AVKit
import AVFAudio
import UIKit
import PMSKit

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

    /// Per-playback transcode session id (also reused as the timeline session).
    private let sessionID = "plex-avp-" + UUID().uuidString

    /// `@AppStorage`-style key for the Direct Stream opt-in (#7 Step 3) — shared with
    /// SettingsView's toggle, default OFF. Read fresh from UserDefaults on every
    /// (re)build (`startStreaming`), so flipping the toggle mid-session takes effect on
    /// the next stream rebuild: the in-headset kill switch from the research/15 plan.
    static let directStreamEnabledKey = "directStreamEnabled"

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
    private var failedToEndObserver: NSObjectProtocol?
    /// Watchdog for a stalled stream (#8 hardening). HLS network loss frequently manifests as a
    /// PERMANENT stall — the player sits in `.waitingToPlayAtSpecifiedRate` with an empty buffer
    /// and never flips `AVPlayerItem.status` to `.failed` (AVKit paints its own placeholder glyph
    /// from the error log, but neither the status observer nor `failedToPlayToEnd` fires). This
    /// timer is the catch-all: armed while the player is starved, it surfaces the error+Retry
    /// overlay if the stall outlasts `stallTimeoutSeconds`, turning a dead-end into a recoverable
    /// state. Cancelled the moment playback genuinely resumes (`.playing`).
    private var stallWatchdog: Timer?
    /// Observer for `AVPlayerItem.timeJumpedNotification` — the only in-process signal of a user
    /// seek on visionOS (#25): AVKit's user-navigation delegate callbacks
    /// (`willResumePlaybackAfterUserNavigatedFromTime:toTime:`) are `API_UNAVAILABLE(visionos)`,
    /// checked in the XROS 26.5 AVPlayerViewController.h.
    private var timeJumpedObserver: NSObjectProtocol?
    /// Debounce/confirmation timer for a seek that lands the player in starved territory (#25).
    /// Re-armed on every jump so a user scrubbing around coalesces onto the last target.
    private var seekRestartTimer: Timer?
    /// True once the CURRENT item has genuinely played (reached `.playing`). Gates the
    /// seek-during-stall restart (#25): the start path repositions the playhead itself (offset
    /// priming / the client-side resume fallback), and a slow initial prime must not be misread
    /// as a dead seek — the stall watchdog owns start-time recovery. Reset per item in `load(_:)`.
    private var hasPlayedThisItem = false
    private var started = false
    private var playbackTask: Task<Void, Never>?
    private var upNextTask: Task<Void, Never>?
    private var playbackGeneration = 0

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
        static let language = "preferredSubtitleLanguage"
        /// `true` once the user has explicitly chosen "Off"; suppresses auto-select.
        static let off = "subtitlesOff"
    }

    /// `@AppStorage`-style key for the persisted audio-language preference (#3). Mirrors
    /// `SubtitlePrefKey`, but there is no "Off" — a video always plays some soundtrack.
    private enum AudioPrefKey {
        /// BCP-47 / ISO language code of the user's last chosen audio track (e.g. "en").
        static let language = "preferredAudioLanguage"
    }

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

    /// Whether we've already spent our single automatic retry on a transient start.m3u8
    /// failure (P3 #8). A manual `retry()` from the UI resets this.
    private var didAutoRetry = false

    /// Whether this session is streaming (vs local file). Drives which menus the
    /// player surface offers (quality reload only makes sense for streaming).
    var isStreaming: Bool { localFile == nil && server != nil && token != nil }

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
         mediaIndex: Int = 0,
         machineIdentifier: String? = nil,
         initialResumeMsOverride: Int? = nil) {
        self.item = item
        self.server = server
        self.token = token
        self.identity = identity
        self.client = client
        self.localFile = nil
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
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
        // Offline playback has no server session to build a play queue against.
        self.machineIdentifier = nil
        // Local files resume from the item's saved offset; no rebuild override.
        self.initialResumeMsOverride = nil
        self.chapters = item.chapters ?? []
        self.speedState.speed = self.playbackSpeed
    }

    // MARK: - Lifecycle

    /// Begin playback. Safe to call once; subsequent calls are ignored.
    func start() {
        guard !started else { return }
        started = true
        if let localFile {
            loadLocalFile(localFile)
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
        playbackTask?.cancel()
        playbackTask = nil
        upNextTask?.cancel()
        upNextTask = nil
        playbackGeneration += 1
        timeline.report(state: .stopped, force: true)
        sendTranscodeStop()
        player.pause()
        removeObservers()
        // Tear down the session/lifecycle observers (kept separate from the per-item
        // observers above) and release the audio session, notifying other apps so they can
        // resume (#17).
        audioSession.removeObservers()
        audioSession.deactivate()
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
        guard wantsOff || (savedLang?.isEmpty == false) else { return }

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

    /// After a successful `selectAudioStream` PUT, the locally-known active stream id.
    /// The `item` snapshot's `selected` flags are stale from that point on, so the loader
    /// prefers this override when rebuilding the checkmarked list.
    private var audioStreamIDOverride: Int?

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
        guard isStreaming, let server, let token, let part = streamingPart else { return }
        guard !choice.isSelected else { return }
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
        audioStreamIDOverride = choice.id
        if let lang = part.audioStreams.first(where: { $0.id == choice.id })?.languageTag,
           !lang.isEmpty {
            UserDefaults.standard.set(lang, forKey: AudioPrefKey.language)
        }
        // Restart the transcode where the viewer is — mirror `reload(bitrateKbps:)`.
        let resumeMs = currentResumeMs
        didAutoRetry = false
        removeObservers()
        beginStreaming(resumeOffsetMsOverride: resumeMs)
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
        if player.timeControlStatus != .paused {
            player.rate = speed
        }
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
        // A reload is a fresh session: restore the auto-retry budget and the seek-restart
        // burst budget (#27) — explicit user intent re-earns self-healing. (didScrobble is
        // intentionally NOT reset — the same content shouldn't re-scrobble mid-watch.)
        didAutoRetry = false
        seekRestartBudget.reset()
        removeObservers()
        beginStreaming(resumeOffsetMsOverride: resumeMs)
    }

    // MARK: - Failure / retry

    /// User-initiated retry after a surfaced playback failure (P3 #8). Re-runs the
    /// streaming start path from the last known playhead so a transient bad start.m3u8
    /// (or a recovered network blip) gets a fresh session rather than a permanent black
    /// screen. Resets the auto-retry budget so a subsequent transient failure can still
    /// self-heal. No-op for local-file sessions (nothing to re-fetch).
    func retry() {
        guard isStreaming else { return }
        let resumeMs = currentResumeMs
        didAutoRetry = false
        // Explicit user intent re-earns the seek-restart burst budget (#27).
        seekRestartBudget.reset()
        playbackError.clear()
        removeObservers()
        beginStreaming(resumeOffsetMsOverride: resumeMs)
    }

    /// `stoppingPreviousTranscode` is true on every in-place RESTART (quality/audio reload,
    /// retry, auto-retry, seek-restart) and false only on the initial start: a restart reuses
    /// `sessionID`, and PMS proved unreliable at reaping the superseded job on its own — a
    /// live pile-up of software transcoders OOM-killed the server pod (8Gi cgroup) during the
    /// #25 stall testing. Explicitly stop the old job first (see `stopPreviousTranscode`).
    private func beginStreaming(resumeOffsetMsOverride: Int? = nil,
                                stoppingPreviousTranscode: Bool = true) {
        playbackTask?.cancel()
        playbackGeneration += 1
        let generation = playbackGeneration
        playbackTask = Task { [weak self] in
            guard let self else { return }
            await self.startStreaming(resumeOffsetMsOverride: resumeOffsetMsOverride,
                                      stoppingPreviousTranscode: stoppingPreviousTranscode,
                                      generation: generation)
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
            NSLog("[VP] transcode: stopping previous job for session before restart")
            await stopPreviousTranscode(server: server, token: token)
            guard !Task.isCancelled, generation == playbackGeneration else { return }
        }
        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"

        // 0 (Maximum/Original) maps to a very high ceiling so PMS still emits a
        // playable HLS rendition rather than rejecting an absent cap.
        let requestedCap = maxVideoBitrateKbps <= 0 ? 200_000 : maxVideoBitrateKbps

        // Resume position. Tell PMS to PRIME the transcode here (seconds) so it emits
        // `#EXT-X-START:TIME-OFFSET` and the first segment at the playhead is produced
        // immediately. Without this PMS transcodes from 0 and a deep client seek stalls
        // waiting on a segment the transcoder hasn't reached yet.
        let resumeMs = resumeOffsetMsOverride ?? item.viewOffset
        let offsetSeconds: Int? = if let resumeMs, resumeMs > 0 { resumeMs / 1000 } else { nil }

        let transcode = TranscodeRequest(server: server,
                                         token: token,
                                         identity: identity,
                                         metadataKey: metadataKey,
                                         maxVideoBitrateKbps: requestedCap,
                                         sessionID: sessionID,
                                         mediaIndex: mediaIndex,
                                         partIndex: 0,
                                         startOffsetSeconds: offsetSeconds)

        // Direct Stream opt-in (#7 Step 3, default OFF): probe the MDE FIRST with
        // directPlay=1 + the direct-play-capable profile. Commit to the matching
        // direct-play start.m3u8 ONLY when PMS confirms it will copy the video stream
        // (`savesVideoEncode`) — the expensive software re-encode is saved and the server
        // load drops to a remux. Any other answer, a failed probe, or the toggle being
        // off falls through to today's exact transcode path, byte-identical.
        var decision: DecisionResponse?
        var streamURL = transcode.startM3U8URL()
        if UserDefaults.standard.bool(forKey: Self.directStreamEnabledKey) {
            do {
                let probeReq = PlexRequest(url: transcode.directPlayProbeDecisionURL(), method: "GET")
                let probe = try await client.send(probeReq, as: DecisionResponse.self)
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                // #7 instrumentation (strip after live verification): the probe's verdict is
                // the whole experiment — log every field the rollout plan wants eyeballed.
                let probeMsg = String(format: "[VP] decision: probe general=%d video=%@ audio=%@ mde=%@",
                                      probe.generalDecisionCode ?? -1,
                                      probe.videoDecision ?? "nil",
                                      probe.audioDecision ?? "nil",
                                      probe.mdeDecisionText ?? "nil")
                NSLog("%@", probeMsg)
                if probe.savesVideoEncode {
                    NSLog("[VP] decision: PMS will copy video — committing direct-play start.m3u8")
                    decision = probe
                    streamURL = transcode.directPlayStartM3U8URL()
                }
            } catch {
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                NSLog("PlaybackController: direct-play probe failed (%@); using transcode path", String(describing: error))
            }
        }

        // Ask PMS for a transcode decision (skipped when the probe above already committed —
        // its decision/start pair must stay consistent, research/15 risk #8). We proceed for
        // both directPlay and transcode; only a hard `.unsupported` aborts. A failed decision
        // call is non-fatal — fall through and try start.m3u8 anyway.
        if decision == nil {
            do {
                let decisionReq = PlexRequest(url: transcode.decisionURL(), method: "GET")
                let response = try await client.send(decisionReq, as: DecisionResponse.self)
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                decision = response
                if case .unsupported = response.decision {
                    // Best-effort: still attempt playback; PMS often plays despite an
                    // odd decision code. Logged for the integration pass.
                    NSLog("PlaybackController: transcode decision unsupported: %@", String(describing: response.generalDecisionText))
                }
            } catch {
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                NSLog("PlaybackController: decision call failed (%@); attempting start.m3u8 anyway", String(describing: error))
            }
        }

        // Seed the Stats-for-Nerds static facts (no token is ever read here).
        diagnostics.applyStatic(item: item,
                                mediaIndex: mediaIndex,
                                decision: decision,
                                server: server,
                                targetBitrateKbps: maxVideoBitrateKbps)

        // #4 probe (since removed) answered NO: this PMS's master playlist carries
        // only EXT-X-STREAM-INF — no I-frame variant, so AVKit gets no free scrub
        // thumbnails here. Recorded on the issue; a custom BIF scrubber is the only
        // remaining route and is parked.
        let asset = AVURLAsset(url: streamURL)
        let playerItem = AVPlayerItem(asset: asset)
        // Offset priming (the `offset` param + `#EXT-X-START`) is the FAST path: PMS
        // positions the session so AVPlayer begins at the resume point with a primed
        // segment, avoiding a cold deep-seek stall. But we now also pass `resumeMs`
        // through as a CLIENT-SIDE FALLBACK (P2 #9): if the player still lands at ~0
        // (PMS didn't honor `#EXT-X-START`), the status observer seeks once we're ready.
        // Previously this was `nil`, so a non-honoring PMS dropped the playhead to 0.
        guard !Task.isCancelled, generation == playbackGeneration else { return }
        load(playerItem, resumeOffsetMs: resumeMs)
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
        var comps = URLComponents(url: server.appendingPathComponent("/photo/:/transcode"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            .init(name: "url", value: imagePath),
            .init(name: "width", value: "600"),
            .init(name: "height", value: "900"),
            .init(name: "minSize", value: "1"),
            .init(name: "upscale", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ]
        return comps?.url
    }

    /// Builds a `/photo/:/transcode` URL for a chapter thumbnail key, sized 16:9
    /// landscape. Returns nil when offline (no server/token) or the key is empty.
    ///
    /// The Chapters info-tab rail can't use `PosterImage` (which reads `AppModel`
    /// from the SwiftUI environment): AVKit hosts each info tab in its own
    /// `UIHostingController`, outside that environment. The controller already
    /// holds the server + token, so it vends the URL directly instead.
    func chapterThumbnailURL(for imagePath: String?) -> URL? {
        guard let imagePath, !imagePath.isEmpty, let server, let token else { return nil }
        var comps = URLComponents(url: server.appendingPathComponent("/photo/:/transcode"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            .init(name: "url", value: imagePath),
            .init(name: "width", value: "480"),
            .init(name: "height", value: "270"),
            .init(name: "minSize", value: "1"),
            .init(name: "upscale", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ]
        return comps?.url
    }

    // MARK: - Shared load + observers

    private func load(_ playerItem: AVPlayerItem, resumeOffsetMs: Int?) {
        // Reset per-item state for the new player item: a fresh load is a fresh resume
        // (didSeek), a fresh readiness gate, and a clean error surface (P2/P3/P8).
        didSeek = false
        hasPlayedThisItem = false
        timeline.isReadyForReporting = false
        didApplySavedSubtitle = false
        didApplyAudioPreference = false
        pendingResumeMs = resumeOffsetMs
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
        // Forward-buffer tuning (#21). Ask AVPlayer to keep ~30s of media buffered AHEAD of
        // the playhead. Default (0) lets AVPlayer pick automatically, which on a capped HLS
        // transcode can run lean and rebuffer on a network blip. A modest explicit buffer
        // smooths over those blips. We deliberately do NOT over-buffer: too large a window
        // wastes the PMS transcoder's lead segments and grows memory, and on a live transcode
        // AVPlayer can only buffer as fast as the transcoder produces anyway — ~30s is a
        // balance. Applied uniformly (streaming + local): a local file fills it instantly so
        // it's harmless there, and keeping one code path is simpler. `automaticallyWaitsTo-
        // MinimizeStalling` stays at its default `true` (set below) so the player still waits
        // for enough buffer before starting rather than starting and immediately stalling.
        playerItem.preferredForwardBufferDuration = 30
        player.automaticallyWaitsToMinimizeStalling = true
        // Populate Now Playing / cinema-chrome metadata (title + summary now, artwork async).
        // Done for both streaming and local-file paths so the player shows the real title.
        attachExternalMetadata(to: playerItem)
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
        // Observe item status for its WHOLE lifetime (P4 #8): handle both the resume
        // seek on `.readyToPlay` AND a later `.failed`. The old code self-nilled this
        // observation inside the readyToPlay branch, so a subsequent ready→failed
        // transition (e.g. transcode dies mid-stream) was never seen.
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] pItem, _ in
            guard let self else { return }
            Task { @MainActor in
                switch pItem.status {
                case .readyToPlay:
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
                    self.applyPlaybackSpeed()
                    // Resume seek, exactly once (didSeek). Offset priming is the fast
                    // path; this is the CLIENT-SIDE FALLBACK (P2 #9): if PMS didn't honor
                    // `#EXT-X-START` and we're sitting at ~0 while a resume was requested,
                    // seek there ourselves.
                    if !self.didSeek, let resumeOffsetMs, resumeOffsetMs > 0 {
                        let current = self.player.currentTime().seconds
                        let nearZero = !current.isFinite || current < 1.0
                        if nearZero {
                            let target = CMTime(value: CMTimeValue(resumeOffsetMs), timescale: 1000)
                            self.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
                        }
                        self.didSeek = true
                    }
                case .failed:
                    self.handlePlaybackFailure(pItem.error)
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
                self.handlePlaybackFailure(error)
            }
        }

        // Seek-during-stall recovery (#25): while the transcoder is stalled the scrubber is
        // effectively pinned — even when AVPlayer accepts the drag, PMS only produces segments
        // forward from the session's current point, so a seek elsewhere sits starved forever
        // (seen live: stuck at 14:12, dragging to 26:56 doesn't take). `timeJumpedNotification`
        // is the only in-process signal of a user seek on visionOS (the AVKit user-navigation
        // delegate callbacks are `API_UNAVAILABLE(visionos)`); on each jump we arm a short
        // confirmation window and, if the player is still starved at the new position when it
        // elapses, restart the transcode at that offset — the same in-place rebuild mechanics
        // as the Quality reload / `selectAudioStream` (PMS replaces the same-session job, no
        // explicit stop needed).
        timeJumpedObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTimeJump()
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
            Task { @MainActor in
                let paused = avPlayer.timeControlStatus == .paused
                self.timeline.report(state: paused ? .paused : .playing, force: true)
                self.transport.set(paused: paused)
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
                let isStalled = (status == .waitingToPlayAtSpecifiedRate)
                self.buffering.set(isStalled)
                // Stall watchdog (#8 hardening): a network-loss stall often never flips
                // item.status to .failed, so arm a timeout while the player is starved and
                // cancel it the instant playback genuinely resumes. We deliberately do NOT
                // cancel on `.paused` — handleStallTimeout's buffer-empty check distinguishes a
                // dead stall from a user pause on already-buffered content.
                if isStalled {
                    self.armStallWatchdog()
                } else if status == .playing {
                    self.cancelStallWatchdog()
                    // The item has genuinely played: from here on, a time jump that strands the
                    // player starved is a dead seek (#25), not a slow initial prime.
                    self.hasPlayedThisItem = true
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
                self.timeline.report(state: .stopped, force: true)
                self.timeline.scrobble()
                // Play-to-end with a resolved, un-cancelled next item: autoplay it (#15).
                // `advanceToNextItem` re-flushes timeline/scrobble idempotently.
                if self.upNext.nextItem != nil, !self.upNext.isCancelled {
                    self.advanceToNextItem()
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
        // Cancel the stall watchdog so a stale timer can't fire across a reload / auto-retry /
        // teardown and surface an error against a freshly-loaded item.
        cancelStallWatchdog()
        if let timeJumpedObserver {
            NotificationCenter.default.removeObserver(timeJumpedObserver)
            self.timeJumpedObserver = nil
        }
        // Cancel a pending seek-stall confirmation so it can't fire across a reload/teardown
        // and restart a freshly-loaded session at a stale offset (#25).
        seekRestartTimer?.invalidate()
        seekRestartTimer = nil
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
            skipMarker.set(kind: match.kind, seekTargetSeconds: match.endSeconds)
        } else if skipMarker.active != nil {
            skipMarker.clear()
        }
    }

    /// Seek the player to the active marker's end and dismiss the Skip button. Uses
    /// zero tolerance so we land precisely past the intro/credits boundary. No-op when no
    /// marker is currently active.
    func skipCurrentMarker() {
        guard let active = skipMarker.active else { return }
        let target = CMTime(seconds: active.seekTargetSeconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        skipMarker.clear()
    }

    // MARK: - Up Next (#15)

    /// Seconds-before-end at which the Up Next card appears when the item carries no
    /// credits marker. (When a credits marker IS present, its start is used instead.)
    private let upNextTailSeconds: Double = 30

    /// Countdown (seconds) shown on the Up Next card before it autoplays the next item.
    private let upNextCountdownStart = 10

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
        guard upNext.nextItem != nil, !upNext.isCancelled else { return }
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
            upNext.show(countdown: upNextCountdownStart)
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

    /// Surface a playback failure to the UI and, for a transient start.m3u8 failure,
    /// spend ONE automatic retry before giving up (P3 #8). A bad/expired start.m3u8 used
    /// to leave a permanent black screen with nothing surfaced; now the UI can show an
    /// error + Retry (driven by `playbackError`).
    private func handlePlaybackFailure(_ error: Error?) {
        // Ignore stale callbacks once an error is already being shown for this item.
        guard !playbackError.isFailed else { return }

        // One silent auto-retry for streaming: transcode sessions sometimes hand back a
        // not-yet-ready / briefly-stale start.m3u8 on the first hit. (Don't log tokens or
        // raw %-bearing strings — use the %@ form.)
        if isStreaming && !didAutoRetry {
            didAutoRetry = true
            NSLog("PlaybackController: playback failed (%@); auto-retrying start.m3u8",
                  String(describing: error))
            let resumeMs = currentResumeMs
            removeObservers()
            beginStreaming(resumeOffsetMsOverride: resumeMs)
            return
        }

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
        player.pause()
        playbackError.set(error)
    }

    // MARK: - Stall watchdog (#8 hardening)

    /// How long (seconds) a continuous stall may last before we treat it as a failure. Generous
    /// enough not to trip a slow-but-working initial prime, short enough to replace AVKit's dead
    /// placeholder glyph with a recoverable Retry promptly.
    private let stallTimeoutSeconds: TimeInterval = 15

    /// Arm the stall watchdog if it isn't already running and no error is being shown. Idempotent
    /// so repeated `.waitingToPlayAtSpecifiedRate` callbacks don't reset the countdown.
    private func armStallWatchdog() {
        guard stallWatchdog == nil, !playbackError.isFailed else { return }
        // #25 instrumentation: snapshot the seekable ranges at stall onset. If they collapse
        // during a stall, that's the suspected mechanic behind the pinned system scrubber
        // (AVKit clamps drags to the seekable span). Strip after live verification.
        let stallMsg = String(format: "[VP] seek: stall began at %.1fs (seekable=%@)",
                              player.currentTime().seconds, seekableRangesDescription())
        NSLog("%@", stallMsg)
        let timer = Timer(timeInterval: stallTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleStallTimeout()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallWatchdog = timer
    }

    /// Cancel the stall watchdog (genuine resume, teardown, or retry).
    private func cancelStallWatchdog() {
        stallWatchdog?.invalidate()
        stallWatchdog = nil
    }

    /// Fired when a stall outlasts `stallTimeoutSeconds`. Confirm the player is genuinely starved
    /// (empty buffer AND not likely to keep up) rather than, e.g., paused on already-buffered
    /// content — so we never flash an error over a normal user pause — then surface the failure.
    /// We surface DIRECTLY (no silent auto-retry): the watchdog already gave the stream 15s to
    /// recover, and over a dead network a retry would just stall again. The overlay's Retry
    /// rebuilds the session once the user's connection is back.
    private func handleStallTimeout() {
        cancelStallWatchdog()
        guard !playbackError.isFailed, let current = player.currentItem else { return }
        guard current.isPlaybackBufferEmpty, !current.isPlaybackLikelyToKeepUp else { return }
        if let underlying = current.error {
            NSLog("PlaybackController: stream stalled, surfacing failure (%@)",
                  String(describing: underlying))
            surfaceFailure(underlying)
        } else {
            NSLog("PlaybackController: stream stalled with no item error; surfacing generic failure")
            surfaceFailure(NSError(
                domain: "PlexAVPApp.Playback", code: -1001,
                userInfo: [NSLocalizedDescriptionKey:
                    "Playback stalled. The server or network may be unreachable. Tap Retry once your connection is back."]))
        }
    }

    // MARK: - Seek-during-stall recovery (#25)

    /// How long after a time jump we wait before checking whether the player is starved at the
    /// new position. Long enough that a seek into already-buffered/produced content starts
    /// playing (or at least reports likely-to-keep-up) and is left alone; short enough that a
    /// dead seek recovers promptly instead of pinning the scrubber. Repeat jumps re-arm the
    /// window, so a user scrubbing around coalesces onto their final target.
    private let seekStallConfirmSeconds: TimeInterval = 2.0

    /// Rate-limit policy for seek-triggered transcode restarts (#27): 5s cooldown between
    /// restarts, escalate to the failure overlay past 3 restarts in a rolling 60s window.
    /// The cooldown alone still allows 12 restarts/min indefinitely, and the
    /// play→starve→restart cycle can self-sustain with NO user input (HLS discontinuities fire
    /// `timeJumpedNotification` too) — a budget is what turns "runaway" into "ask the viewer."
    /// Policy + rationale live in `SeekRestartBudget` (PMSKit), where the spam scenarios are
    /// unit-tested; reset on user-intent rebuilds (`retry()` / `reload(bitrateKbps:)`).
    private var seekRestartBudget = SeekRestartBudget(
        cooldownSeconds: 5.0, burstLimit: 3, burstWindowSeconds: 60)

    /// Handle a playhead jump (seek) on the current item. Streaming only: a seek into territory
    /// the transcoder hasn't produced can never make progress on its own — PMS only transcodes
    /// forward from the session's offset, so the player sits starved at the target forever and
    /// the scrubber reads as pinned (#25, seen live while stalled mid-buffer). Arm the
    /// confirmation window; `confirmSeekStallRestart` does the actual starvation check.
    ///
    /// Deliberately fires for OUR programmatic seeks too (chapter jump, Skip Intro/Credits):
    /// they share the same failure mode when they land beyond the transcoder's progress.
    private func handleTimeJump() {
        guard isStreaming, !playbackError.isFailed else { return }
        // Ignore jumps before this item first plays — see `hasPlayedThisItem`. This also
        // prevents a restart loop: a restarted session re-primes (starved for a while) and
        // must not re-trigger off its own positioning jumps.
        guard hasPlayedThisItem else { return }

        // #25 instrumentation (strip after live verification): record every jump with the
        // player state so the live test shows whether stalled drags reach the app at all —
        // if AVKit swallows the drag entirely, no line appears and the fix can't engage.
        let item = player.currentItem
        let jumpMsg = String(format: "[VP] seek: time jumped to %.1fs (status=%d bufferEmpty=%d keepUp=%d seekable=%@)",
                             player.currentTime().seconds,
                             player.timeControlStatus.rawValue,
                             (item?.isPlaybackBufferEmpty ?? false) ? 1 : 0,
                             (item?.isPlaybackLikelyToKeepUp ?? false) ? 1 : 0,
                             seekableRangesDescription())
        NSLog("%@", jumpMsg)

        seekRestartTimer?.invalidate()
        let timer = Timer(timeInterval: seekStallConfirmSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.confirmSeekStallRestart()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        seekRestartTimer = timer
    }

    /// Fired `seekStallConfirmSeconds` after the most recent jump. If the player is genuinely
    /// starved at the jumped-to position (waiting on data with an empty buffer it can't
    /// refill), the current transcode session will never deliver — restart the transcode at
    /// that offset (in-place `beginStreaming`, mirroring `reload(bitrateKbps:)`; this is a
    /// stall, not a surfaced failure, so no AVKit wedge and no `.id()` view rebuild needed).
    /// A jump that recovered on its own — buffered content, or the transcoder caught up — is
    /// a logged no-op. (A paused player with a HEALTHY buffer is also left alone; only
    /// paused-AND-starved restarts, see the buffer-flags note below.)
    private func confirmSeekStallRestart() {
        seekRestartTimer?.invalidate()
        seekRestartTimer = nil
        guard isStreaming, !playbackError.isFailed, let current = player.currentItem else { return }
        // Starvation is judged by the BUFFER FLAGS, not `timeControlStatus`: AVKit leaves the
        // player `.paused` (not `.waitingToPlayAtSpecifiedRate`) after an interactive scrub
        // that lands starved — proven live, status=0 bufferEmpty=1 in the #25 logs — and a
        // paused-but-starved session can never refill at the target either. Only an actively
        // `.playing` player is left alone.
        guard player.timeControlStatus != .playing,
              current.isPlaybackBufferEmpty,
              !current.isPlaybackLikelyToKeepUp else {
            let okMsg = String(format: "[VP] seek: jump recovered without restart (status=%d bufferEmpty=%d keepUp=%d)",
                               player.timeControlStatus.rawValue,
                               current.isPlaybackBufferEmpty ? 1 : 0,
                               current.isPlaybackLikelyToKeepUp ? 1 : 0)
            NSLog("%@", okMsg)
            return
        }
        // Rate-limit (#27): policy lives in SeekRestartBudget (PMSKit, unit-tested).
        // Deferred → re-arm the confirmation for the cooldown remainder instead of restarting
        // now; the user's latest target isn't lost — when the re-armed check fires,
        // `currentResumeMs` reads the live playhead. Escalate → restarts clustering inside
        // the window mean the stream can't sustain playback; stop silently rebuilding and
        // put the viewer in charge (Retry / quality reload reset the budget).
        switch seekRestartBudget.requestRestart(now: ProcessInfo.processInfo.systemUptime) {
        case .deferred(let remaining):
            NSLog("%@", String(format: "[VP] seek: starved but in restart cooldown; re-arming in %.1fs", remaining))
            let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.confirmSeekStallRestart()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            seekRestartTimer = timer
            return
        case .escalate(let recentCount):
            NSLog("%@", String(format: "[VP] seek: %d restarts within 60s — escalating to failure overlay", recentCount))
            surfaceFailure(NSError(
                domain: "PlexAVPApp.Playback", code: -1002,
                userInfo: [NSLocalizedDescriptionKey:
                    "Playback keeps falling behind the server. Tap Retry to rebuild the stream, or lower the quality setting."]))
            return
        case .allow:
            break
        }
        // `currentResumeMs` reads the live playhead, which after the seek IS the user's target.
        let resumeMs = currentResumeMs
        let restartMsg = String(format: "[VP] seek: starved %.0fs after jump; restarting transcode at %dms",
                                seekStallConfirmSeconds, resumeMs)
        NSLog("%@", restartMsg)
        // Restart the transcode where the viewer wants to be — mirror `reload(bitrateKbps:)`,
        // but deliberately do NOT reset `didAutoRetry`: a seek restart is not user intent, and
        // refilling the silent auto-retry budget here would let a flapping stream rebuild
        // forever without ever surfacing (#27).
        removeObservers()
        beginStreaming(resumeOffsetMsOverride: resumeMs)
    }

    /// Compact "start-end,start-end" (seconds) rendering of the current item's seekable ranges
    /// for the #25 instrumentation; "EMPTY" when they collapsed (the suspected pin mechanic).
    private func seekableRangesDescription() -> String {
        guard let current = player.currentItem else { return "no-item" }
        let ranges = current.seekableTimeRanges.map(\.timeRangeValue)
        guard !ranges.isEmpty else { return "EMPTY" }
        return ranges.map { range in
            String(format: "%.1f-%.1f", range.start.seconds, range.end.seconds)
        }.joined(separator: ",")
    }
}

/// Observable failure surface for a `PlaybackController`. Modeled as its own object
/// (mirroring `PlaybackDiagnostics`) so PlayerView/DetailView can react to a failure and
/// show an error + Retry without the whole controller needing to be `@Observable`.
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

    /// Set the paused flag. Idempotent so duplicate KVO callbacks don't churn the observable.
    func set(paused: Bool) {
        if isPaused != paused { isPaused = paused }
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
