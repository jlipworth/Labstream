import Foundation
import AVKit
import AVFAudio
import UIKit
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
    private var lastTimelineState: TimelineRequest.State?
    private var lastReportedSecond: Int = -1
    private var didScrobble = false
    private var started = false

    // MARK: - Audio-session / interruption / background state (#17)

    /// NotificationCenter tokens for the audio-session interruption + route-change
    /// observers and the app-lifecycle (background) observers. Registered once in
    /// `installSessionObservers()` and torn down in `removeSessionObservers()`. Kept
    /// separate from the per-item observers (which are re-registered on a Quality reload)
    /// so audio-session/lifecycle handling survives an item swap and is never doubly
    /// registered.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var didEnterBackgroundObserver: NSObjectProtocol?

    /// True when we paused playback ourselves (audio interruption, route change, or app
    /// backgrounding) WHILE the user had it playing. Gates auto-resume after an
    /// interruption: we only resume something WE paused, never something the user paused
    /// manually. Resume after backgrounding is intentionally NOT automatic — this flag is
    /// only consulted by the interruption `.ended`/`.shouldResume` path.
    private var wasPlayingBeforeInterruption = false

    /// One-shot guard for the resume seek. Replaces the old "self-nil the observation
    /// inside its own callback" pattern (P4 #8): nilling the observation there meant a
    /// later `unknown → ready → failed` transition was never seen. We now keep the
    /// status observation alive for the item's lifetime and gate the resume seek on this
    /// flag instead, so `.failed` is still observed after `.readyToPlay`.
    private var didSeek = false

    /// True once the current item has reached `.readyToPlay` with a real duration. Used
    /// to suppress timeline/scrobble heartbeats during readyToPlay churn (P8 #11): a
    /// `duration=0` / `time≈0` heartbeat confuses PMS Continue Watching.
    private var isReadyForReporting = false

    /// One-shot guard so the saved-subtitle-language auto-select runs once per item. Reset
    /// in `load(_:)` alongside the other per-item flags so a Quality reload (which swaps the
    /// `AVPlayerItem`) re-applies the preference to the new legible group.
    private var didApplySavedSubtitle = false

    /// `@AppStorage` keys for the persisted subtitle preference. Mirrors `PlayerView`'s
    /// `maxVideoBitrateKbps` pattern (UserDefaults-backed) so the controller — which can't be
    /// a SwiftUI view — and any future settings UI share one source of truth.
    private enum SubtitlePrefKey {
        /// BCP-47 / ISO language code of the user's last chosen subtitle track (e.g. "en").
        static let language = "preferredSubtitleLanguage"
        /// `true` once the user has explicitly chosen "Off"; suppresses auto-select.
        static let off = "subtitlesOff"
    }

    /// Resume target (ms) for the current item, retained so the status observer can do a
    /// client-side seek fallback if PMS's `#EXT-X-START` priming didn't land (P2 #9).
    private var pendingResumeMs: Int?

    /// Whether we've already spent our single automatic retry on a transient start.m3u8
    /// failure (P3 #8). A manual `retry()` from the UI resets this.
    private var didAutoRetry = false

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

    /// Skippable intro/credits ranges derived from the item's Plex markers (#14), in
    /// SECONDS. Built once from `item.markers` (markers don't change across a Quality
    /// reload of the same item, so this is derived from the constant `item`). Commercial
    /// and `.other` markers are intentionally excluded — only intro/credits get a Skip
    /// button. `endSeconds` is the seek target when the user taps Skip.
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
         machineIdentifier: String? = nil) {
        self.item = item
        self.server = server
        self.token = token
        self.identity = identity
        self.client = client
        self.localFile = nil
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.mediaIndex = mediaIndex
        self.machineIdentifier = machineIdentifier
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
            Task { await self.startStreaming() }
        }
        // Resolve the next episode in the background (#15). Network-bound and entirely
        // best-effort: if it fails or there is no next item, the Up Next card simply never
        // appears. Only meaningful for episodes; the resolver returns early otherwise.
        Task { await self.resolveNextItem() }
    }

    /// Tear down observers and report a final `stopped` timeline. Call from the
    /// view's `dismantle`.
    func stop() {
        reportTimeline(state: .stopped, force: true)
        player.pause()
        removeObservers()
        // Tear down the session/lifecycle observers (kept separate from the per-item
        // observers above) and release the audio session, notifying other apps so they can
        // resume (#17).
        removeSessionObservers()
        deactivateAudioSession()
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
        // A reload is a fresh session: restore the auto-retry budget. (didScrobble is
        // intentionally NOT reset — the same content shouldn't re-scrobble mid-watch.)
        didAutoRetry = false
        removeObservers()
        Task { await self.startStreaming(resumeOffsetMsOverride: resumeMs) }
    }

    // MARK: - Failure / retry

    /// User-initiated retry after a surfaced playback failure (P3 #8). Re-runs the
    /// streaming start path from the last known playhead so a transient bad start.m3u8
    /// (or a recovered network blip) gets a fresh session rather than a permanent black
    /// screen. Resets the auto-retry budget so a subsequent transient failure can still
    /// self-heal. No-op for local-file sessions (nothing to re-fetch).
    func retry() {
        guard isStreaming else { return }
        let resumeMs = pendingResumeMs ?? item.viewOffset
        didAutoRetry = false
        playbackError.clear()
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
        // Offset priming (the `offset` param + `#EXT-X-START`) is the FAST path: PMS
        // positions the session so AVPlayer begins at the resume point with a primed
        // segment, avoiding a cold deep-seek stall. But we now also pass `resumeMs`
        // through as a CLIENT-SIDE FALLBACK (P2 #9): if the player still lands at ~0
        // (PMS didn't honor `#EXT-X-START`), the status observer seeks once we're ready.
        // Previously this was `nil`, so a non-honoring PMS dropped the playhead to 0.
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

        // `MediaItem` carries no grandparent/parent (show/episode) fields, so the best
        // available secondary context is the release year. Only added when present.
        if let year = item.year {
            items.append(Self.metadataItem(identifier: .iTunesMetadataReleaseDate,
                                           value: String(year)))
        }
        if let summary = item.summary, !summary.isEmpty {
            items.append(Self.metadataItem(identifier: .commonIdentifierDescription,
                                           value: summary))
        }
        return items
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

    // MARK: - Shared load + observers

    private func load(_ playerItem: AVPlayerItem, resumeOffsetMs: Int?) {
        // Reset per-item state for the new player item: a fresh load is a fresh resume
        // (didSeek), a fresh readiness gate, and a clean error surface (P2/P3/P8).
        didSeek = false
        isReadyForReporting = false
        didApplySavedSubtitle = false
        pendingResumeMs = resumeOffsetMs
        playbackError.clear()
        // Clear any active Skip affordance for the (re)loaded item. The skip RANGES are
        // unchanged across a Quality reload (same `item`), so we only reset the live UI
        // state here; the new fine-grained observer will re-derive the active marker.
        skipMarker.clear()
        // Configure + activate the shared audio session before the item starts (#17), and
        // register the interruption / route-change / background observers once. Both are
        // idempotent across a Quality reload (which re-enters here): the session is already
        // active and `installSessionObservers()` no-ops on its second call.
        configureAudioSession()
        installSessionObservers()
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
                        self.isReadyForReporting = true
                    }
                    // Reapply the user's saved subtitle-language preference to this item's
                    // legible group (once per item; gated inside). Runs on each fresh item —
                    // including after a Quality reload swaps the AVPlayerItem.
                    await self.applySavedSubtitlePreferenceIfNeeded()
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

        // Periodic heartbeat ~ every 10s.
        let interval = CMTime(seconds: timelineIntervalSeconds, preferredTimescale: 1)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self else { return }
            let state: TimelineRequest.State = self.player.timeControlStatus == .paused ? .paused : .playing
            self.reportTimeline(state: state, force: false)
            // Progress-based scrobble (P9 #11): capped-HLS viewers often stop short of
            // EOF, so didPlayToEnd never fires and the item stays "unwatched." Mark it
            // watched once we cross ~90%. `sendScrobble()` is idempotent (didScrobble),
            // and didPlayToEnd remains the backstop for the final stretch.
            self.scrobbleIfNearEnd()
        }

        // Marker detection (#14): a finer ~0.5s observer that toggles the Skip
        // Intro/Skip Credits button as the playhead enters/leaves an intro/credits range.
        // Separate from the 10s heartbeat above, which is too coarse for a live button.
        let markerInterval = CMTime(seconds: 0.5, preferredTimescale: 600)
        markerTimeObserver = player.addPeriodicTimeObserver(forInterval: markerInterval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.updateSkipMarker(at: time.seconds)
            // Drive the Up Next card (#15) off the same fine-grained observer.
            self.updateUpNext(at: time.seconds)
        }

        // Fire on play/pause transitions.
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            guard let self else { return }
            Task { @MainActor in
                let state: TimelineRequest.State = avPlayer.timeControlStatus == .paused ? .paused : .playing
                self.reportTimeline(state: state, force: true)
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
                self.buffering.set(status == .waitingToPlayAtSpecifiedRate)
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

    // MARK: - Audio session / interruptions / background (#17)

    /// Configure and activate the shared `AVAudioSession` for video playback.
    ///
    /// Category `.playback` with mode `.moviePlayback` is the correct combination for a
    /// video player: it routes audio to the cinema/system output, plays through the silent
    /// switch (a movie's audio should not be muted by it), and is what AVKit expects for the
    /// docked/expanded screen. We activate once before the first item loads; subsequent
    /// (re)loads (e.g. a Quality reload) reuse the already-active session.
    ///
    /// Conservative by design: audio already worked without explicit config, so `.playback`
    /// must not regress that — it's the documented category for exactly this use and does not
    /// mute. Failures are logged (never fatal) so a session-config hiccup can't black-hole
    /// playback.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            NSLog("PlaybackController: AVAudioSession configuration failed (%@)",
                  String(describing: error))
        }
    }

    /// Deactivate the shared audio session on teardown, notifying other audio apps so they
    /// can resume. Best-effort: a failure here is logged, never fatal. Notifying on
    /// deactivation is the recommended behavior so we don't leave the session pinned for a
    /// subsequent player or another app.
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            NSLog("PlaybackController: AVAudioSession deactivation failed (%@)",
                  String(describing: error))
        }
    }

    /// Register the audio-session (interruption / route-change) and app-lifecycle
    /// (background) observers exactly once for this controller's lifetime. Idempotent: a
    /// second call (or a Quality reload, which only touches the per-item observers) is a
    /// no-op, so we never double-register. All closures hop to the `@MainActor` before
    /// touching player/controller state, satisfying Swift 6 strict concurrency.
    private func installSessionObservers() {
        guard interruptionObserver == nil else { return }
        let center = NotificationCenter.default

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            // Extract the Sendable scalars (raw UInts) from the non-Sendable userInfo BEFORE
            // hopping actors, so nothing risks a data race crossing into the @MainActor task.
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        }

        // Background-aware playback (P5): on visionOS the immersive player loses the active
        // scene when the user leaves; video can't decode/render in the background and a live
        // transcode session would keep churning. Pause on resign-active / background. We do
        // NOT auto-resume on return — that's the user's choice.
        resignActiveObserver = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pauseForBackground()
            }
        }

        didEnterBackgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pauseForBackground()
            }
        }
    }

    /// Tear down the session/lifecycle observers. Called from `stop()` (and is safe to call
    /// more than once). Kept separate from `removeObservers()` so a Quality reload — which
    /// rebuilds only the per-item observers — never tears these down or re-registers them.
    private func removeSessionObservers() {
        let center = NotificationCenter.default
        if let interruptionObserver {
            center.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeChangeObserver {
            center.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
        if let resignActiveObserver {
            center.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        if let didEnterBackgroundObserver {
            center.removeObserver(didEnterBackgroundObserver)
            self.didEnterBackgroundObserver = nil
        }
    }

    /// Handle an `AVAudioSession.interruptionNotification`.
    ///
    /// `.began`: remember whether we were actively playing (so we don't later resume a
    /// user-paused stream) and pause. `.ended`: if the system says `.shouldResume` AND we
    /// were the ones who paused (the user hadn't manually paused before the interruption),
    /// resume — otherwise leave it paused and respect the user's intent.
    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            // Only flag for resume if playback was actually running; a paused player should
            // stay paused.
            wasPlayingBeforeInterruption = player.timeControlStatus != .paused
            if wasPlayingBeforeInterruption {
                player.pause()
            }
        case .ended:
            guard wasPlayingBeforeInterruption else { return }
            wasPlayingBeforeInterruption = false
            let options: AVAudioSession.InterruptionOptions =
                optionsRaw.map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if options.contains(.shouldResume) {
                // Re-activate the session (the interruption may have deactivated it) and
                // resume only because WE paused while the user had it playing.
                configureAudioSession()
                player.play()
            }
        @unknown default:
            break
        }
    }

    /// Handle an `AVAudioSession.routeChangeNotification`. On `.oldDeviceUnavailable`
    /// (headphones / AirPods unplugged or disconnected) pause, so audio doesn't suddenly
    /// blast out of the speakers — the standard system behavior. Other reasons are ignored.
    private func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        if reason == .oldDeviceUnavailable {
            player.pause()
        }
    }

    /// Pause video when the app is backgrounded / loses the foreground (P5). Video can't
    /// decode/render in the background and a live transcode would keep running, so we always
    /// pause. Tracks "was playing" using the SAME flag as interruptions so the two compose
    /// cleanly — but note we deliberately do NOT auto-resume on foreground: resume is the
    /// user's choice on return. The flag is set here mainly so a background event followed by
    /// an interruption-ended sequence doesn't resume a stream the user never intended to keep
    /// running; the foreground path simply leaves playback paused.
    func pauseForBackground() {
        if player.timeControlStatus != .paused {
            wasPlayingBeforeInterruption = true
            player.pause()
        }
    }

    // MARK: - Timeline / scrobble

    /// Send a timeline heartbeat. Skips when nothing meaningful changed (same state
    /// within the same ~10s second bucket) unless `force` is set.
    private func reportTimeline(state: TimelineRequest.State, force: Bool) {
        // Local-file playback has no server session to report to.
        guard let server, let token else { return }

        // Don't post heartbeats until the item is genuinely ready with a real duration
        // (P8 #11): a duration=0 / time≈0 heartbeat during readyToPlay churn confuses
        // PMS Continue Watching. The final `.stopped` is exempt so we always flush a true
        // offset when the user leaves (even if we never reached the readiness gate).
        if !isReadyForReporting && state != .stopped { return }

        let durationMs = item.duration
            ?? Int((player.currentItem?.duration.seconds ?? 0).isFinite ? (player.currentItem?.duration.seconds ?? 0) * 1000 : 0)
        // Guard against duration=0 heartbeats slipping through (e.g. a .stopped before
        // the gate opened with no known item duration).
        guard durationMs > 0 || state == .stopped else { return }

        let currentMs = Int(player.currentTime().seconds.isFinite ? player.currentTime().seconds * 1000 : 0)
        let currentSecond = currentMs / 1000

        if !force,
           state == lastTimelineState,
           currentSecond == lastReportedSecond {
            return
        }
        lastTimelineState = state
        lastReportedSecond = currentSecond

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

    /// Fire the scrobble once the playhead crosses ~90% of the duration (P9 #11). Only
    /// meaningful once we have a real duration; `sendScrobble()` guards re-entry.
    private func scrobbleIfNearEnd() {
        guard !didScrobble, isReadyForReporting else { return }
        let durSecs = player.currentItem?.duration.seconds ?? 0
        guard durSecs.isFinite, durSecs > 0 else { return }
        let curSecs = player.currentTime().seconds
        guard curSecs.isFinite else { return }
        if curSecs / durSecs >= 0.90 {
            sendScrobble()
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
        reportTimeline(state: .stopped, force: true)
        sendScrobble()
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
            let resumeMs = pendingResumeMs ?? item.viewOffset
            removeObservers()
            Task { await self.startStreaming(resumeOffsetMsOverride: resumeMs) }
            return
        }

        NSLog("PlaybackController: playback failed, surfacing to UI (%@)",
              String(describing: error))
        playbackError.set(error)
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
