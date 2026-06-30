import Foundation
import Observation
import PMSKit
import AVFoundation   // D1: AVURLAsset playability probe on a finished download
import os

/// Diagnostic log for the offline-download pipeline. Inspect with:
///   log show --predicate 'subsystem == "com.jlipworth.VisionPlay"' --last 10m
/// Only scrubbed values are logged — never the token or full URL (the transcode
/// URL carries `X-Plex-Token` as a query param), so we log `url.path` only.
let downloadLog = Logger(subsystem: "com.jlipworth.VisionPlay", category: "Downloads")

enum DownloadOptimizeStateLabel {
    static let queued = "queued"
    static let transcoding = "transcoding"
    static let finalizing = "finalizing"
}

private struct ForwardOnlyStallObservation {
    var bytes: Int
    var lastForwardProgressAt: Date
}

private struct ForwardOnlyStallRestart {
    let record: DownloadRecord
    let stalledFor: TimeInterval
    let attempt: Int
}

/// Coordinates the offline-download pipeline:
///   1. trigger a server-side capped-bitrate optimize (8 Mbps 1080p preset),
///   2. poll the item's metadata until the optimized `Part` appears,
///   3. fetch that part over a **background** `URLSession` into Application Support,
///   4. record it in `DownloadStore` (ratingKey -> local file, size, progress).
///
/// Offline playback reuses the custom player via `CustomPlayerView(localFile:item:)`.
///
/// The optimize trigger is the highest-uncertainty area in the whole app — see
/// `triggerOptimize(...)`. It is isolated behind that single method so the live
/// (server-specific playlist + targetTagID) path can be swapped in without
/// touching the rest of the pipeline.
@MainActor
@Observable
public final class DownloadManager {

    /// Surfaced failure/edge states for the UI. Not thrown — recorded so the
    /// `OfflineLibraryView` can show why a job didn't complete.
    public enum DownloadError: Error, Sendable, Equatable {
        case notAuthenticated
        case optimizeFailed(String)
        // Legacy UI mapping only. Plex optimize polling no longer fails by wall clock; long
        // server renders remain queued/transcoding until Plex reports a real terminal failure.
        case optimizeTimedOut
        // Deliberately never produced today: the optimize path surfaces `.optimizeFailed`
        // only when Plex reports a true terminal failure. Retained because `OfflineLibraryView`
        // still maps it to a user-facing message, so a future "optimized version had no Part"
        // diagnostic can be wired in without churn.
        case noOptimizedPart
        case storageFull
        case storageLimitExceeded(String)
        case transferFailed(String)
        /// The transfer finished with a 2xx but the body wasn't a usable video
        /// container (HTML/JSON error page, truncated transcode, unplayable). D1:
        /// previously such bodies were saved as "complete" and failed at playback.
        case invalidDownload(String)
        /// #95: a recoverable interruption (e.g. headset-off killed the transfer) that handed
        /// back URLSession resume data. NOT a hard failure — the partial + resume blob are kept
        /// and the row is `.paused`; the UI shows a "will resume" affordance rather than a red error.
        case interruptedResumable
    }

    /// What the user chose in the download sheet, resolved from the direct-play probe.
    public enum DownloadChoice: Sendable, Equatable {
        /// Direct-download the original file (probe said whole-file direct play).
        case original
        /// Server-side optimize to a named preset (the server's real target name).
        case optimize(targetName: String)
        /// #83: original-quality compatible remux (Jellyfin/Emby only) — copy the video stream into
        /// an offline-playable MP4, transcoding only audio/container as needed. Forward-only (a
        /// remux stream is not range-resumable). Plex falls back to `.optimize` for this choice.
        case optimizeCompatible
        /// #112: download an EXISTING server-generated Plex Version exactly as-is. This is a static
        /// byte-for-byte transfer of the chosen `Media`/`Part` (range-resumable, like `.original`),
        /// but deliberately bypasses the original direct-play preflight/locally-playable gates —
        /// the user explicitly picked a pre-rendered server version — and never touches the Plex
        /// optimize queue (no render/re-render). The chosen version is addressed by `mediaIndex`.
        case existingVersion
    }

    /// Internal control-flow error for async server-prep work that outlived the row it belonged to.
    ///
    /// Deleting/retrying a server-prep row removes the visible row and can immediately enqueue a
    /// replacement with a new attempt identity. The old async poller is not a URLSession task, so it
    /// may wake up later after the server has produced a file. Treat that as a no-op, not as a
    /// user-visible failure, and never let it overwrite the newer row or start a duplicate transfer.
    enum DownloadLifecycleCancellation: Error {
        case staleOptimizeAttempt
    }

    /// Live records (in-progress + completed), backed by `DownloadStore`.
    public private(set) var records: [DownloadRecord] = []

    /// Coarse, pre-derived UI state for `OfflineLibraryView`.
    ///
    /// Rows used to read `records`, progress dictionaries, ETA dictionaries, active jobs, and
    /// errors directly from SwiftUI. Under Observation that makes every progress tick invalidate a
    /// broad part of the list. Keep the hot derived strings/fractions in one snapshot so the view
    /// observes a single value and row bodies stay manager-free.
    var offlineLibrarySnapshot: OfflineLibrarySnapshot = .empty

    /// ratingKeys with an active (optimize or transfer) job in flight.
    public internal(set) var activeJobs: Set<String> = []
    private var retryingRows: Set<String> = []
    private var retryPresentationRows: Set<String> = []
    /// Rows intentionally parked as `.failed` only as an internal retry handoff sentinel.
    /// While present, refresh cleanup must not treat the `.failed` row as terminal; the backend
    /// retry task still needs `retryingRows` to pass its async continuation guard. Cleared as soon
    /// as replacement work is seeded or a real failure path releases the retry.
    private var retryHandoffRows: Set<String> = []
    @ObservationIgnored private var refreshRecordsTask: Task<Void, Never>?
    private var serverPrepResumeRetryTask: Task<Void, Never>?
    @ObservationIgnored private var serverPrepPollerTasks: [String: Task<Void, Never>] = [:]
    /// Server-prep attempt identities for Plex optimize and Emby convert. Keeps protected Plex
    /// queue titles, Plex poller ownership, and Emby convert attempt UUIDs in one IO-free model.
    /// The queue title must stay protected for the REAL download lifetime (until the file
    /// finishes/fails), not merely until optimize kickoff returns.
    var serverPrepAttempts = ServerPrepAttemptTracker()
    private var serverPrepRefreshKickScheduled = false
    private var lastServerPrepRefreshKickAt: Date?
    private var lastServerPrepQueuePausedLogAt: Date?
    /// Static byte-range recovery bookkeeping that belongs to app queue/retry policy rather than
    /// URLSession mechanics: pending backend-auth rebuilds, finalization re-entry guards,
    /// checkpoint-draining pauses, queue-paused manual resumes, and one-shot restart-counter
    /// preservation.
    private var staticRangeRecovery = StaticRangeRecoveryTracker()
    @ObservationIgnored private var downloadWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var forwardOnlyStallObservations: [String: ForwardOnlyStallObservation] = [:]
    @ObservationIgnored private var forwardOnlyStallRestartAttempts: [String: Int] = [:]
    @ObservationIgnored private var lastDownloadHealthDiagnosticAt: Date?

    /// Ephemeral live Range bytes. Persisted records stay pinned to durable checkpoints so storage
    /// and Pause/Pause All accounting never claim non-resumable OS temp bytes. This overlay drives
    /// active row progress, speed, and ETA between checkpoints.
    private var liveRangeProgress: [String: DownloadLiveRangeProgressSample] = [:]

    private static let queuePausedDefaultsKey = "downloads.queuePaused"

    var storageAudit: OfflineDownloadStorageAudit {
        let inFlight = Set(activeJobs.compactMap { store.destinationsByRatingKey[$0]?.lastPathComponent })
        return store.storageAudit(inFlightRelativePaths: inFlight)
    }

    /// User-controlled queue pause. Persisted so a relaunch does not immediately restart
    /// server-prep polling or paused transfers the user intentionally stopped before refreshing.
    public private(set) var isQueuePaused: Bool = UserDefaults.standard.bool(forKey: queuePausedDefaultsKey)

    /// Last error per ratingKey, for UI surfacing.
    public internal(set) var lastError: [String: DownloadError] = [:]

    /// Smoothed transfer rate (bytes/sec) per actively-downloading ratingKey, derived
    /// in `refreshRecords` by diffing cumulative bytes between progress callbacks.
    /// Ephemeral (never persisted); drives the "x MB/s" + ETA readout in the UI.
    public private(set) var downloadSpeed: [String: Double] = [:]

    /// Pure speed/ETA estimator per actively-downloading ratingKey, driven by `refreshRecords`
    /// (#123). Replaces the old ad-hoc `(bytes, time)` baseline + EMA: the estimator owns the
    /// first-emit window, the stall decay/cutoff, the backwards-bytes re-baseline, and the
    /// Σdb/Σdt window average — all pinned by `DownloadRateEstimatorTests`. Ephemeral; never persisted.
    private var rateEstimators: [String: DownloadRateEstimator] = [:]

    /// Estimated seconds remaining for the FILE-DOWNLOAD phase, per actively-downloading
    /// ratingKey. Derived from the smoothed `downloadSpeed` and the remaining bytes
    /// (`expectedTotal − bytesWritten`, where `expectedTotal` is recovered from the record's
    /// `bytes / progress`, persisted static Part size, or a transcoder size estimate). Suppressed
    /// (absent) only when the rate is ~0 or the total is unknown; long but real ETAs still render.
    /// Ephemeral (never persisted); drives the "~M min left" readout in the download phase.
    public private(set) var downloadETA: [String: TimeInterval] = [:]

    /// Server-side optimize/transcode progress (0.0…1.0) per ratingKey, polled from
    /// `GET /activities` during the "Preparing on server…" phase. Absent when the server
    /// reports no matching activity (caller falls back to the indeterminate caption).
    /// Ephemeral (never persisted); drives the "Transcoding… 37%" readout.
    public internal(set) var optimizeProgress: [String: Double] = [:]

    /// Estimated seconds remaining for the server-side optimize, derived from an EMA over
    /// the moving percent. Present only when the rate is stable enough to be meaningful;
    /// suppressed while noisy/indeterminate. Labelled "estimated" in the UI.
    public private(set) var optimizeETA: [String: TimeInterval] = [:]

    /// Coarse optimize state label per ratingKey: "queued" (job seen but no progress yet)
    /// or "transcoding" (progress reported). Absent when no matching activity is found.
    public internal(set) var optimizeState: [String: String] = [:]

    /// Active downloads whose byte stream is gated by the server's transcoder rather than by
    /// the network — i.e. the file is being served AS it renders, so a slow rate means "the
    /// server is still transcoding", NOT "slow Wi-Fi". Set for optimize/transcode downloads
    /// (where this is the reality) and surfaced in the caption so the rate isn't misread as a
    /// network problem. Ephemeral; never persisted. Membership alone marks a download as
    /// transcode-sourced; `isDownloadTranscodeLimited` adds the "running well below realtime"
    /// test so a fast-rendering job isn't mislabelled.
    var transcodeSourcedDownloads: Set<String> = []

    /// ratingKey -> the server `PlaySessionId` minted/assigned for a TRANSCODED download.
    /// Required for encoder teardown: active server encoders must be killed with
    /// `DELETE /Videos/ActiveEncodings?PlaySessionId=..` when the transfer reaches a terminal
    /// state. Fired from `releaseInFlight` (complete/failed/cancel/delete). Original/static
    /// downloads use no encoder, so they are never recorded here.
    ///
    /// #84: the same PlaySessionId is also mirrored into `OfflineMetadata.playSessionID` after the
    /// row is seeded. Normal terminal transitions tear down from this in-memory map and clear the
    /// persisted copy on success; hard-kill/relaunch cleanup uses the persisted copy in
    /// `teardownOrphanedEncodersOnLaunch()`.
    var embyPlaySessionByRatingKey: [String: String] = [:]
    var jellyfinPlaySessionByRatingKey: [String: String] = [:]
    /// Jellyfin kills idle transcodes when no session progress/ping arrives. Offline downloads
    /// consume `/Videos/{id}/stream.mp4` as a file transfer, not through the playback controller, so
    /// keep the server-minted PlaySessionId alive until the transfer reaches a terminal row state.
    @ObservationIgnored private var jellyfinDownloadKeepaliveTasks: [String: Task<Void, Never>] = [:]

    /// Last (progress 0…1, time) sample per ratingKey, used to derive `optimizeETA` rate.
    private var optimizeProgressSamples: [String: (p: Double, time: Date)] = [:]
    /// Smoothed %/sec rate per ratingKey (EMA), used to derive `optimizeETA`.
    private var optimizeRate: [String: Double] = [:]

    // #135 Stage 5c: `internal` (not `private`) so the per-backend lane subsystems split into their
    // own files (e.g. DownloadManager+EmbyConvert.swift) can reach the shared download services.
    let appModel: AppModel
    let store: DownloadStore
    let session: BackgroundDownloadSession

    /// Poll cadence for Plex server-side optimize jobs. Deliberately no wall-clock timeout:
    /// long 4K/HDR software transcodes can legitimately run for hours, and the app must base
    /// failure only on server truth (metadata/background queue status), not elapsed time.
    let optimizePollInterval: TimeInterval = 5

    init(appModel: AppModel) {
        self.appModel = appModel
        let store = DownloadStore()
        self.store = store
        self.session = BackgroundDownloadSession(store: store)
        self.records = store.records
        self.offlineLibrarySnapshot = makeOfflineLibrarySnapshot(from: self.records)
        // Reattach to any transfers that survived a relaunch + receive progress.
        self.session.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleRefreshRecords(reason: "session_change") }
        }
        // D3: surface background-delegate failures instead of silently dropping the
        // row. Hard failures record a `.failed` status in the store and hand us the
        // reason here so `lastError` can drive the OfflineLibraryView message + retry.
        self.session.onError = { [weak self] ratingKey, error in
            Task { @MainActor in
                guard let self else { return }
                self.lastError[ratingKey] = error
                if case .invalidDownload = error {
                    await self.fallbackOriginalValidationFailureIfPossible(ratingKey: ratingKey)
                }
                self.refreshRecords()
            }
        }
        self.session.onRangeRequestNeeded = { [weak self] ratingKey, reason in
            Task { @MainActor in
                self?.resumeStaticRangeWhenReady(ratingKey: ratingKey, reason: reason.rawValue)
            }
        }
        self.session.onRangeLiveProgress = { [weak self] ratingKey, liveBytes, expectedBytes in
            Task { @MainActor in
                guard let self else { return }
                self.liveRangeProgress[ratingKey] = DownloadLiveRangeProgressPolicy.mergedSample(
                    liveBytes: liveBytes,
                    expectedBytes: expectedBytes,
                    previous: self.liveRangeProgress[ratingKey],
                    updatedAt: Date())
                self.scheduleRefreshRecords(reason: "range_live_progress")
            }
        }
        // D2: rows with no live task can't be told apart from a stall, so reconcile
        // them to `.failed` (retryable) once we know which tasks survived, except
        // server-prep optimized rows that can resume polling after relaunch. The
        // `getAllTasks` completion lands off the main actor; the store is thread-safe,
        // so we reconcile there and hop to `@MainActor` to publish records and kick any
        // now-queued optimized jobs. This second kick closes the launch-order race where
        // auth restore called `resumePendingServerPrepDownloads()` before reattach reset
        // a stale `.downloading` optimized row back to `.queued`.
        // #169: capture which static byte-range rows were actively transferring (not user-paused)
        // BEFORE `reconcile` parks them `.paused`, so we can auto-resume an interrupted download
        // after a hard kill without overriding a row the user deliberately paused.
        let interruptedStaticKeys = store.interruptedStaticByteRangeKeys()
        self.session.reattach { [weak self, store] liveKeys in
            store.reconcile(liveRatingKeys: liveKeys)
            Task { @MainActor in
                self?.refreshRecords()
                self?.finalizeCompletedStaticRangeDownloads(reason: "launch_recovered")
                if self?.isQueuePaused != true {
                    self?.resumePendingServerPrepDownloads()
                    self?.resumeInterruptedStaticByteRangeDownloads(candidateKeys: interruptedStaticKeys,
                                                                    liveKeys: liveKeys)
                }
                // #84: reclaim any server encoder leaked by a HARD app kill (the in-memory
                // PlaySessionId maps are empty on a fresh launch; the persisted `playSessionID`
                // on each row is the only handle left to DELETE the encoder).
                self?.teardownOrphanedEncodersOnLaunch()
            }
        }
    }

    /// #84: launch-time sweep that tears down server encoders whose download reached a terminal
    /// state but whose `releaseInFlight` teardown never fired (e.g. a hard app kill mid-transfer,
    /// so the in-memory PlaySession maps were lost). Resolves each row's backend via the migration
    /// fallback and only fires when that backend lane is still configured (a DELETE needs creds).
    /// The persisted `playSessionID` is cleared ONLY once the encoder is confirmed gone, so a
    /// teardown that fails (server unreachable / wrong server) retries on a later launch instead
    /// of leaking the encoder forever.
    func teardownOrphanedEncodersOnLaunch() {
        for record in records {
            guard let md = record.metadata, let psid = md.playSessionID, !psid.isEmpty,
                  record.status == .failed || record.status == .complete || record.status == .unverified else { continue }
            let kind = md.resolvedBackendKind(ratingKey: record.ratingKey)
            // Need a live session for that backend to issue the DELETE.
            guard let live = appModel.backendSession(for: kind) else { continue }
            // Only tear down on the SAME server the encoder lives on. If the lane was re-pointed
            // at a different server (re-login elsewhere), firing the DELETE there would hit the
            // wrong server and leak the original encoder — skip and keep the psid so a later
            // launch on the matching server retries.
            guard live.matchesPersistedServer(md) else { continue }
            let key = record.ratingKey
            switch kind {
            case .jellyfin:
                recordDownloadDiagnostic("downloads.jellyfin_encoder_teardown", fields: [
                    "download_id": .identifier(key),
                    "phase": .label("launch_sweep"),
                ])
                let service = JellyfinBrowseService(appModel: appModel)
                Task { if await service.stopActiveEncoding(playSessionId: psid, session: live) { store.clearPlaySessionID(ratingKey: key) } }
            case .emby:
                recordDownloadDiagnostic("downloads.emby_encoder_teardown", fields: [
                    "download_id": .identifier(key),
                    "phase": .label("launch_sweep"),
                ])
                let service = EmbyBrowseService(appModel: appModel)
                Task { if await service.stopActiveEncoding(playSessionId: psid, session: live) { store.clearPlaySessionID(ratingKey: key) } }
            case .plex:
                // Plex optimize renders server-side then serves a static file — no live encoder to
                // tear down (the queue item is reaped separately). Clear the unused psid.
                store.clearPlaySessionID(ratingKey: key)
            }
        }
    }

    /// Confirm a persisted encoder handle belongs to the currently-restored backend lane before
    /// sending `DELETE /Videos/ActiveEncodings`. Prefer stable server ids; fall back to the saved
    /// base URL for servers that did not provide one.
    /// Absolute local URL for a completed download, if present on disk.
    public func localURL(for ratingKey: String) -> URL? {
        store.localURL(for: ratingKey)
    }

    /// Absolute cached Plex BIF index URL for a completed download, if present on disk.
    public func plexBIFURL(for ratingKey: String) -> URL? {
        store.plexBIFURL(for: ratingKey)
    }

    /// Absolute cached Jellyfin trickplay playlist URL for a completed download, if present on disk.
    public func jellyfinTrickPlayPlaylistURL(for ratingKey: String) -> URL? {
        store.jellyfinTrickPlayPlaylistURL(for: ratingKey)
    }

    /// Absolute cached per-chapter image URLs (chapter index → file) for a completed download (#88/#89).
    public func chapterImageURLs(for ratingKey: String) -> [Int: URL] {
        store.chapterImageURLs(for: ratingKey)
    }

    /// Whether an active download's byte stream is gated by the server's transcoder (the file
    /// is served as it renders) rather than by the network — so a slow rate means "server still
    /// transcoding", not "slow connection". #123: decided by the PERSISTED lane (see
    /// `isLiveTranscoderSourced`) rather than the old in-memory marker + 500 KB/s heuristic, so the
    /// "/s" suppression survives relaunch and a fast-rendering optimize job is still correctly
    /// suppressed (its byte cadence is transcoder output, not wire speed, at any rate). The UI uses
    /// this to caption the phase honestly + avoid implying a fabricated network speed. The derived
    /// ETA already reflects the real (gated) byte rate.
    public func isDownloadTranscodeLimited(_ ratingKey: String) -> Bool {
        guard let record = records.first(where: { $0.ratingKey == ratingKey }),
              record.status == .downloading else { return false }
        // #123 / #135 Stage 1c: the lane × backend × progress classification lives in the pure,
        // tested `DownloadDisplayClassifier`.
        return Self.isDownloadTranscodeLimited(record)
    }

    private static func isDownloadTranscodeLimited(_ record: DownloadRecord) -> Bool {
        record.status == .downloading && DownloadDisplayClassifier.isLiveTranscoderSourced(record)
    }

    /// #84: whether the backend lane a row needs is currently configured/authenticated. The
    /// offline UI uses this to caption a server-prep row whose lane is signed out honestly
    /// ("…signed out") instead of implying the server is still preparing. The row stays `.queued`
    /// and auto-resumes once the lane returns (see `resumePendingServerPrepDownloads`).
    public func isBackendConfigured(for record: DownloadRecord) -> Bool {
        let kind = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
        return appModel.backendSession(for: kind) != nil
    }

    /// Store identity for a SPECIFIC backend. Filenames/rows are keyed by IDs, not titles, so
    /// duplicate episode/movie names are safe. Jellyfin/Emby IDs are namespaced so they cannot
    /// collide with a Plex ratingKey in the shared offline index. The `backend` is passed
    /// explicitly (rather than read from `appModel.activeBackend`) so keying never depends on the
    /// globally-active lane — at the UI call site the active backend IS the correct backend (the
    /// user downloads what they're browsing), but the key is then stable regardless of switches.
    public func recordKey(for item: MediaItem, backend: DownloadBackendKind) -> String {
        DownloadRecordIdentity.recordKey(for: item.ratingKey, backend: backend)
    }

    static func jellyfinRecordKey(_ itemId: String) -> String {
        DownloadRecordIdentity.recordKey(for: itemId, backend: .jellyfin)
    }

    private static func isJellyfinRecordKey(_ ratingKey: String) -> Bool {
        DownloadRecordIdentity.isJellyfinRecordKey(ratingKey)
    }

    private static func jellyfinItemID(fromRecordKey ratingKey: String) -> String {
        DownloadRecordIdentity.jellyfinItemID(fromRecordKey: ratingKey)
    }

    static func embyRecordKey(_ itemId: String) -> String {
        DownloadRecordIdentity.recordKey(for: itemId, backend: .emby)
    }

    private static func isEmbyRecordKey(_ ratingKey: String) -> Bool {
        DownloadRecordIdentity.isEmbyRecordKey(ratingKey)
    }

    private static func embyItemID(fromRecordKey ratingKey: String) -> String {
        DownloadRecordIdentity.embyItemID(fromRecordKey: ratingKey)
    }

    /// Run the download-time direct-play probe for `item` at the given media/part. Advertises
    /// the `.original` 200_000 kbps ceiling so a high-bitrate-but-compatible file still
    /// qualifies for a direct download — a cap must NEVER force a transcode verdict for
    /// downloads. Returns `(playsWholeFileDirectly, originalPart)`; on any probe failure
    /// returns `(false, part?)` so the caller falls back to the optimizer.
    public func directPlayProbe(for item: MediaItem, server: URL, token: String,
                                mediaIndex: Int, partIndex: Int)
        async -> (direct: Bool, part: Part?) {
        let part = item.media?[safe: mediaIndex]?.part[safe: partIndex]
        let metadataKey = item.key ?? "/library/metadata/\(item.ratingKey)"
        let transcode = TranscodeRequest(server: server, token: token,
                                         identity: appModel.identity,
                                         metadataKey: metadataKey,
                                         maxVideoBitrateKbps: 200_000,
                                         sessionID: "visionplay-dl-probe-" + UUID().uuidString,
                                         mediaIndex: mediaIndex, partIndex: partIndex)
        do {
            let decision = try await appModel.client.send(transcode.directPlayProbeRequest(),
                                                          as: DecisionResponse.self)
            let eligibility = OfflineDownloadDecision.originalEligibility(decision: decision, part: part)
            var fields: [String: DiagnosticFieldValue] = [
                "download_id": .identifier(item.ratingKey),
                "direct": .bool(decision.playsWholeFileDirectly),
                "container": .label(eligibility.container),
                "local_playable": .bool(eligibility.localPlayableContainer),
                "saves_video_encode": .bool(decision.savesVideoEncode),
                "route": .label(eligibility.route),
            ]
            if let reason = eligibility.optimizeReason { fields["reason"] = .label(reason) }
            if let code = decision.mdeDecisionCode { fields["mde_code"] = .int(code) }
            if let code = decision.generalDecisionCode { fields["general_code"] = .int(code) }
            if let d = decision.partDecision { fields["part_decision"] = .label(d) }
            if let d = decision.videoDecision { fields["video_decision"] = .label(d) }
            if let d = decision.audioDecision { fields["audio_decision"] = .label(d) }
            recordDownloadDiagnostic("downloads.original_probe", fields: fields)
            return (eligibility.playsWholeFileDirectly, part)
        } catch {
            downloadLog.error("download-probe-failed ratingKey=\(item.ratingKey, privacy: .public) error=\(DiagnosticRedactor.safeErrorSummary(error), privacy: .public)")
            recordDownloadDiagnostic("downloads.original_probe", fields: [
                "download_id": .identifier(item.ratingKey),
                "probe": .label("failed"),
                "container": .label(OfflineDownloadDecision.containerLabel(part: part)),
                "local_playable": .bool(Self.isLocallyPlayableOriginal(part: part)),
            ])
            return (false, part)
        }
    }

    /// Download quality labels for the sheet. Plex exposes three server Media Optimizer
    /// target tags, but first-party clients also offer custom sync/videoQuality profiles
    /// (Universal TV + 20/12/10/8 Mbps 1080p, 720p, 480p, etc.). Always include those
    /// custom profiles so the offline picker matches the iPad-style quality ladder.
    public func optimizePresetNames(server: URL, token: String) async -> [String] {
        let serverTargets = (try? await appModel.client.send(
            OptimizeRequest.mediaProcessingTargetsRequest(server: server, token: token,
                                                          identity: appModel.identity),
            as: MediaProcessingTargets.self))?.targets.map(\.name) ?? []
        return Self.dedup(serverTargets + Self.customDownloadProfileNames)
            .filter(Self.isVisibleDownloadPresetName)
            .filter { !$0.isEmpty }
    }

    /// Whether a download already exists (completed or in-flight) for `ratingKey`.
    /// Lets the options sheet show "Downloaded" / disable re-download.
    public func hasDownload(for ratingKey: String) -> Bool {
        records.contains { $0.ratingKey == ratingKey }
    }


    /// Acquire the per-ratingKey in-flight slot before starting a new download.
    ///
    /// A retry can remove the only visible row while the previous terminal callback is still
    /// unwinding. If that leaves `activeJobs` set but no store row, future starts would be
    /// ignored as "already active" and the item would never appear in Downloads. Treat that
    /// combination as stale bookkeeping and clear it before accepting the new start.
    func acquireInFlightSlotForStart(ratingKey: String, backend: String) -> Bool {
        let existingStatus = store.records.first(where: { $0.ratingKey == ratingKey })?.status
        switch DownloadStartSlotPolicy.decision(existingRecordStatus: existingStatus,
                                                hasActiveSlot: activeJobs.contains(ratingKey)) {
        case .accept:
            break
        case .rejectExistingActiveRow(let status):
            recordDownloadDiagnostic("downloads.enqueue_ignored", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label(backend),
                "reason": .label("existing_active_row"),
                "status": .label(status.rawValue),
            ])
            return false
        case .rejectAlreadyActive:
            recordDownloadDiagnostic("downloads.enqueue_ignored", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label(backend),
                "reason": .label("already_active"),
            ])
            return false
        case .recoverStaleSlotAndAccept:
            recordDownloadDiagnostic("downloads.inflight_recovered", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label(backend),
                "reason": .label("active_without_row"),
            ])
            releaseInFlight(ratingKey: ratingKey)
        }
        activeJobs.insert(ratingKey)
        return true
    }

    /// Pause one visible download row. Active URLSession transfers are cancelled with resume data
    /// when the backend lane supports it; server-prep rows are marked paused so relaunch/refresh
    /// does not auto-poll/retry until the user resumes.
    public func pause(ratingKey: String) {
        guard let record = records.first(where: { $0.ratingKey == ratingKey }) else { return }
        let pauseAction = DownloadPausePolicy.rowAction(
            status: record.status,
            isStaticRangeRecord: Self.isStaticRangeRecord(record),
            isTrackingTransfer: session.isTrackingTransfer(ratingKey: ratingKey)
        )
        guard pauseAction != .ignore else { return }

        recordDownloadDiagnostic("downloads.pause", fields: [
            "download_id": .identifier(ratingKey),
        ])
        retryingRows.remove(ratingKey)
        staticRangeRecovery.removeManualQueueResume(ratingKey)
        lastError[ratingKey] = .interruptedResumable

        switch pauseAction {
        case .ignore:
            break
        case .checkpointPauseAndCancelTask:
            // Static Range rows pause at a real durable checkpoint. Keep the persisted lifecycle
            // as active while the current bounded chunk drains so progress/rate remain honest and
            // the row does not bounce Paused→Downloading from delegate progress. The session writes
            // `.paused` once the checkpoint is appended (or immediately for non-drainable cases).
            staticRangeRecovery.markCheckpointPause(ratingKey)
            session.pause(ratingKey: ratingKey)
        case .parkStaticWithoutLiveTask:
            // A freshly seeded URLSession task can still be `.queued` until first progress. Route
            // queued rows through the session too, but park no-live static gaps immediately.
            store.setStatus(ratingKey: ratingKey, .paused)
            session.pause(ratingKey: ratingKey)
        case .cancelTaskOnly:
            session.pause(ratingKey: ratingKey)
        case .parkPreparing:
            store.setStatus(ratingKey: ratingKey, .paused)
        }
        clearOptimizeProgress(ratingKey: ratingKey)
        releaseInFlight(ratingKey: ratingKey)
        refreshRecords()
    }

    /// Pause all non-terminal work and persist the queue gate across relaunch.
    public func pauseQueue() {
        isQueuePaused = true
        staticRangeRecovery.removeAllManualQueueResumes()
        UserDefaults.standard.set(true, forKey: Self.queuePausedDefaultsKey)
        for record in records where DownloadPausePolicy.shouldPauseDuringQueuePause(record) {
            pause(ratingKey: record.ratingKey)
        }
        resumePendingEmbyConvertDownloads()
        refreshRecords()
    }

    /// Resume queue processing with no memory of which rows the last global pause touched.
    ///
    /// "Resume Queue" is intentionally snowball-style: clear the persisted queue gate, retry every
    /// idle incomplete row (`.paused` and `.failed`), then let queued/preparing server-side work
    /// resume through its normal poller. Already-active rows are left alone so we do not duplicate
    /// URLSession tasks.
    public func resumeQueue() {
        isQueuePaused = false
        staticRangeRecovery.removeAllManualQueueResumes()
        UserDefaults.standard.set(false, forKey: Self.queuePausedDefaultsKey)
        let retryKeys = records
            .filter { DownloadQueueToolbarPolicy.shouldRetryWhenResumingQueue($0.status) }
            .map(\.ratingKey)
        for key in retryKeys { retry(ratingKey: key) }
        resumePendingServerPrepDownloads()
        resumePendingStaticRangeDownloads()
        refreshRecords()
    }

    /// Auth restore and background URLSession reattachment can complete in different turns.
    /// Server-prep rows have no URLSession task yet, and relaunch-adopted Range chunks may need the
    /// backend lane to rehydrate an authenticated request before the next chunk can start. Retry a
    /// few times after launch/ready edges; both resume helpers are idempotent.
    public func scheduleServerPrepResumeRetries() {
        serverPrepResumeRetryTask?.cancel()
        serverPrepResumeRetryTask = Task { [weak self] in
            // Calls are idempotent and this task is debounced above so multiple UI edges do not
            // stack scans while backend lanes hydrate after cold launch.
            for delay in DownloadResumeRetrySchedulePolicy.retryDelaysSeconds {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                switch DownloadResumeRetrySchedulePolicy.serverPrepAction(isQueuePaused: self?.isQueuePaused == true) {
                case .resumePendingEmbyConvertOnly:
                    self?.resumePendingEmbyConvertDownloads()
                case .resumePendingServerPrep:
                    self?.resumePendingServerPrepDownloads()
                }
                self?.resumePendingStaticRangeDownloads()
            }
        }
    }

    /// App lifecycle hint for #169 transfer scheduling. DownloadManager does not decide byte-range
    /// mechanics; it just bridges the app-level scene signal to the URLSession owner.
    func noteAppScenePhase(_ phase: String) {
        session.noteAppScenePhase(phase)
        if phase == "active" {
            // #187: headset reattach can deliver a burst of background-session progress and scene
            // activation events while the Offline window is being reconstructed. Coalesce the first
            // refresh onto the next run-loop turn instead of invalidating the whole downloads list
            // synchronously during scene activation.
            scheduleRefreshRecords(reason: "scene_active")
        }
    }

    private static func isStaticRangeRecord(_ record: DownloadRecord) -> Bool {
        StaticRangeRecoveryPolicy.isStaticRangeRecord(record)
    }

    private func staticRangeBackendSession(for record: DownloadRecord) -> BackendSession? {
        let kind = backendKind(for: record)
        guard let session = appModel.backendSession(for: kind) else { return nil }
        if let metadata = record.metadata, !session.matchesPersistedServer(metadata) {
            return nil
        }
        return session
    }

    @discardableResult
    private func deferStaticRangeRetryIfBackendUnavailable(record: DownloadRecord, reason: String) -> Bool {
        guard Self.isStaticRangeRecord(record),
              staticRangeBackendSession(for: record) == nil else {
            staticRangeRecovery.removePendingResume(record.ratingKey)
            return false
        }
        deferStaticRangeResume(record: record, reason: reason)
        return true
    }

    private func deferStaticRangeResume(record: DownloadRecord,
                                        reason: String,
                                        preserveActiveIntent: Bool = false) {
        let ratingKey = record.ratingKey
        let backend = backendKind(for: record)
        let checkpointBytes = store.resetStaticRangeProgressToDurableCheckpoint(ratingKey: ratingKey)
        staticRangeRecovery.addPendingResume(ratingKey)
        clearRetryHandoff(ratingKey: ratingKey)
        retryingRows.remove(ratingKey)
        switch StaticRangeRecoveryPolicy.deferredResumeDisposition(
            checkpointBytes: checkpointBytes,
            preserveActiveIntent: preserveActiveIntent
        ) {
        case .queuedActiveIntent:
            // This was not a user pause: a system/adopted Range continuation needs backend auth before
            // it can rebuild the next request. Persist an active queued intent so a second app kill
            // before backend restore is derived by launch auto-resume instead of turning into a manual
            // `.paused` / `.failed` row with only in-memory pending state.
            store.setStatus(ratingKey: ratingKey, .queued)
            lastError[ratingKey] = checkpointBytes > 0 ? .interruptedResumable : .transferFailed(
                "Download will restart when the \(backend.displayName) session is ready.")
        case .pausedAtCheckpoint:
            store.setStatus(ratingKey: ratingKey, .paused)
            lastError[ratingKey] = .interruptedResumable
        case .failedNoCheckpoint:
            // No durable checkpoint remains (for example, an adopted chunk discovered a validator
            // mismatch and discarded the stale prefix). Keep this restartable as a failed row rather
            // than a paused row with no partial and no retry path.
            store.setStatus(ratingKey: ratingKey, .failed)
            lastError[ratingKey] = .transferFailed(
                "No completed checkpoint was saved before the interruption; retry will restart this download from 0%.")
        }
        recordDownloadDiagnostic("downloads.range_resume_deferred", fields: [
            "download_id": .identifier(ratingKey),
            "backend": .label(backend.rawValue),
            "reason": .label(reason),
            "checkpoint_bytes": .bytes(checkpointBytes),
        ])
        refreshRecords()
    }


    private func finalizeCompletedStaticRangeIfNeeded(record: DownloadRecord, reason: String) -> Bool {
        let ratingKey = record.ratingKey
        let checkpointBytes = store.durableStaticRangeCheckpointSize(ratingKey: ratingKey)
        switch StaticRangeRecoveryPolicy.finalizeDecision(
            for: record,
            checkpointBytes: checkpointBytes,
            isAlreadyFinalizing: staticRangeRecovery.isFinalizing(ratingKey)
        ) {
        case .ignore:
            if record.status == .complete || record.status == .unverified || record.status == .failed {
                staticRangeRecovery.unmarkFinalizing(ratingKey)
            }
            return false
        case .alreadyFinalizing:
            return true
        case .start:
            break
        }
        staticRangeRecovery.removePendingResume(ratingKey)
        staticRangeRecovery.markFinalizing(ratingKey)
        recordDownloadDiagnostic("downloads.range_finalize_resume", fields: [
            "download_id": .identifier(ratingKey),
            "reason": .label(reason),
            "checkpoint_bytes": .bytes(checkpointBytes),
        ])
        let started = session.finalizeCompletedStaticRangeFile(ratingKey: ratingKey,
                                                               validationLabel: "range_checkpoint_recovered")
        if started {
            lastError[ratingKey] = nil
        } else {
            staticRangeRecovery.unmarkFinalizing(ratingKey)
        }
        return started
    }

    private func resumeStaticRangeWhenReady(ratingKey: String, reason: String) {
        if StaticRangeRecoveryPolicy.shouldWaitForManualResume(
            isQueuePaused: isQueuePaused,
            wasManuallyResumedWhileQueuePaused: staticRangeRecovery.wasManuallyResumedWhileQueuePaused(ratingKey)
        ) {
            guard let record = store.records.first(where: { $0.ratingKey == ratingKey }) else {
                staticRangeRecovery.removePendingResume(ratingKey)
                return
            }
            guard Self.isStaticRangeRecord(record) else {
                staticRangeRecovery.removePendingResume(ratingKey)
                return
            }
            let checkpointBytes = store.resetStaticRangeProgressToDurableCheckpoint(ratingKey: ratingKey)
            if checkpointBytes > 0 {
                store.setStatus(ratingKey: ratingKey, .paused)
                lastError[ratingKey] = .interruptedResumable
            }
            staticRangeRecovery.removePendingResume(ratingKey)
            recordDownloadDiagnostic("downloads.range_resume_queue_paused", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(reason),
                "checkpoint_bytes": .bytes(checkpointBytes),
            ])
            refreshRecords()
            return
        }
        guard let record = store.records.first(where: { $0.ratingKey == ratingKey }) else {
            staticRangeRecovery.removePendingResume(ratingKey)
            return
        }
        guard Self.isStaticRangeRecord(record) else {
            staticRangeRecovery.removePendingResume(ratingKey)
            return
        }
        if record.status == .complete || record.status == .unverified {
            staticRangeRecovery.removePendingResume(ratingKey)
            staticRangeRecovery.unmarkFinalizing(ratingKey)
            return
        }
        if finalizeCompletedStaticRangeIfNeeded(record: record, reason: reason) {
            return
        }
        guard staticRangeBackendSession(for: record) != nil else {
            deferStaticRangeResume(record: record, reason: reason, preserveActiveIntent: true)
            return
        }
        staticRangeRecovery.removePendingResume(ratingKey)
        recordDownloadDiagnostic("downloads.range_resume_ready", fields: [
            "download_id": .identifier(ratingKey),
            "backend": .label(backendKind(for: record).rawValue),
            "reason": .label(reason),
            "checkpoint_bytes": .bytes(store.durableStaticRangeCheckpointSize(ratingKey: ratingKey)),
        ])
        // A relaunch-adopted chunk can leave app-level retry/active bookkeeping behind even though
        // URLSession has no live task and the row is merely a queued continuation intent. Clear that
        // presentation/handoff state before driving the backend retry, or `retry` can no-op and the
        // user has to manually Pause→Resume to kick the exact same request.
        retryingRows.remove(ratingKey)
        clearRetryHandoff(ratingKey: ratingKey)
        if StaticRangeRecoveryPolicy.shouldPreserveRangeRestartCounters(reason: reason) {
            staticRangeRecovery.preserveRestartCountersForNextStart(ratingKey)
        }
        if StaticRangeRecoveryPolicy.shouldMarkSystemResumeInactiveBeforeRetry(record) {
            // A persisted system-resume intent is not a live task. Drop it to an inactive status for
            // the backend retry handoff so `acquireInFlightSlotForStart` will seed the replacement
            // Range request instead of treating the row as duplicate active work.
            store.setStatus(ratingKey: ratingKey, .failed)
        }
        refreshRecords()
        retry(ratingKey: ratingKey)
    }

    func consumeRangeRestartCounterPreservation(ratingKey: String) -> Bool {
        staticRangeRecovery.consumeRestartCounterPreservation(ratingKey)
    }


    private func finalizeCompletedStaticRangeDownloads(reason: String) {
        for record in store.records {
            guard record.status != .complete, record.status != .unverified else { continue }
            _ = finalizeCompletedStaticRangeIfNeeded(record: record, reason: reason)
        }
    }

    private func resumePendingStaticRangeDownloads() {
        let keys = staticRangeRecovery.resumablePendingKeys(isQueuePaused: isQueuePaused)
        guard !keys.isEmpty else { return }
        for key in keys {
            resumeStaticRangeWhenReady(ratingKey: key, reason: "backend_ready")
        }
    }

    /// Retry a previously `.failed` download (D3/D5). We rebuild the source `MediaItem`
    /// from the persisted `OfflineMetadata` snapshot (real type + media/part index) and
    /// re-run the probe-driven download path — re-probing so a now-compatible file goes
    /// direct. Rows persisted before D5 lack a snapshot, so we fall back to a minimal movie.
    public func retry(ratingKey: String) {
        guard !retryingRows.contains(ratingKey),
              let record = records.first(where: { $0.ratingKey == ratingKey }) else { return }
        guard record.status != .complete, record.status != .unverified else { return }
        let isManualStaticResumeWhileQueuePaused = DownloadRetryPreparationPolicy.isManualStaticResumeWhileQueuePaused(
            isQueuePaused: isQueuePaused,
            isStaticRangeRecord: Self.isStaticRangeRecord(record),
            status: record.status
        )
        if isManualStaticResumeWhileQueuePaused {
            staticRangeRecovery.markManualQueueResume(ratingKey)
            recordDownloadDiagnostic("downloads.range_queue_paused_manual_resume", fields: [
                "download_id": .identifier(ratingKey),
            ])
        }
        if finalizeCompletedStaticRangeIfNeeded(record: record, reason: "manual_retry") {
            return
        }
        if deferStaticRangeRetryIfBackendUnavailable(record: record, reason: "retry_backend_not_ready") {
            return
        }
        retryingRows.insert(ratingKey)
        retryPresentationRows.insert(ratingKey)
        retryHandoffRows.insert(ratingKey)
        recordDownloadDiagnostic("downloads.retry", fields: [
            "download_id": .identifier(ratingKey),
        ])
        lastError[ratingKey] = nil
        // #95: a recoverably-interrupted (`.paused`) row with persisted resume data should
        // CONTINUE from its byte offset rather than discarding the partial and restarting. This
        // path is backend-agnostic — only range-resumable sources (static originals) ever have
        // resume data, so transcoded JF/Emby rows naturally fall through to the clean restart
        // below. If the resume task is later rejected by the server (200 full-restart / 416), the
        // normal failure path makes the row retryable again from scratch.
        if DownloadRetryPreparationPolicy.shouldResumePausedEmbyConvert(
            status: record.status,
            resumeMode: record.metadata?.resolvedResumeMode(ratingKey: ratingKey),
            isEmbyRecord: Self.isEmbyRecordKey(ratingKey),
            hasEmbyConvertJobID: record.metadata?.embyConvertJobID != nil
        ) {
            store.setStatus(ratingKey: ratingKey, .preparing)
            resumePendingEmbyConvertDownloads()
            refreshRecords()
            return
        }
        let persistedResumeData = store.resumeData(ratingKey: ratingKey)
        if DownloadRetryPreparationPolicy.shouldResumePersistedURLSessionData(
            status: record.status,
            supportsPersistedResumeData: store.supportsPersistedResumeData(ratingKey: ratingKey),
            hasResumeData: persistedResumeData != nil
        ), let resumeData = persistedResumeData {
            store.clearResumeData(ratingKey: ratingKey)
            store.setStatus(ratingKey: ratingKey, .downloading)
            if session.resume(ratingKey: ratingKey, resumeData: resumeData, to: record.localURL) {
                activeJobs.insert(ratingKey)
                refreshRecords()
                return
            }
            // resume() refused the blob — fall through to a clean restart below.
            store.setStatus(ratingKey: ratingKey, .failed)
        }
        if DownloadRetryPreparationPolicy.shouldResumePausedPlexServerPrep(
            status: record.status,
            resumeMode: record.metadata?.resolvedResumeMode(ratingKey: ratingKey),
            isJellyfinRecord: Self.isJellyfinRecordKey(ratingKey),
            isEmbyRecord: Self.isEmbyRecordKey(ratingKey),
            optimizeTargetName: record.metadata?.optimizeTargetName,
            hasIncompleteStaticPartial: Self.hasIncompleteStaticPartial(record)
        ), let targetName = record.metadata?.optimizeTargetName {
            resumePausedPlexServerPrep(record: record, targetName: targetName)
            return
        }
        // #131/#146/#168/#169 live checks: paused static-byte-range rows may have only the durable
        // partial file as their checkpoint (no URLSession resume blob), or may have no durable bytes
        // yet (user paused before the first chunk committed / validator restart from zero). Promote
        // them out of `.paused` before backend-specific retry dispatch, because Jellyfin/Emby retry
        // bodies also pass through `retryAttemptCanContinue`; if the row is still `.paused`, that
        // async guard treats the user's Resume tap as cancelled and silently no-ops.
        if StaticRangeRecoveryPolicy.shouldMarkPausedRowInactiveBeforeBackendRetry(record) {
            // The backend download entry points reject existing `.queued`/`.downloading` rows as
            // duplicate active work. A partial static retry is not active yet; it is about to
            // re-acquire a URLSession task against the same destination file. Keep the row inactive
            // for that handoff so `downloadEmby`/`downloadJellyfin` can start the Range request
            // instead of no-oping and stranding the row as queued.
            store.setStatus(ratingKey: ratingKey, .failed)
        }
        if Self.isJellyfinRecordKey(ratingKey) {
            retryJellyfin(record: record)
            return
        }
        if Self.isEmbyRecordKey(ratingKey) {
            retryEmby(record: record)
            return
        }
        let metadata = record.metadata
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        // Re-probe so the retry takes the correct path: a now-compatible file goes direct,
        // otherwise re-render via the optimizer using the user's explicit default preset. Keep the
        // failed row visible until after auth/server preflight succeeds; otherwise tapping retry
        // while disconnected/not-ready removes the only visible retry affordance.
        Task { [weak self] in
            guard let self else { return }
            // #84: resolve the Plex session from its own lane (not `activeBackend`); a row whose
            // lane is unconfigured stays `.failed`/retryable with the accurate not-signed-in reason.
            guard let backendSession = self.appModel.backendSession(for: .plex) else {
                if self.deferStaticRangeRetryIfBackendUnavailable(record: record,
                                                                  reason: "plex_backend_not_ready") {
                    return
                }
                self.clearRetryHandoff(ratingKey: ratingKey)
                self.lastError[ratingKey] = .notAuthenticated
                self.store.setStatus(ratingKey: ratingKey, .failed)
                self.refreshRecords()
                return
            }
            let server = backendSession.baseURL
            let token = backendSession.token
            if self.activeJobs.contains(ratingKey) {
                self.recordDownloadDiagnostic("downloads.inflight_recovered", fields: [
                    "download_id": .identifier(ratingKey),
                    "backend": .label("Plex"),
                    "reason": .label("retry_failed_row"),
                ])
                self.releaseInFlight(ratingKey: ratingKey)
            }
            let currentItem = await self.fetchCurrentMediaItem(ratingKey: ratingKey,
                                                               server: server,
                                                               token: token,
                                                               identity: self.appModel.identity) ?? item
            guard self.retryAttemptCanContinue(ratingKey: ratingKey) else { return }

            // #131/#184: static retries must preserve the exact Part identity whenever possible,
            // not only when a durable partial exists. Plex optimized/final static rows keep
            // `sourcePartID`/serverPreparedVersion after restart; re-probing them can create or
            // chase a different optimize job and leave the user tapping repeatedly. Route back to
            // the persisted static target, preserving the partial when present and otherwise
            // redownloading the same existing Part from byte 0.
            if Self.isStaticRangeRecord(record),
               (Self.hasIncompleteStaticPartial(record) || metadata?.sourcePartID != nil || metadata?.isServerPreparedVersion == true) {
                let resolved = self.resolveStaticRetryTarget(record: record,
                                                            fallbackMediaIndex: mediaIndex,
                                                            fallbackPartIndex: partIndex,
                                                            in: currentItem)
                self.releaseInFlight(ratingKey: ratingKey)
                // Keep the row in place even when there is no durable media partial yet. `upsert`
                // preserves cached poster/chapter/trickplay paths, while `startRangeChunk` resumes
                // from the durable file size (0 when no checkpoint exists). Removing here made Plex
                // existing-version retries forget side materials and appear to restart from scratch.
                await self.download(currentItem, choice: resolved.choice,
                                    mediaIndex: resolved.mediaIndex, partIndex: resolved.partIndex)
                self.refreshRecords()
                return
            }

            // #112: legacy rows without sourcePartID that downloaded an EXISTING server version
            // retry by re-downloading that same non-source Media index as-is.
            if mediaIndex > 0,
               metadata?.resolvedDownloadLane() == .original,
               currentItem.media?.indices.contains(mediaIndex) == true {
                self.releaseInFlight(ratingKey: ratingKey)
                // Preserve side materials for the same static existing-version row; the replacement
                // upsert updates transfer fields without deleting cached assets.
                await self.download(currentItem, choice: .existingVersion,
                                    mediaIndex: mediaIndex, partIndex: partIndex)
                self.refreshRecords()
                return
            }
            let probe = await self.directPlayProbe(for: currentItem, server: server, token: token,
                                                   mediaIndex: mediaIndex, partIndex: partIndex)
            let media = currentItem.media?.indices.contains(mediaIndex) == true ? currentItem.media?[mediaIndex] : currentItem.media?.first
            let part = probe.part ?? (media?.part.indices.contains(partIndex) == true ? media?.part[partIndex] : media?.part.first)
            let choice: DownloadChoice = (probe.direct && Self.isLocallyPlayableOriginal(part: part))
                ? .original
                : .optimize(targetName: Self.originalFallbackOptimizeTarget())
            // Drop the stale `.failed` row only once we know the replacement can be seeded.
            // This also removes any leftover invalid/partial file from the failed attempt.
            guard self.retryAttemptCanContinue(ratingKey: ratingKey) else { return }
            self.releaseInFlight(ratingKey: ratingKey)
            if !Self.hasIncompleteStaticPartial(record) {
                self.store.remove(ratingKey: ratingKey)
            }
            await self.download(currentItem, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex)
            self.refreshRecords()
        }
    }

    private static func hasIncompleteStaticPartial(_ record: DownloadRecord) -> Bool {
        DownloadRetryPolicy.shouldPromotePausedStaticPartial(record)
    }

    private func retryRowStillPresent(ratingKey: String) -> Bool {
        store.records.contains { $0.ratingKey == ratingKey }
    }

    private func retryAttemptCanContinue(ratingKey: String) -> Bool {
        let row = store.records.first { $0.ratingKey == ratingKey }
        return DownloadRetryPreparationPolicy.attemptCanContinue(
            isRetrying: retryingRows.contains(ratingKey),
            rowIsPresent: row != nil,
            rowStatus: row?.status
        )
    }

    private func resolveStaticRetryTarget(record: DownloadRecord,
                                          fallbackMediaIndex: Int,
                                          fallbackPartIndex: Int,
                                          in item: MediaItem) -> (choice: DownloadChoice, mediaIndex: Int, partIndex: Int) {
        if let partID = record.metadata?.sourcePartID {
            for (mediaIndex, media) in (item.media ?? []).enumerated() {
                if let partIndex = media.part.firstIndex(where: { $0.id == partID }) {
                    let isPrimaryOriginal = mediaIndex == 0 && record.metadata?.isServerPreparedVersion != true
                    return (isPrimaryOriginal ? .original : .existingVersion, mediaIndex, partIndex)
                }
            }
        }
        let isPrepared = record.metadata?.isServerPreparedVersion == true
            || (record.metadata?.mediaIndex ?? 0) > 0
        return (isPrepared ? .existingVersion : .original, fallbackMediaIndex, fallbackPartIndex)
    }

    /// Resume a paused Plex server-prep row by reattaching to its existing optimize queue item.
    ///
    /// Do not call `retryPausedPlexOptimize` here: that path creates a fresh optimize request after
    /// fetching current metadata. A server-prep row already has the queue title/baseline needed by
    /// `resumePendingServerPrepDownloads`, so recreating risks a duplicate Plex transcode.
    private func resumePausedPlexServerPrep(record: DownloadRecord, targetName: String) {
        guard let backendSession = appModel.backendSession(for: .plex) else {
            lastError[record.ratingKey] = .notAuthenticated
            clearRetryHandoff(ratingKey: record.ratingKey)
            retryingRows.remove(record.ratingKey)
            refreshRecords()
            return
        }
        if let metadata = record.metadata, !backendSession.matchesPersistedServer(metadata) {
            recordDownloadDiagnostic("downloads.paused_optimize_resume_skip", fields: [
                "download_id": .identifier(record.ratingKey),
                "target": .label(targetName),
                "reason": .label("plex_session_mismatch"),
            ])
            lastError[record.ratingKey] = .transferFailed("Waiting for the original Plex server session.")
            clearRetryHandoff(ratingKey: record.ratingKey)
            retryingRows.remove(record.ratingKey)
            refreshRecords()
            return
        }
        recordDownloadDiagnostic("downloads.paused_optimize_resume", fields: [
            "download_id": .identifier(record.ratingKey),
            "target": .label(targetName),
            "mode": .label("reattach_server_prep"),
        ])
        // A paused server-prep row can retain a stale in-memory poller token after headset-off or a
        // previous cancelled poller. If left in place, the resume scanner filters this queued row out
        // as "already attached" and the user has to pause/resume again to kick it.
        clearServerPrepPoller(ratingKey: record.ratingKey, reason: "paused_resume")
        retryingRows.remove(record.ratingKey)
        clearRetryHandoff(ratingKey: record.ratingKey)
        store.setStatus(ratingKey: record.ratingKey, .queued)
        optimizeState[record.ratingKey] = DownloadOptimizeStateLabel.queued
        refreshRecords()
        resumePendingServerPrepDownloads(allowWhileQueuePaused: true)
    }

    private func retryPausedPlexOptimize(record: DownloadRecord, targetName: String) {
        let metadata = record.metadata
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        Task { [weak self] in
            guard let self else { return }
            guard let backendSession = self.appModel.backendSession(for: .plex) else {
                self.lastError[record.ratingKey] = .notAuthenticated
                self.store.setStatus(ratingKey: record.ratingKey, .paused)
                self.refreshRecords()
                return
            }
            if let metadata, !backendSession.matchesPersistedServer(metadata) {
                self.recordDownloadDiagnostic("downloads.paused_optimize_resume_skip", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "target": .label(targetName),
                    "reason": .label("plex_session_mismatch"),
                ])
                self.lastError[record.ratingKey] = .transferFailed(
                    "Waiting for the original Plex server session.")
                self.store.setStatus(ratingKey: record.ratingKey, .paused)
                self.refreshRecords()
                return
            }
            let currentItem = await self.fetchCurrentMediaItem(ratingKey: record.ratingKey,
                                                               server: backendSession.baseURL,
                                                               token: backendSession.token,
                                                               identity: self.appModel.identity) ?? item
            guard self.retryAttemptCanContinue(ratingKey: record.ratingKey) else { return }
            self.recordDownloadDiagnostic("downloads.paused_optimize_resume", fields: [
                "download_id": .identifier(record.ratingKey),
                "target": .label(targetName),
            ])
            self.releaseInFlight(ratingKey: record.ratingKey)
            if !Self.hasIncompleteStaticPartial(record) {
                self.store.remove(ratingKey: record.ratingKey)
            }
            await self.download(currentItem, choice: .optimize(targetName: targetName),
                                mediaIndex: mediaIndex, partIndex: partIndex)
            self.refreshRecords()
        }
    }

    private func retryJellyfin(record: DownloadRecord) {
        let metadata = record.metadata
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: Self.jellyfinItemID(fromRecordKey: record.ratingKey),
                         title: record.title,
                         type: "movie")
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        let media = item.media?.indices.contains(mediaIndex) == true ? item.media?[mediaIndex] : item.media?.first
        let part = media?.part.indices.contains(partIndex) == true ? media?.part[partIndex] : media?.part.first
        let choice: DownloadChoice
        if let targetName = metadata?.optimizeTargetName, !targetName.isEmpty {
            choice = .optimize(targetName: Self.jellyfinDownloadPreset(named: targetName))
        } else if metadata?.resolvedDownloadLane() == .compatibleRemux {
            // #83: a persisted compatible-remux row has no optimizeTargetName, so without the lane
            // discriminator it would rehydrate as `.original` and silently drop the user's intent.
            choice = .optimizeCompatible
        } else if metadata != nil {
            // #84: stored rows know the original user intent. `makeMediaItem()` intentionally does
            // not rehydrate full MediaSource/Part arrays, so deriving this from `part` after a
            // relaunch would incorrectly turn original retries into optimized transcodes.
            // #90 (won't-fix): deliberately NO Emby-style PlaybackInfo re-probe here — Jellyfin's
            // normal `.original` path doesn't probe either, and re-probing only on retry would make
            // retry behave differently from the first attempt. The theoretical
            // `.original`→fail→`.original` loop needs a non-transient route-specific failure and is
            // self-limiting (manual retry only). If a real stuck loop is ever reported, the minimal
            // fix is an attempt-count escalation to the default download preset after N consecutive
            // `.original` failures — cheaper than a speculative re-probe (mediaSourceID IS persisted).
            choice = .original
        } else if Self.isLocallyPlayableOriginal(part: part) {
            choice = .original
        } else {
            choice = .optimize(targetName: Self.jellyfinDefaultDownloadPreset)
        }

        Task { [weak self] in
            guard let self else { return }
            // #84: gate on the Jellyfin lane being configured (resolved from its own session),
            // independent of `activeBackend`; an unconfigured lane stays retryable with the
            // accurate not-signed-in reason.
            guard self.appModel.backendSession(for: .jellyfin) != nil else {
                if self.deferStaticRangeRetryIfBackendUnavailable(record: record,
                                                                  reason: "jellyfin_backend_not_ready") {
                    return
                }
                self.clearRetryHandoff(ratingKey: record.ratingKey)
                self.lastError[record.ratingKey] = .notAuthenticated
                self.store.setStatus(ratingKey: record.ratingKey, .failed)
                self.refreshRecords()
                return
            }
            if self.activeJobs.contains(record.ratingKey) {
                self.recordDownloadDiagnostic("downloads.inflight_recovered", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "backend": .label("Jellyfin"),
                    "reason": .label("retry_failed_row"),
                ])
                self.releaseInFlight(ratingKey: record.ratingKey)
            }
            guard self.retryAttemptCanContinue(ratingKey: record.ratingKey) else { return }
            // Keep the failed row visible until `downloadJellyfin` successfully seeds the
            // replacement. If PlaybackInfo/auth/network preflight fails, its start-failed path can
            // mark this existing row `.failed` instead of making the retry affordance disappear.
            await self.downloadJellyfin(item, choice: choice,
                                        mediaIndex: mediaIndex,
                                        partIndex: partIndex,
                                        mediaSourceIDOverride: metadata?.mediaSourceID)
            self.refreshRecords()
        }
    }

    private func retryEmby(record: DownloadRecord) {
        let metadata = record.metadata
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: Self.embyItemID(fromRecordKey: record.ratingKey),
                         title: record.title,
                         type: "movie")
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        // Choice intent only — `downloadEmby` re-probes PlaybackInfo and decides the real route, so
        // a now-compatible file goes original even if the failed row had an optimize target. We
        // pass `.original` unless the row explicitly recorded an optimize preset, in which case we
        // honour the user's downscale request via the explicit ladder.
        let choice: DownloadChoice
        if metadata?.isServerPreparedVersion == true, let sourceID = metadata?.mediaSourceID, !sourceID.isEmpty {
            // A server-prepared version (Emby convert-then-download output / #126 reuse) downloads a
            // specific converted MediaSource byte-for-byte. Retry MUST re-address that source via
            // `.existingVersion` (the override below carries its id) — NOT a plain `.original`, which
            // would drop the server-prepared intent and re-badge the row "Original" instead of
            // "Transcode". `.existingVersion` re-stamps `serverPreparedVersion` on the reseeded row.
            choice = .existingVersion
        } else if let targetName = metadata?.optimizeTargetName, !targetName.isEmpty {
            choice = .optimize(targetName: Self.jellyfinDownloadPreset(named: targetName))
        } else if metadata?.resolvedDownloadLane() == .compatibleRemux {
            // #83: preserve the compatible-remux intent (downloadEmby re-probes PlaybackInfo and
            // re-decides remux-vs-transcode, falling back safely if the source is no longer copyable).
            choice = .optimizeCompatible
        } else {
            choice = .original
        }

        Task { [weak self] in
            guard let self else { return }
            // #84: gate on the Emby lane being configured (resolved from its own session),
            // independent of `activeBackend`; an unconfigured lane stays retryable with the
            // accurate not-signed-in reason.
            guard self.appModel.backendSession(for: .emby) != nil else {
                if self.deferStaticRangeRetryIfBackendUnavailable(record: record,
                                                                  reason: "emby_backend_not_ready") {
                    return
                }
                self.clearRetryHandoff(ratingKey: record.ratingKey)
                self.lastError[record.ratingKey] = .notAuthenticated
                self.store.setStatus(ratingKey: record.ratingKey, .failed)
                self.refreshRecords()
                return
            }
            if self.activeJobs.contains(record.ratingKey) {
                self.recordDownloadDiagnostic("downloads.inflight_recovered", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "backend": .label("Emby"),
                    "reason": .label("retry_failed_row"),
                ])
                self.releaseInFlight(ratingKey: record.ratingKey)
            }
            guard self.retryAttemptCanContinue(ratingKey: record.ratingKey) else { return }
            // Keep the failed row visible until `downloadEmby` successfully seeds the replacement.
            // If PlaybackInfo/auth/network preflight fails, its start-failed path can mark this
            // existing row `.failed` instead of making the retry affordance disappear.
            await self.downloadEmby(item, choice: choice,
                                    mediaIndex: mediaIndex,
                                    partIndex: partIndex,
                                    mediaSourceIDOverride: metadata?.mediaSourceID)
            self.refreshRecords()
        }
    }

    /// Re-hydrate `.preparing` Emby convert rows after an app relaunch and RESUME polling their
    /// server-side Sync job (rather than restarting the conversion — it runs server-side and
    /// survives app death, which is the whole point of this lane). Idempotent: a row already being
    /// polled (`activeJobs`) is skipped. Best-effort — a row whose Emby lane is signed out stays
    /// `.preparing` and resumes automatically on the next call once the lane returns.
    private func resumePendingEmbyConvertDownloads() {
        // Use the store's current rows, not the published `records` snapshot. Manual Resume paths
        // mutate the store and then call this immediately; reading stale published rows can skip the
        // just-promoted `.preparing` record and strand it until another lifecycle edge.
        let embyPreparing = store.records.filter { record in
            let backend = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
                ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
            return record.status == .preparing
                && backend == .emby
                && record.metadata?.resolvedDownloadLane() == .optimize
                && !activeJobs.contains(record.ratingKey)
        }
        for record in embyPreparing where record.metadata?.embyConvertJobID == nil {
            recordDownloadDiagnostic("downloads.convert_failed", fields: [
                "download_id": .identifier(record.ratingKey),
                "phase": .label("resume_missing_job_id"),
            ])
            lastError[record.ratingKey] = .transferFailed("Server conversion did not finish starting; retry to create a new conversion.")
            store.setStatus(ratingKey: record.ratingKey, .failed)
            clearOptimizeProgress(ratingKey: record.ratingKey)
            releaseInFlight(ratingKey: record.ratingKey)
        }
        let candidates = embyPreparing.filter { $0.metadata?.embyConvertJobID != nil }
        guard !candidates.isEmpty else {
            refreshRecords()
            return
        }
        guard let session = appModel.backendSession(for: .emby),
              let userId = session.userID else {
            if !candidates.isEmpty {
                recordDownloadDiagnostic("downloads.convert_resume_skip", fields: [
                    "candidate_count": .int(candidates.count),
                    "reason": .label("emby_session_unavailable"),
                ])
            }
            refreshRecords()
            return
        }
        let server = session.baseURL
        let token = session.token
        let identity = appModel.identity.emby
        for record in candidates {
            guard let metadata = record.metadata,
                  let jobId = metadata.embyConvertJobID,
                  metadata.resolvedBackendKind(ratingKey: record.ratingKey) == .emby else { continue }
            guard session.matchesPersistedServer(metadata) else {
                recordDownloadDiagnostic("downloads.convert_resume_skip", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "job_id": .int(jobId),
                    "reason": .label("emby_session_mismatch"),
                ])
                continue
            }
            let ratingKey = record.ratingKey
            let targetName = metadata.optimizeTargetName ?? ""
            activeJobs.insert(ratingKey)
            let attemptID = beginEmbyConvertAttempt(ratingKey: ratingKey)
            recordDownloadDiagnostic("downloads.convert_resume", fields: [
                "download_id": .identifier(ratingKey),
                "job_id": .int(jobId),
            ])
            // Use the FULL pre-conversion File-source snapshot persisted at trigger time so the
            // freshly converted source is identified as "not in the snapshot" even when a PRIOR
            // converted version already existed. Fall back to the original source id alone for rows
            // written before the snapshot was persisted; the h264/mp4 recency heuristic in
            // `finishEmbyConvert` covers any residual ambiguity. `makeMediaItem` rebuilds the item.
            let item = metadata.makeMediaItem()
            let resumeSnapshot: Set<String> = metadata.embyConvertSnapshotIDs.map { Set($0) }
                ?? (metadata.mediaSourceID.map { [$0] } ?? [])
            Task { [weak self] in
                await self?.pollAndDownloadEmbyConvertJob(item: item, ratingKey: ratingKey,
                                                          jobId: jobId, snapshotIds: resumeSnapshot,
                                                          targetName: targetName, server: server,
                                                          token: token, identity: identity,
                                                          userId: userId, attemptID: attemptID)
            }
        }
    }

    private func shouldKeepEmbyServerPrepPollingWhileQueuePaused(_ record: DownloadRecord) -> Bool {
        ServerPrepRefreshPolicy.shouldPollEmbyServerPrepWhileQueuePaused(record)
    }

    /// #169: auto-resume static byte-range downloads that a hard app kill interrupted mid-transfer.
    ///
    /// `nsurlsessiond` keeps a background chunk running while the app is merely suspended, but once
    /// the OS terminates the app under memory pressure (likely on a multi-hour 4K download) the next
    /// chunk can't auto-start — `reconcile` parks rows with a durable partial `.paused` and rows whose
    /// first chunk never committed `.failed`. `candidateKeys` (captured BEFORE reconcile) are the rows
    /// that were ACTIVELY transferring, so resuming them honors a system interruption while leaving a
    /// user's deliberate pause alone. `retry` rebuilds the request and continues from the durable
    /// partial (or byte 0). Rows whose background task DID survive are in `liveKeys` (already
    /// continuing) and skipped.
    private func resumeInterruptedStaticByteRangeDownloads(candidateKeys: [String], liveKeys: Set<String>) {
        for ratingKey in candidateKeys where !liveKeys.contains(ratingKey) {
            guard let status = records.first(where: { $0.ratingKey == ratingKey })?.status,
                  status == .paused || status == .failed else { continue }
            recordDownloadDiagnostic("downloads.range_auto_resume", fields: [
                "download_id": .identifier(ratingKey),
            ])
            resumeStaticRangeWhenReady(ratingKey: ratingKey, reason: "launch_interrupted")
        }
    }

    /// Resume server-side Plex optimize rows that were persisted while Plex was still rendering.
    ///
    /// During "Preparing on server…" there is intentionally no URLSession task yet, so a relaunch
    /// must not reconcile the row as a dead transfer. Once auth is restored, this method resumes
    /// polling Plex for the optimized Part and starts the static file download when it appears.
    public func resumePendingServerPrepDownloads(allowWhileQueuePaused: Bool = false) {
        guard !isQueuePaused || allowWhileQueuePaused else {
            // Automatic launch/refresh retries respect the global queue pause. Do not keep emitting
            // skip diagnostics from the retry timer; `refreshRecords` parks unattached prep rows as
            // `.paused` and records `downloads.server_prep_queue_paused` once per throttle window.
            return
        }
        resumePendingEmbyConvertDownloads()
        // #84/#181: no longer gated on `activeBackend == .plex`. Each candidate is resolved against
        // its OWN persisted backend/server lane, so a Plex optimize-prep row resumes on relaunch even
        // when the app launched into Jellyfin/Emby — but never against a different Plex server.
        // Same current-store rule as Emby: callers often set the row queued/preparing immediately
        // before asking the prep scanner to attach a poller.
        let serverPrepRows = store.records.filter(DownloadRetryPolicy.isPlexServerPrepResumeCandidate)
        let candidates = serverPrepRows.filter { !serverPrepAttempts.hasPlexPoller(forRecordKey: $0.ratingKey) }
        let skippedActivePollers = serverPrepRows.count - candidates.count
        if skippedActivePollers > 0 {
            recordDownloadDiagnostic("downloads.optimize_resume_scan", fields: [
                "candidates": .int(candidates.count),
                "active_pollers": .int(skippedActivePollers),
            ])
        }
        guard !candidates.isEmpty else { return }

        for record in candidates {
            guard let metadata = record.metadata,
                  let targetName = metadata.optimizeTargetName else { continue }
            // Only Plex has a server-side render/poll PREP phase. Jellyfin/Emby optimize is a live
            // transcode stream with no separate queued-prep row, so a JF/Emby row in this state was
            // interrupted mid-transfer and is handled by reconcile (-> .failed -> retryable).
            let kind = metadata.resolvedBackendKind(ratingKey: record.ratingKey)
            guard kind == .plex else { continue }
            guard let backendSession = appModel.backendSession(for: .plex) else {
                recordDownloadDiagnostic("downloads.optimize_resume_skip", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "target": .label(targetName),
                    "reason": .label("plex_session_unavailable"),
                ])
                continue
            }
            guard backendSession.matchesPersistedServer(metadata) else {
                recordDownloadDiagnostic("downloads.optimize_resume_skip", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "target": .label(targetName),
                    "reason": .label("plex_session_mismatch"),
                ])
                continue
            }
            let server = backendSession.baseURL
            let token = backendSession.token
            let ratingKey = record.ratingKey
            if activeJobs.contains(ratingKey) {
                // A queued server-prep row with no registered poller but an active slot means the
                // lifecycle Task that should publish Plex background progress was lost or never
                // reattached. Reuse the slot and attach a fresh poller instead of leaving the UI at
                // the flat "Preparing on server…" phase forever (#181).
                recordDownloadDiagnostic("downloads.optimize_resume_stale_slot", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(targetName),
                ])
            }
            activeJobs.insert(ratingKey)
            if let queueTitle = metadata.optimizeQueueTitle {
                serverPrepAttempts.protectQueueTitle(queueTitle, forRecordKey: ratingKey)
            }
            recordDownloadDiagnostic("downloads.optimize_resume", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "has_queue_title": .bool(metadata.optimizeQueueTitle != nil),
            ])

            guard let pollerID = beginServerPrepPoller(ratingKey: ratingKey, source: "resume") else {
                continue
            }
            let task = Task { [weak self] in
                defer {
                    Task { [weak self] in
                        await MainActor.run {
                            self?.endServerPrepPoller(ratingKey: ratingKey, id: pollerID)
                        }
                    }
                }
                await self?.resumePendingOptimizeDownload(record: record,
                                                          metadata: metadata,
                                                          targetName: targetName,
                                                          server: server,
                                                          token: token)
            }
            serverPrepPollerTasks[ratingKey] = task
        }
    }

    func beginServerPrepPoller(ratingKey: String, source: String) -> UUID? {
        guard let id = serverPrepAttempts.beginPlexPoller(forRecordKey: ratingKey) else {
            recordDownloadDiagnostic("downloads.optimize_poller_skip", fields: [
                "download_id": .identifier(ratingKey),
                "source": .label(source),
                "reason": .label("already_attached"),
            ])
            return nil
        }
        recordDownloadDiagnostic("downloads.optimize_poller_attached", fields: [
            "download_id": .identifier(ratingKey),
            "source": .label(source),
        ])
        return id
    }

    func endServerPrepPoller(ratingKey: String, id: UUID) {
        guard serverPrepAttempts.endPlexPoller(forRecordKey: ratingKey, id: id) else { return }
        serverPrepPollerTasks.removeValue(forKey: ratingKey)
        recordDownloadDiagnostic("downloads.optimize_poller_detached", fields: [
            "download_id": .identifier(ratingKey),
        ])
    }

    private func clearServerPrepPoller(ratingKey: String, reason: String) {
        let hadPoller = serverPrepAttempts.clearPlexPoller(forRecordKey: ratingKey)
        let task = serverPrepPollerTasks.removeValue(forKey: ratingKey)
        task?.cancel()
        if hadPoller || task != nil {
            recordDownloadDiagnostic("downloads.optimize_poller_reset", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(reason),
            ])
        }
    }

    private func resumePendingOptimizeDownload(record: DownloadRecord,
                                               metadata: OfflineMetadata,
                                               targetName: String,
                                               server: URL,
                                               token: String) async {
        let ratingKey = record.ratingKey
        let identity = appModel.identity
        do {
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: metadata,
                                             targetName: targetName)
            let currentItem = await fetchCurrentMediaItem(ratingKey: ratingKey, server: server,
                                                         token: token, identity: identity)
                ?? metadata.makeMediaItem()
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: metadata,
                                             targetName: targetName)
            let originalPartIDs = Self.resumeOriginalPartIDs(metadata: metadata, item: currentItem)
            guard !originalPartIDs.isEmpty else {
                throw DownloadError.optimizeFailed("No source media parts found while resuming optimize.")
            }
            // Resume only the in-flight queue item below; do not grab some older Plex Version as a
            // substitute for the requested target. A future UI can offer those versions explicitly.
            let backgroundProcessingKey = await bgKeyForPolling(server: server,
                                                                 token: token,
                                                                 identity: identity)
            if let backgroundProcessingKey,
               let queueTitle = metadata.optimizeQueueTitle,
               await optimizerQueueStatus(backgroundProcessingKey: backgroundProcessingKey,
                                          queueTitle: queueTitle,
                                          server: server,
                                          token: token,
                                          identity: identity) == nil {
                recordDownloadDiagnostic("downloads.optimize_resume_recreate", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(targetName),
                ])
                do {
                    try await triggerOptimize(item: currentItem, targetName: targetName,
                                              queueTitle: queueTitle,
                                              server: server, token: token, identity: identity)
                } catch {
                    // Same policy as fresh optimize starts: a recreate failure should not briefly
                    // turn a queued/preparing row red if the optimized Part can still be discovered.
                    recordDownloadDiagnostic("downloads.optimize_create_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "target": .label(targetName),
                        "error": .error(error),
                    ])
                }
                try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                                 metadata: metadata,
                                                 targetName: targetName)
            }
            let sourceHeight = currentItem.media?[safe: metadata.mediaIndex ?? 0]?.height
            let part = try await pollForOptimizedPart(ratingKey: ratingKey,
                                                      originalPartIDs: originalPartIDs,
                                                      targetName: targetName,
                                                      sourceHeight: sourceHeight,
                                                      backgroundProcessingKey: backgroundProcessingKey,
                                                      queueTitle: metadata.optimizeQueueTitle,
                                                      mediaTitle: record.title,
                                                      server: server,
                                                      token: token,
                                                      identity: identity)
            try assertCurrentOptimizeAttempt(ratingKey: ratingKey,
                                             metadata: metadata,
                                             targetName: targetName)
            try startOptimizedPartDownload(ratingKey: ratingKey,
                                           title: record.title,
                                           part: part,
                                           metadata: metadata,
                                           server: server,
                                           token: token)
        } catch DownloadLifecycleCancellation.staleOptimizeAttempt {
            recordDownloadDiagnostic("downloads.optimize_resume_stale", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
            ])
            // If this stale exit still corresponds to the visible queued server-prep row, drop the
            // in-memory active slot so the debounced resume retries can attach a fresh poller. This
            // is safe against newer same-item attempts because Plex queueTitle is the per-attempt
            // identity; never release when the row has already handed off to bytes or another title.
            if let current = store.records.first(where: { $0.ratingKey == ratingKey }),
               current.status == .queued, current.bytes == 0, current.progress == 0,
               current.metadata?.optimizeTargetName == targetName,
               current.metadata?.optimizeQueueTitle == metadata.optimizeQueueTitle {
                clearOptimizeProgress(ratingKey: ratingKey)
                releaseInFlight(ratingKey: ratingKey)
                refreshRecords()
                scheduleServerPrepResumeRetries()
            }
        } catch let error as DownloadError {
            recordDownloadDiagnostic("downloads.optimize_resume_failed", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "error": .error(error),
            ])
            lastError[ratingKey] = error
            store.setStatus(ratingKey: ratingKey, .failed)
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
        } catch is CancellationError {
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
        } catch {
            recordDownloadDiagnostic("downloads.optimize_resume_failed", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "error": .error(error),
            ])
            lastError[ratingKey] = .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer"))
            store.setStatus(ratingKey: ratingKey, .failed)
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(ratingKey: ratingKey)
            refreshRecords()
        }
    }

    private static func resumeOriginalPartIDs(metadata: OfflineMetadata, item: MediaItem) -> Set<Int> {
        // Prefer the selected/source part over legacy persisted baselines. Older builds wrote ALL
        // current part ids here, which included already-rendered Plex Versions and prevented a
        // queued optimize row from ever discovering that matching server-prepared file.
        if let sourcePartID = metadata.sourcePartID { return [sourcePartID] }
        if let mediaIndex = metadata.mediaIndex,
           let partIndex = metadata.partIndex,
           let id = item.media?[safe: mediaIndex]?.part[safe: partIndex]?.id {
            return [id]
        }
        if let baseline = metadata.optimizeBaselinePartIDs, !baseline.isEmpty {
            return Set(baseline)
        }
        return Set((item.media ?? []).flatMap { media in
            media.part.filter { !OptimizedVersionMatch.isServerOptimizedPart($0) }.map(\.id)
        })
    }

    static func optimizeSourcePartIDs(item: MediaItem,
                                              fallbackItem: MediaItem,
                                              mediaIndex: Int,
                                              partIndex: Int) -> [Int] {
        let media = item.media?[safe: mediaIndex] ?? fallbackItem.media?[safe: mediaIndex]
        if let selected = media?.part[safe: partIndex]?.id { return [selected] }
        if let ids = media?.part.map(\.id), !ids.isEmpty { return ids }
        return (item.media ?? fallbackItem.media ?? [])
            .flatMap { media in media.part.filter { !OptimizedVersionMatch.isServerOptimizedPart($0) }.map(\.id) }
    }

    public var totalDownloadedBytes: Int {
        records.reduce(0) { $0 + $1.bytes + $1.sideAssetBytes }
    }

    public var storageLimitBytes: Int {
        PlaybackPreferences.downloadStorageLimitBytes()
    }

    public func storageLimitMessage(adding expectedBytes: Int?) -> String? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        let limit = storageLimitBytes
        guard limit > 0 else { return nil }
        let projected = totalDownloadedBytes + expectedBytes
        guard projected > limit else { return nil }
        let incoming = ByteCountFormatter.string(fromByteCount: Int64(expectedBytes), countStyle: .file)
        let used = ByteCountFormatter.string(fromByteCount: Int64(totalDownloadedBytes), countStyle: .file)
        let cap = DownloadStorageLimit.label(bytes: limit)
        return "This download needs about \(incoming), but \(used) is already used and the limit is \(cap). Increase the limit or remove downloads first."
    }

    public func estimatedBytes(for item: MediaItem, choice: DownloadChoice,
                               mediaIndex: Int = 0, partIndex: Int = 0,
                               backend: DownloadBackendKind? = nil) -> Int? {
        // #84: the trickplay surcharge is a Jellyfin-only sidecar. Resolve the backend explicitly
        // when the caller is on a specific lane (the download pipeline always passes it); the
        // default falls back to `activeBackend` for the UI sheet, which is on the active backend.
        let resolvedBackend = backend ?? appModel.activeBackend.downloadBackendKind
        let media = item.media?[safe: mediaIndex]
        let part = media?.part[safe: partIndex]
        let mediaBytes: Int?
        switch choice {
        case .original, .existingVersion:
            // #112: an existing server version is a static byte-for-byte part transfer, so the
            // chosen part's size is the storage estimate (same as `.original`).
            mediaBytes = part?.size
        case .optimizeCompatible:
            // #83: the video stream is COPIED, so the output is close to the original size (audio may
            // shrink slightly when transcoded to AAC). Use the source size as the storage estimate.
            mediaBytes = part?.size
        case .optimize(let targetName):
            if Self.isPlexOriginalQualityTarget(targetName) {
                mediaBytes = part?.size
            } else if let profile = Self.customDownloadProfile(named: targetName) {
                if let kbps = profile.settings.maxVideoBitrateKbps {
                    mediaBytes = TranscodeSizeEstimator.bytes(durationMs: item.duration,
                                                             videoBitrateBps: kbps * 1_000)
                } else {
                    mediaBytes = part?.size
                }
            } else {
                mediaBytes = TranscodeSizeEstimator.bytes(durationMs: item.duration,
                                                          videoBitrateBps: Self.mediaSettings(forTargetName: targetName).maxVideoBitrateKbps.map { $0 * 1_000 } ?? 8_000_000)
            }
        }
        // Add the thumbnail-cache estimate for every backend that caches one (not just Jellyfin) so
        // the preflight doesn't under-count for Plex/Emby. Text-subtitle sidecars are small and
        // variable, so they're accounted post-hoc from disk via `DownloadRecord.sideAssetBytes`
        // rather than pre-estimated here. Resolve against the job's OWN backend (#84), never the
        // active lane.
        let chapterImageCount = item.chapters?.filter { $0.thumb?.isEmpty == false }.count ?? 0
        let sideAssetBytes = Self.estimatedSideAssetBytes(durationMs: item.duration,
                                                         backend: resolvedBackend,
                                                         chapterImageCount: chapterImageCount)
        guard sideAssetBytes > 0 else { return mediaBytes }
        return (mediaBytes ?? 0) + sideAssetBytes
    }

    /// Rough pre-download estimate of a backend's thumbnail-cache side assets. Plex BIF + Jellyfin
    /// tile sheets are duration-proportional scrub-preview data of comparable magnitude and share
    /// one model. EVERY backend now also caches per-chapter images (#88/#89), bounded by the actual
    /// chapter image count carried by the source item.
    private static func estimatedSideAssetBytes(durationMs: Int?,
                                                backend: DownloadBackendKind,
                                                chapterImageCount: Int) -> Int {
        let chapterImages = estimatedChapterImageBytes(chapterImageCount: chapterImageCount)
        switch backend {
        case .jellyfin, .plex:
            return JellyfinTrickPlayOfflineCachePlanner.estimatedTileBytes(durationMs: durationMs) + chapterImages
        case .emby:
            return chapterImages
        }
    }

    /// Coarse per-chapter-image cache estimate (#88/#89). Chapters are typically a few dozen ~30 KB
    /// 480×270 JPEGs; only chapters with a thumbnail key are fetched.
    private static func estimatedChapterImageBytes(chapterImageCount: Int) -> Int {
        max(0, chapterImageCount) * 30_000
    }

    func rejectIfOverStorageLimit(ratingKey: String, backend: String, expectedBytes: Int?) -> Bool {
        guard let message = storageLimitMessage(adding: expectedBytes) else { return false }
        recordDownloadDiagnostic("downloads.enqueue_failed", fields: [
            "download_id": .identifier(ratingKey),
            "backend": .label(backend),
            "reason": .label("storage_limit"),
            "expected_bytes": .bytes(expectedBytes),
        ])
        lastError[ratingKey] = .storageLimitExceeded(message)
        refreshRecords()
        return true
    }

    public func deleteCompletedDownloads() {
        for record in records where record.isComplete { delete(ratingKey: record.ratingKey) }
    }

    public func deleteAllDownloads() {
        for record in records { delete(ratingKey: record.ratingKey) }
    }

    /// Delete a download and its backing file.
    public func delete(ratingKey: String) {
        recordDownloadDiagnostic("downloads.cancel_or_delete", fields: [
            "download_id": .identifier(ratingKey),
        ])
        staticRangeRecovery.removePendingResume(ratingKey)
        staticRangeRecovery.removeManualQueueResume(ratingKey)
        retryingRows.remove(ratingKey)
        // Emby convert parity (#126 + Plex): deleting a `.preparing` row must ALSO cancel the
        // server-side "Convert Media" Sync job, or it keeps rendering after the user abandoned it.
        // Capture the row BEFORE removing it (best-effort; deleting the job never deletes an
        // already-converted file, so this only ever cancels an in-flight conversion).
        let rowToDelete = store.records.first(where: { $0.ratingKey == ratingKey })
        let embySession = appModel.backendSession(for: .emby)
        let embySessionMatchesDeletedRow = rowToDelete?.metadata.map { metadata in
            embySession?.matchesPersistedServer(metadata) == true
        } ?? false
        switch DownloadDeletePolicy.embyConvertCancelDecision(
            for: rowToDelete,
            embySessionMatchesPersistedServer: embySessionMatchesDeletedRow
        ) {
        case .none:
            break
        case .cancel(let jobId):
            guard let embySession else { break }
            let server = embySession.baseURL
            let token = embySession.token
            let identity = appModel.identity.emby
            recordDownloadDiagnostic("downloads.convert_cancel", fields: [
                "download_id": .identifier(ratingKey),
                "job_id": .int(jobId),
            ])
            Task {
                if let req = try? EmbyConvertRequest.deleteJobRequest(
                    server: server, token: token, identity: identity, jobId: jobId) {
                    _ = try? await URLSession.shared.data(for: req)
                }
            }
        case .skip(let jobId, let reason):
            recordDownloadDiagnostic("downloads.convert_cancel_skip", fields: [
                "download_id": .identifier(ratingKey),
                "job_id": .int(jobId),
                "reason": .label(reason),
            ])
        }
        session.cancel(ratingKey: ratingKey)
        store.remove(ratingKey: ratingKey)
        lastError[ratingKey] = nil
        // Releasing the in-flight protection here matters because the row is now GONE, so the
        // terminal-status sweep in `refreshRecords` (which keys off `.complete`/`.failed` rows)
        // can no longer find it to release — without this, a cancelled/deleted job would leak
        // its `activeJobs` slot (blocking re-download) and keep its queue title protected forever.
        releaseInFlight(ratingKey: ratingKey)
        refreshRecords()
    }

    func recordDownloadDiagnostic(_ name: String,
                                          fields: [String: DiagnosticFieldValue] = [:]) {
        AppDiagnostics.record(.downloads, name, fields: fields)
    }

    /// Shared terminal step for every download lane: record `downloads.start`, kick off the
    /// background transfer via `start`, and record `downloads.start_failed` before rethrowing any
    /// immediate URLSession/start-time failure. `start` performs the lane's own `session.start(...)`
    /// call plus any pre-start side effects (transcode-sourced marking, PlaySessionId persistence)
    /// so the two `session.start` overloads stay at their call sites.
    func startBackgroundTransfer(_ plan: DownloadTransferStartPlan,
                                 start: () throws -> Void) throws {
        var fields: [String: DiagnosticFieldValue] = [
            "download_id": .identifier(plan.ratingKey),
            "backend": .label(plan.backendLabel),
            "choice": .label(plan.choiceLabel),
            "url_shape": .urlShape(plan.urlShape),
            "expected_bytes": .bytes(plan.expectedBytes),
        ]
        fields.merge(plan.extraDiagnosticFields) { current, _ in current }
        recordDownloadDiagnostic("downloads.start", fields: fields)
        do {
            try start()
            refreshRecords()
        } catch {
            recordDownloadDiagnostic("downloads.start_failed", fields: [
                "download_id": .identifier(plan.ratingKey),
                "backend": .label(plan.backendLabel),
                "error": .error(error),
            ])
            throw error
        }
    }

    /// Start a background transfer and surface immediate start failures on the visible row.
    ///
    /// `releaseInFlightOnFailure` preserves a real per-lane difference: the JF/Emby encoder lanes
    /// release the in-flight slot explicitly on a start failure, while the Plex static lane lets the
    /// terminal `.failed`/`refreshRecords` release it (its caller never released here).
    func beginBackgroundTransfer(_ plan: DownloadTransferStartPlan,
                                 start: () throws -> Void) {
        do {
            try startBackgroundTransfer(plan, start: start)
        } catch let error as DownloadError {
            lastError[plan.ratingKey] = error
            store.setStatus(ratingKey: plan.ratingKey, .failed)
            if plan.releaseInFlightOnFailure { releaseInFlight(ratingKey: plan.ratingKey) }
            refreshRecords()
        } catch {
            lastError[plan.ratingKey] = .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer"))
            store.setStatus(ratingKey: plan.ratingKey, .failed)
            if plan.releaseInFlightOnFailure { releaseInFlight(ratingKey: plan.ratingKey) }
            refreshRecords()
        }
    }

    func downloadDiagnosticFields(item: MediaItem,
                                          choice: DownloadChoice,
                                          backend: String,
                                          backendKind: DownloadBackendKind,
                                          mediaIndex: Int,
                                          partIndex: Int) -> [String: DiagnosticFieldValue] {
        let media = item.media.flatMap { mediaItems -> Media? in
            if mediaItems.indices.contains(mediaIndex) { return mediaItems[mediaIndex] }
            return mediaItems.first
        }
        let part = media?.part.indices.contains(partIndex) == true ? media?.part[partIndex] : media?.part.first
        var fields: [String: DiagnosticFieldValue] = [
            "download_id": .identifier(recordKey(for: item, backend: backendKind)),
            "backend": .label(backend),
            "choice": .label(Self.diagnosticChoiceLabel(choice)),
            "item_type": .label(item.type),
            "media_index": .int(mediaIndex),
            "part_index": .int(partIndex),
            "source_container": .label(media?.container ?? part?.container),
            "source_video_codec": .label(media?.videoCodec ?? part?.videoStreams.first?.codec),
            "source_audio_codec": .label(media?.audioCodec ?? part?.audioStreams.first?.codec),
            "source_bitrate_kbps": .int(media?.bitrate ?? 0),
            "expected_bytes": .bytes(part?.size),
        ]
        if let width = media?.width, let height = media?.height {
            fields["source_resolution"] = .label("\(width)x\(height)")
        }
        return fields
    }

    static func diagnosticChoiceLabel(_ choice: DownloadChoice) -> String {
        switch choice {
        case .original:
            return "original"
        case .existingVersion:
            return "existing_version"
        case .optimize(let targetName):
            return "optimize:\(targetName)"
        case .optimizeCompatible:
            return "optimize_compatible"
        }
    }

    /// #83: the persisted lane discriminator for a choice. Stored on the row so a retry/resume after
    /// an app kill preserves the user's intent — original and compatible-remux both lack an
    /// `optimizeTargetName`, so the legacy inference can't tell them apart.
    static func downloadLane(for choice: DownloadChoice) -> DownloadLane {
        switch choice {
        case .original: return .original
        // #112: an existing server version downloads as a static, range-resumable part — the same
        // transfer characteristics as `.original`, so it persists/resumes on the `.original` lane.
        // (The version is addressed by the row's persisted `mediaIndex`.)
        case .existingVersion: return .original
        case .optimize: return .optimize
        case .optimizeCompatible: return .compatibleRemux
        }
    }

    /// Display-only discriminator persisted alongside the lane: true when the chosen download is a
    /// SERVER-PREPARED (transcoded) version rather than the user's true source. `.existingVersion`
    /// covers all three: the Emby convert-then-download handoff, the Emby #126 reuse of an existing
    /// converted version, and the Plex #112 existing-version download. They all ride the `.original`
    /// static lane (resumable), so this flag — not the lane — is what lets the UI badge them
    /// "Transcode" instead of "Original". See `OfflineMetadata.serverPreparedVersion`.
    static func isServerPreparedVersion(for choice: DownloadChoice) -> Bool {
        if case .existingVersion = choice { return true }
        return false
    }

    func updateLocalPlaybackPosition(ratingKey: String, positionMs: Int, durationMs: Int?) {
        store.setLocalPlaybackPosition(ratingKey: ratingKey, positionMs: positionMs, durationMs: durationMs)
        refreshRecords()
    }

    private func clearRetryHandoff(ratingKey: String) {
        retryPresentationRows.remove(ratingKey)
        retryHandoffRows.remove(ratingKey)
    }

    private func markRetryReplacementSeeded(ratingKey: String) {
        retryingRows.remove(ratingKey)
        clearRetryHandoff(ratingKey: ratingKey)
    }

    private func scheduleRefreshRecords(reason _: String, delay: Duration = .milliseconds(500)) {
        guard refreshRecordsTask == nil else { return }
        refreshRecordsTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.refreshRecordsTask = nil
            self.refreshRecords()
        }
    }

    func refreshRecords() {
        let now = Date()
        var fresh = store.records
        let staleQueuedStaticPartials = fresh.filter { record in
            DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(
                record,
                isActive: session.isTrackingTransfer(ratingKey: record.ratingKey)
            )
        }
        if !staleQueuedStaticPartials.isEmpty {
            if isQueuePaused {
                let manuallyResumed = staleQueuedStaticPartials.filter {
                    staticRangeRecovery.wasManuallyResumedWhileQueuePaused($0.ratingKey)
                }
                let queueParked = staleQueuedStaticPartials.filter {
                    !staticRangeRecovery.wasManuallyResumedWhileQueuePaused($0.ratingKey)
                }
                for record in queueParked {
                    staticRangeRecovery.removePendingResume(record.ratingKey)
                    let checkpointBytes = store.resetStaticRangeProgressToDurableCheckpoint(ratingKey: record.ratingKey)
                    if checkpointBytes > 0 {
                        store.setStatus(ratingKey: record.ratingKey, .paused)
                        lastError[record.ratingKey] = .interruptedResumable
                    }
                    recordDownloadDiagnostic("downloads.range_stale_queued_paused", fields: [
                        "download_id": .identifier(record.ratingKey),
                        "backend": .label(backendKind(for: record).rawValue),
                        "checkpoint_bytes": .bytes(checkpointBytes),
                    ])
                }
                for record in manuallyResumed where !staticRangeRecovery.hasPendingResume(record.ratingKey) {
                    staticRangeRecovery.addPendingResume(record.ratingKey)
                    recordDownloadDiagnostic("downloads.range_stale_queued_manual_resume", fields: [
                        "download_id": .identifier(record.ratingKey),
                        "backend": .label(backendKind(for: record).rawValue),
                        "checkpoint_bytes": .bytes(store.durableStaticRangeCheckpointSize(ratingKey: record.ratingKey)),
                    ])
                }
                for record in manuallyResumed {
                    resumeStaticRangeWhenReady(ratingKey: record.ratingKey,
                                               reason: "stale_queued_static_manual_resume")
                }
            } else {
                for record in staleQueuedStaticPartials where !staticRangeRecovery.hasPendingResume(record.ratingKey) {
                    staticRangeRecovery.addPendingResume(record.ratingKey)
                    recordDownloadDiagnostic("downloads.range_stale_queued_resume", fields: [
                        "download_id": .identifier(record.ratingKey),
                        "backend": .label(backendKind(for: record).rawValue),
                        "checkpoint_bytes": .bytes(store.durableStaticRangeCheckpointSize(ratingKey: record.ratingKey)),
                    ])
                }
                // Do not dispatch this through a detached Task. The evidence for Flight showed the
                // detector firing (`range_stale_queued_resume`) while the row stayed queued/resumed with
                // no subsequent `retry`/`range_start`. Normalize synchronously on this MainActor refresh
                // turn so the queued residue cannot be lost between refresh cycles.
                for record in staleQueuedStaticPartials {
                    resumeStaticRangeWhenReady(ratingKey: record.ratingKey,
                                               reason: "stale_queued_static")
                }
            }
            fresh = store.records
        }
        let serverPrepKickIsRecent = lastServerPrepRefreshKickAt.map { now.timeIntervalSince($0) < 5 } ?? false
        let serverPrepRefreshPlan = ServerPrepRefreshPolicy.refreshPlan(
            records: fresh,
            isQueuePaused: isQueuePaused,
            refreshKickScheduled: serverPrepRefreshKickScheduled,
            refreshKickRecent: serverPrepKickIsRecent,
            hasPlexPoller: { [serverPrepAttempts] ratingKey in
                serverPrepAttempts.hasPlexPoller(forRecordKey: ratingKey)
            },
            isActiveJob: { [activeJobs] ratingKey in
                activeJobs.contains(ratingKey)
            }
        )
        if isQueuePaused {
            for ratingKey in serverPrepRefreshPlan.parkWhileQueuePausedKeys {
                if fresh.first(where: { $0.ratingKey == ratingKey })?.status != .paused {
                    store.setStatus(ratingKey: ratingKey, .paused)
                }
            }
            if !serverPrepRefreshPlan.parkWhileQueuePausedKeys.isEmpty { fresh = store.records }
            if !serverPrepRefreshPlan.parkWhileQueuePausedKeys.isEmpty,
               lastServerPrepQueuePausedLogAt.map({ now.timeIntervalSince($0) >= 5 }) ?? true {
                lastServerPrepQueuePausedLogAt = now
                recordDownloadDiagnostic("downloads.server_prep_queue_paused", fields: [
                    "candidate_count": .int(serverPrepRefreshPlan.parkWhileQueuePausedKeys.count),
                    "plex_count": .int(serverPrepRefreshPlan.parkedCounts.plex),
                    "emby_count": .int(serverPrepRefreshPlan.parkedCounts.emby),
                    "reason": .label("parked_for_manual_resume"),
                ])
            }
            if serverPrepRefreshPlan.shouldScheduleKick, serverPrepRefreshPlan.kickEmbyOnly {
                serverPrepRefreshKickScheduled = true
                lastServerPrepRefreshKickAt = now
                recordDownloadDiagnostic("downloads.server_prep_refresh_kick", fields: [
                    "candidate_count": .int(serverPrepRefreshPlan.pollEmbyWhileQueuePausedKeys.count),
                    "plex_count": .int(serverPrepRefreshPlan.kickCounts.plex),
                    "emby_count": .int(serverPrepRefreshPlan.kickCounts.emby),
                    "reason": .label("queue_paused_emby_reconcile"),
                ])
                Task { [weak self] in
                    await MainActor.run {
                        guard let self else { return }
                        self.resumePendingEmbyConvertDownloads()
                        self.serverPrepRefreshKickScheduled = false
                    }
                }
            }
        } else if serverPrepRefreshPlan.shouldScheduleKick {
            serverPrepRefreshKickScheduled = true
            lastServerPrepRefreshKickAt = now
            recordDownloadDiagnostic("downloads.server_prep_refresh_kick", fields: [
                "candidate_count": .int(serverPrepRefreshPlan.candidateKeys.count),
                "plex_count": .int(serverPrepRefreshPlan.kickCounts.plex),
                "emby_count": .int(serverPrepRefreshPlan.kickCounts.emby),
                "reason": .label("refresh_detected_unattached_prep"),
            ])
            Task { [weak self] in
                await MainActor.run {
                    guard let self else { return }
                    self.resumePendingServerPrepDownloads()
                    self.serverPrepRefreshKickScheduled = false
                }
            }
        }
        for record in fresh where retryHandoffRows.contains(record.ratingKey) {
            if record.status.isActiveWork || record.status == .complete || record.status == .unverified {
                markRetryReplacementSeeded(ratingKey: record.ratingKey)
            }
        }
        let finalizedRecoveryKeys = StaticRangeRefreshCleanupPolicy.finalizingTerminalKeys(records: fresh)
        staticRangeRecovery.subtractFinalizing(finalizedRecoveryKeys)
        let manualResumeTerminalKeys = StaticRangeRefreshCleanupPolicy.manualQueueResumeTerminalKeys(
            records: fresh,
            retryHandoffKeys: retryHandoffRows,
            retryingKeys: retryingRows
        )
        staticRangeRecovery.subtractManualQueueResumes(manualResumeTerminalKeys)
        let activeKeys = Set(fresh.filter { $0.status == .downloading }.map(\.ratingKey))
        let pendingPauseKeys = Set(fresh.filter { staticRangeRecovery.isCheckpointPausing($0.ratingKey) }.map(\.ratingKey))
        staticRangeRecovery.keepCheckpointPauses { key in
            StaticRangeRefreshCleanupPolicy.shouldKeepCheckpointPause(
                record: fresh.first(where: { $0.ratingKey == key }),
                isTrackingTransfer: session.isTrackingTransfer(ratingKey: key)
            )
        }
        liveRangeProgress = liveRangeProgress.filter { key, sample in
            guard DownloadLiveRangeProgressPolicy.isFresh(sample, now: now) else { return false }
            return StaticRangeRefreshCleanupPolicy.shouldKeepLiveRangeProgress(
                key: key,
                activeDownloadingKeys: activeKeys,
                checkpointPauseKeys: pendingPauseKeys
            )
        }
        // #123: drive one pure `DownloadRateEstimator` per actively-downloading row from its
        // cumulative byte count. The estimator owns ALL the speed/ETA math — first-emit window,
        // stall decay→nil, backwards-bytes re-baseline, and the Σdb/Σdt window average that
        // reconciles the displayed rate with Σbytes/elapsed. The actor just feeds `(bytes, now)`
        // and reads back the smoothed rate + ETA; the math is pinned by `DownloadRateEstimatorTests`.
        // #169: a background Range segment can reset optimistic temp-byte progress back to the
        // durable partial checkpoint during promotion/pause/retry. Hide rate/ETA for one averaging
        // window after that backwards rebaseline instead of flashing a bogus high-speed provisional.
        for record in fresh where record.status == .downloading {
            var estimator = rateEstimators[record.ratingKey]
                ?? DownloadRateEstimator(rebaselineSuppressWindow: 4.0)
            let sampleBytes = liveDisplayBytes(for: record, now: now) ?? record.bytes
            let rate = estimator.sample(bytes: sampleBytes, at: now)
            // Recover the expected final size for the ETA: the exact Content-Length path
            // (`bytes / progress`) when the server reported a size, the persisted static Part size
            // when a range/static row has bytes but progress is still zero, else the same
            // duration×target-bitrate estimate used for storage preflight (JF/Emby transcoder
            // streams that ship no Content-Length). Static Range rows use the ephemeral live sample
            // here so speed/ETA remain continuous even though persisted bytes are checkpoint-only.
            let expectedTotal = expectedDownloadBytes(for: record, liveBytes: sampleBytes)
            downloadSpeed[record.ratingKey] = (rate ?? 0) > 0 ? rate : nil
            downloadETA[record.ratingKey] = estimator.eta(expectedTotal: expectedTotal)
            rateEstimators[record.ratingKey] = estimator
        }
        let forwardOnlyRestarts = detectForwardOnlyStreamStalls(in: fresh, now: now)
        // Drop estimators/derived values for rows no longer downloading (complete / failed / removed).
        rateEstimators = rateEstimators.filter { activeKeys.contains($0.key) }
        downloadSpeed = downloadSpeed.filter { activeKeys.contains($0.key) }
        downloadETA = downloadETA.filter { activeKeys.contains($0.key) }
        updateDownloadWatchdog(for: fresh)
        recordDownloadHealthSnapshotIfNeeded(records: fresh, now: now)

        // Release the in-flight protection for any job whose download has reached a terminal
        // state (complete / failed). The optimize-queue title and `activeJobs` slot must stay
        // held for the REAL download lifetime, not just the optimize kickoff — so the actual
        // release happens HERE, driven by the store's terminal status, rather than in a `defer`
        // at the end of `triggerOptimizeAndDownload`/`download` (which fires while the file is
        // still transferring). Once released, `cleanStaleOptimizeJobs` is free to remove the
        // now-abandoned (completed-but-unprotected) marked queue item on the next optimize run.
        // #95: a `.paused` (recoverably-interrupted) row has genuinely stopped transferring, so it
        // releases too — its slot is re-acquired by `retry()` on resume, and releasing also fires
        // any encoder teardown should a transcoded row ever land here.
        let terminalKeys = Set(fresh.filter {
            let isInternalRetryFailedSentinel = $0.status == .failed
                && retryHandoffRows.contains($0.ratingKey)
                && retryingRows.contains($0.ratingKey)
            return !isInternalRetryFailedSentinel
                && ($0.status == .complete || $0.status == .unverified
                    || $0.status == .failed || $0.status == .paused)
        }.map(\.ratingKey))
        for key in terminalKeys { releaseInFlight(ratingKey: key) }

        records = fresh
        offlineLibrarySnapshot = makeOfflineLibrarySnapshot(from: fresh)
        ensureJellyfinDownloadKeepalives(for: fresh)
        for restart in forwardOnlyRestarts {
            Task { @MainActor [weak self] in
                self?.restartStalledForwardOnlyStream(restart)
            }
        }
    }

    private func detectForwardOnlyStreamStalls(in records: [DownloadRecord],
                                               now: Date) -> [ForwardOnlyStallRestart] {
        var candidateKeys: Set<String> = []
        var restarts: [ForwardOnlyStallRestart] = []
        for record in records where DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(record) {
            candidateKeys.insert(record.ratingKey)
            let active = activeJobs.contains(record.ratingKey)
                || session.isTrackingTransfer(ratingKey: record.ratingKey)
            var observation = forwardOnlyStallObservations[record.ratingKey]
                ?? ForwardOnlyStallObservation(bytes: record.bytes, lastForwardProgressAt: now)
            if record.bytes > observation.bytes {
                observation.bytes = record.bytes
                observation.lastForwardProgressAt = now
                forwardOnlyStallRestartAttempts[record.ratingKey] = 0
            }
            let attempts = forwardOnlyStallRestartAttempts[record.ratingKey] ?? 0
            if DownloadStallRecoveryPolicy.shouldRestartForwardOnlyStream(
                record: record,
                active: active,
                lastForwardProgressAt: observation.lastForwardProgressAt,
                now: now,
                restartAttempts: attempts
            ) {
                let nextAttempt = attempts + 1
                forwardOnlyStallRestartAttempts[record.ratingKey] = nextAttempt
                restarts.append(ForwardOnlyStallRestart(
                    record: record,
                    stalledFor: now.timeIntervalSince(observation.lastForwardProgressAt),
                    attempt: nextAttempt))
                observation.lastForwardProgressAt = now
                observation.bytes = record.bytes
            }
            forwardOnlyStallObservations[record.ratingKey] = observation
        }
        forwardOnlyStallObservations = forwardOnlyStallObservations.filter { candidateKeys.contains($0.key) }
        let liveOrRetryableKeys = Set(records.filter { $0.status != .complete && $0.status != .unverified }.map(\.ratingKey))
        forwardOnlyStallRestartAttempts = forwardOnlyStallRestartAttempts.filter { liveOrRetryableKeys.contains($0.key) }
        return restarts
    }

    private func restartStalledForwardOnlyStream(_ restart: ForwardOnlyStallRestart) {
        let ratingKey = restart.record.ratingKey
        guard let current = store.records.first(where: { $0.ratingKey == ratingKey }),
              DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(current) else { return }
        let backend = backendKind(for: current)
        recordDownloadDiagnostic("downloads.forward_stream_stall_restart", fields: [
            "download_id": .identifier(ratingKey),
            "backend": .label(backend.rawValue),
            "lane": .label(current.metadata?.resolvedDownloadLane().rawValue ?? "unknown"),
            "bytes": .bytes(current.bytes),
            "stalled_seconds": .int(Int(restart.stalledFor.rounded())),
            "attempt": .int(restart.attempt),
            "max_attempts": .int(DownloadStallRecoveryPolicy.defaultMaxAutomaticRestarts),
        ])
        session.cancel(ratingKey: ratingKey)
        retryingRows.remove(ratingKey)
        clearRetryHandoff(ratingKey: ratingKey)
        lastError[ratingKey] = .transferFailed(
            "Network stalled; restarting this forward-only stream from the beginning.")
        store.setStatus(ratingKey: ratingKey, .failed)
        releaseInFlight(ratingKey: ratingKey)
        refreshRecords()
        retry(ratingKey: ratingKey)
    }

    private func updateDownloadWatchdog(for records: [DownloadRecord]) {
        if DownloadWatchdogPolicy.requiresWatchdog(records: records) {
            guard downloadWatchdogTask == nil else { return }
            downloadWatchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(DownloadWatchdogPolicy.refreshIntervalSeconds))
                    } catch { return }
                    await MainActor.run {
                        guard let self, self.downloadWatchdogTask != nil else { return }
                        self.refreshRecords()
                    }
                }
            }
        } else {
            downloadWatchdogTask?.cancel()
            downloadWatchdogTask = nil
        }
    }

    private func recordDownloadHealthSnapshotIfNeeded(records: [DownloadRecord], now: Date) {
        let sessionSnapshot = session.diagnosticSnapshot()
        let snapshot = DownloadHealthSnapshotPolicy.makeSnapshot(
            records: records,
            activeJobCount: activeJobs.count,
            retryingCount: retryingRows.count,
            retryHandoffCount: retryHandoffRows.count,
            pendingStaticResumeCount: staticRangeRecovery.pendingResumeCount,
            finalizingStaticRecoveryCount: staticRangeRecovery.finalizingCount,
            serverPrepPollerCount: serverPrepPollerTasks.count,
            jellyfinKeepaliveCount: jellyfinDownloadKeepaliveTasks.count,
            forwardStallWatchCount: forwardOnlyStallObservations.count,
            session: makeDownloadHealthSessionSnapshot(from: sessionSnapshot))
        guard DownloadHealthSnapshotPolicy.shouldRecord(snapshot: snapshot,
                                                        lastRecordedAt: lastDownloadHealthDiagnosticAt,
                                                        now: now) else { return }
        lastDownloadHealthDiagnosticAt = now
        recordDownloadDiagnostic("downloads.health_snapshot",
                                 fields: DownloadHealthSnapshotPolicy.diagnosticFields(for: snapshot))
    }

    private func makeDownloadHealthSessionSnapshot(
        from snapshot: BackgroundDownloadSessionDiagnosticSnapshot
    ) -> DownloadHealthSessionSnapshot {
        DownloadHealthSessionSnapshot(
            opaqueInflightCount: snapshot.opaqueInflightCount,
            rangeInflightCount: snapshot.rangeInflightCount,
            haltedRangeKeyCount: snapshot.haltedRangeKeyCount,
            pendingBackgroundCompletionOperationCount: snapshot.pendingBackgroundCompletionOperationCount,
            deferredBackgroundCompletionIdentifierCount: snapshot.deferredBackgroundCompletionIdentifierCount,
            backgroundCompletionHandlerCount: snapshot.backgroundCompletionHandlerCount,
            finalizingRatingKeyCount: snapshot.finalizingRatingKeyCount,
            rangeBackgroundHandoffGraceTaskCount: snapshot.rangeBackgroundHandoffGraceTaskCount,
            gracefulRangePauseKeyCount: snapshot.gracefulRangePauseKeyCount,
            pendingTempCleanupBytes: snapshot.pendingTempCleanupBytes)
    }

    private func ensureJellyfinDownloadKeepalives(for records: [DownloadRecord]) {
        for record in records where record.status == .queued || record.status == .downloading {
            guard jellyfinDownloadKeepaliveTasks[record.ratingKey] == nil,
                  let metadata = record.metadata,
                  metadata.resolvedBackendKind(ratingKey: record.ratingKey) == .jellyfin,
                  metadata.resolvedDownloadLane() != .original,
                  let playSessionId = metadata.playSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !playSessionId.isEmpty,
                  let mediaSourceId = metadata.mediaSourceID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !mediaSourceId.isEmpty,
                  let session = appModel.backendSession(for: .jellyfin),
                  let userId = session.userID,
                  session.matchesPersistedServer(metadata)
            else { continue }

            startJellyfinDownloadKeepalive(
                ratingKey: record.ratingKey,
                itemId: Self.jellyfinItemID(fromRecordKey: record.ratingKey),
                mediaSourceId: mediaSourceId,
                playSessionId: playSessionId,
                session: session,
                userId: userId,
                durationMs: metadata.duration)
        }
    }

    func startJellyfinDownloadKeepalive(ratingKey: String,
                                                 itemId: String,
                                                 mediaSourceId: String,
                                                 playSessionId: String,
                                                 session: BackendSession,
                                                 userId: String,
                                                 durationMs: Int?) {
        jellyfinDownloadKeepaliveTasks.removeValue(forKey: ratingKey)?.cancel()
        let identity = appModel.identity.jellyfin
        jellyfinDownloadKeepaliveTasks[ratingKey] = Task { [weak self] in
            guard let self else { return }
            var sentPlaying = false
            while !Task.isCancelled {
                guard let record = self.records.first(where: { $0.ratingKey == ratingKey }),
                      record.status == .queued || record.status == .downloading else { return }
                let progress = max(0, min(record.progress, 1))
                let positionTicks = Self.downloadPositionTicks(progress: progress, durationMs: durationMs)
                do {
                    if !sentPlaying {
                        let playing = try JellyfinPlayback.playingRequest(
                            server: session.baseURL,
                            token: session.token,
                            identity: identity,
                            userId: userId,
                            itemId: itemId,
                            mediaSourceId: mediaSourceId,
                            playSessionId: playSessionId,
                            playMethod: .transcode,
                            positionTicks: positionTicks)
                        _ = try? await URLSession.shared.data(for: playing)
                        sentPlaying = true
                    }
                    let progressReq = try JellyfinPlayback.progressRequest(
                        server: session.baseURL,
                        token: session.token,
                        identity: identity,
                        userId: userId,
                        itemId: itemId,
                        mediaSourceId: mediaSourceId,
                        playSessionId: playSessionId,
                        playMethod: .transcode,
                        positionTicks: positionTicks,
                        isPaused: false)
                    _ = try? await URLSession.shared.data(for: progressReq)
                    let ping = try JellyfinPlayback.pingRequest(server: session.baseURL,
                                                                token: session.token,
                                                                identity: identity,
                                                                playSessionId: playSessionId)
                    _ = try? await URLSession.shared.data(for: ping)
                } catch {
                    recordDownloadDiagnostic("downloads.jellyfin_keepalive_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "error": .error(error),
                    ])
                }
                do {
                    try await Task.sleep(for: .seconds(20))
                } catch {
                    return
                }
            }
        }
        recordDownloadDiagnostic("downloads.jellyfin_keepalive_start", fields: [
            "download_id": .identifier(ratingKey),
        ])
    }

    private static func downloadPositionTicks(progress: Double, durationMs: Int?) -> Int {
        guard let durationMs, durationMs > 0, progress.isFinite else { return 0 }
        let ticks = Double(durationMs) * 10_000 * max(0, min(progress, 1))
        return ticks.isFinite ? max(0, Int(ticks.rounded())) : 0
    }

    /// Drop the in-flight protection (`activeJobs` slot + protected optimize-queue title) for a
    /// ratingKey once its download is no longer in flight (completed, failed, cancelled, or
    /// deleted). Idempotent. Keeping the queue title protected past this point would block the
    /// clean-slate cleanup from ever removing the now-abandoned completed optimize item.
    func releaseInFlight(ratingKey: String) {
        retryingRows.remove(ratingKey)
        clearRetryHandoff(ratingKey: ratingKey)
        activeJobs.remove(ratingKey)
        transcodeSourcedDownloads.remove(ratingKey)
        _ = serverPrepAttempts.releaseAll(forRecordKey: ratingKey)
        serverPrepPollerTasks.removeValue(forKey: ratingKey)?.cancel()
        jellyfinDownloadKeepaliveTasks.removeValue(forKey: ratingKey)?.cancel()
        forwardOnlyStallObservations.removeValue(forKey: ratingKey)
        // CLEANUP INVARIANT: a transcoded Emby download leaves a live FFmpeg encoder running on
        // the server until ActiveEncodings is deleted. Fire teardown for the minted PlaySessionId
        // on EVERY terminal transition (complete / failed / cancelled / deleted). Best-effort and
        // idempotent — the session map entry is removed so it never fires twice.
        // Resolve the job's OWN backend lane (never `appModel.activeBackend`): a Jellyfin/Emby
        // download can reach a terminal state while the user has switched to another backend, and
        // the DELETE must hit the server the encoder actually runs on. If that lane is no longer
        // configured (signed out), skip now — the persisted `playSessionID` stays put and the launch
        // sweep retries once the lane returns.
        let releaseMetadata = store.records.first(where: { $0.ratingKey == ratingKey })?.metadata
        let embySession = appModel.backendSession(for: .emby)
        let embySessionMatchesMetadata = releaseMetadata.map { metadata in
            embySession?.matchesPersistedServer(metadata) == true
        }
        let embyPlaySessionId = embyPlaySessionByRatingKey.removeValue(forKey: ratingKey)
        switch DownloadEncoderTeardownPolicy.decision(
            backend: .emby,
            transientPlaySessionID: embyPlaySessionId,
            metadata: releaseMetadata,
            sessionAvailable: embySession != nil,
            sessionMatchesPersistedServer: embySessionMatchesMetadata
        ) {
        case .none:
            break
        case .stop(let playSessionId):
            guard let embySession else { break }
            recordDownloadDiagnostic("downloads.emby_encoder_teardown", fields: [
                "download_id": .identifier(ratingKey),
            ])
            let service = EmbyBrowseService(appModel: appModel)
            let store = self.store
            Task {
                if await service.stopActiveEncoding(playSessionId: playSessionId, session: embySession) {
                    store.clearPlaySessionID(ratingKey: ratingKey)
                }
            }
        case .skip(let reason):
            recordDownloadDiagnostic("downloads.emby_encoder_teardown_skip", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(reason),
            ])
        }

        let jellyfinSession = appModel.backendSession(for: .jellyfin)
        let jellyfinSessionMatchesMetadata = releaseMetadata.map { metadata in
            jellyfinSession?.matchesPersistedServer(metadata) == true
        }
        let jellyfinPlaySessionId = jellyfinPlaySessionByRatingKey.removeValue(forKey: ratingKey)
        switch DownloadEncoderTeardownPolicy.decision(
            backend: .jellyfin,
            transientPlaySessionID: jellyfinPlaySessionId,
            metadata: releaseMetadata,
            sessionAvailable: jellyfinSession != nil,
            sessionMatchesPersistedServer: jellyfinSessionMatchesMetadata
        ) {
        case .none:
            break
        case .stop(let playSessionId):
            guard let jellyfinSession else { break }
            recordDownloadDiagnostic("downloads.jellyfin_encoder_teardown", fields: [
                "download_id": .identifier(ratingKey),
            ])
            let service = JellyfinBrowseService(appModel: appModel)
            let store = self.store
            Task {
                if await service.stopActiveEncoding(playSessionId: playSessionId, session: jellyfinSession) {
                    store.clearPlaySessionID(ratingKey: ratingKey)
                }
            }
        case .skip(let reason):
            recordDownloadDiagnostic("downloads.jellyfin_encoder_teardown_skip", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(reason),
            ])
        }
    }

    // MARK: - D5: offline metadata + poster caching

    /// Build the persisted snapshot of a source `MediaItem` + a human resolution label.
    /// Captures only the fields the offline UI/player/retry actually read. `resolutionLabel`
    /// is descriptive ("1080p"/"4K") for the offline-library caption — it is NOT a transcode
    /// cap (the redesign downloads either the original file or a server-rendered MP4).
    static func offlineMetadata(from item: MediaItem,
                                        resolutionLabel: String?,
                                        mediaIndex: Int,
                                        partIndex: Int,
                                        optimizeTargetName: String? = nil,
                                        optimizeQueueTitle: String? = nil,
                                        session: BackendSession,
                                        mediaSourceID: String? = nil,
                                        downloadLane: DownloadLane? = nil,
                                        serverPreparedVersion: Bool = false) -> OfflineMetadata {
        let sourcePart = item.media?[safe: mediaIndex]?.part[safe: partIndex]
        let sourcePartID = sourcePart?.id
        let sourcePartSize = sourcePart?.size
        let lane = downloadLane ?? ((optimizeTargetName?.isEmpty == false) ? .optimize : .original)
        let resumeMode = DownloadResumeMode.resolved(backend: session.kind,
                                                     lane: lane,
                                                     optimizeTargetName: optimizeTargetName)
        return OfflineMetadata(ratingKey: item.ratingKey,
                               key: item.key,
                               title: item.title,
                               type: item.type,
                               year: item.year,
                               duration: item.duration,
                               viewOffset: item.viewOffset,
                               viewCount: item.viewCount,
                               summary: item.summary,
                               contentRating: item.contentRating,
                               tagline: item.tagline,
                               grandparentTitle: item.grandparentTitle,
                               grandparentRatingKey: item.grandparentRatingKey,
                               grandparentThumb: item.grandparentThumb,
                               parentTitle: item.parentTitle,
                               parentRatingKey: item.parentRatingKey,
                               parentThumb: item.parentThumb,
                               parentIndex: item.parentIndex,
                               index: item.index,
                               thumb: item.thumb,
                               art: item.art,
                               chapters: item.chapters?.map(OfflineChapter.init),
                               markers: item.markers?.map(OfflineMarker.init),
                               resolutionLabel: resolutionLabel,
                               librarySectionID: item.librarySectionID,
                               librarySectionKey: item.librarySectionKey,
                               mediaIndex: mediaIndex,
                               partIndex: partIndex,
                               sourcePartID: sourcePartID,
                               sourcePartSize: sourcePartSize,
                               optimizeTargetName: optimizeTargetName,
                               optimizeQueueTitle: optimizeQueueTitle,
                               posterRelativePath: nil,
                               // #84: per-job backend context captured at ENQUEUE from the job's own
                               // `BackendSession`, so resume/retry/cleanup never read `appModel.active*`.
                               backendKind: session.kind,
                               backendBaseURLString: session.baseURL.absoluteString,
                               backendServerID: session.serverID,
                               backendUserID: session.userID,
                               mediaSourceID: mediaSourceID,
                               playSessionID: nil,
                               downloadLane: downloadLane,
                               resumeMode: resumeMode,
                               serverPreparedVersion: serverPreparedVersion ? true : nil)
    }

    /// Human-readable resolution label for the chosen media version, for the offline-library
    /// caption only (descriptive, never a transcode cap). Derived from the media's pixel
    /// height with the common consumer-resolution buckets; falls back to "W×H" then nil.
    static func resolutionLabel(for media: Media?) -> String? {
        guard let media else { return nil }
        return DownloadResolutionLabel.label(width: media.width, height: media.height)
    }

    /// Resolution label to STORE/DISPLAY on the offline row.
    ///
    /// For a `.optimize` choice whose target encodes a resolution (the custom "720p …"/"1080p …"
    /// profiles, or the built-in server targets), this is the TARGET resolution — NOT the source.
    /// Showing the source was misleading: a "720p 4 Mbps" job against a 4K source displayed "4K",
    /// implying a 4K file the user is not getting. For DIRECT (`.original`) downloads and the
    /// "Original"/"Original Quality" optimize target (no downscale), the source resolution IS
    /// correct, so we keep it. Falls back to the source whenever the target's resolution can't be
    /// derived — we never fabricate a resolution.
    static func displayResolutionLabel(choice: DownloadChoice, chosenMedia: Media?) -> String? {
        let sourceLabel = resolutionLabel(for: chosenMedia)
        guard case .optimize(let targetName) = choice else { return sourceLabel }
        // Resolve the target's "WIDTHxHEIGHT" from the custom profile first, then the built-in
        // server target settings. A nil videoResolution means "no downscale" (Original) → source.
        let videoResolution = customDownloadProfile(named: targetName)?.settings.videoResolution
            ?? mediaSettings(forTargetName: targetName).videoResolution
        guard let videoResolution else { return sourceLabel }
        return resolutionLabel(forVideoResolution: videoResolution) ?? sourceLabel
    }

    /// Map an optimize target's `"WIDTHxHEIGHT"` videoResolution (e.g. "1280x720") to the same
    /// human bucket label as `resolutionLabel(for:)` ("4K"/"1080p"/"720p"/"480p"/"W×H"). Accepts
    /// the lowercase `x` separator the MediaSettings strings use. Returns nil for an unparseable
    /// value so the caller can fall back to the source label.
    static func resolutionLabel(forVideoResolution raw: String) -> String? {
        DownloadResolutionLabel.label(forVideoResolution: raw)
    }

    /// Bucket a raw pixel height into the same human label as `resolutionLabel(for:)`. Used to label
    /// a server-prepared/existing-version download by the CONVERTED source's real height (e.g. a 720p
    /// copy of a 4K original) rather than the item's primary-source height. Returns nil for nil input.
    static func resolutionLabel(forHeight height: Int?) -> String? {
        DownloadResolutionLabel.label(forHeight: height)
    }

    /// Whether the original source part is a good local-file download target. PMS may be able
    /// to stream/copy an MKV through HLS, but AVFoundation often cannot open that same MKV as a
    /// downloaded local file. Keep direct-original conservative and route other containers
    /// through the optimizer presets.
    static func isLocallyPlayableOriginal(part: Part?) -> Bool {
        OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
    }

    static func filePath(_ file: String, isUnder directory: String) -> Bool {
        let normalizedDirectory = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return file == normalizedDirectory || file.hasPrefix(normalizedDirectory + "/")
    }

    // #135 Stage 5c: `internal` so DownloadManager+PlexOptimize.swift can read a resolved custom
    // preset's device profile + media settings when PUTting the optimize job.
    struct CustomDownloadProfile {
        let name: String
        let deviceProfile: String
        let settings: OptimizeRequest.MediaSettings
    }

    private static let compatibleOriginalQualityName = "Original video quality"
    static let plexOriginalQualityTargetName = "Original Quality"

    private static let customDownloadProfiles: [CustomDownloadProfile] = [
        .init(name: "4K 40 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 100, maxVideoBitrateKbps: 40_000, videoResolution: "3840x2160")),
        .init(name: "1080p 20 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 100, maxVideoBitrateKbps: 20_000, videoResolution: "1920x1080")),
        .init(name: "1080p 12 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 90, maxVideoBitrateKbps: 12_000, videoResolution: "1920x1080")),
        .init(name: "1080p 10 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 75, maxVideoBitrateKbps: 10_000, videoResolution: "1920x1080")),
        .init(name: "1080p 8 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 60, maxVideoBitrateKbps: 8_000, videoResolution: "1920x1080")),
        .init(name: "720p 4 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 100, maxVideoBitrateKbps: 4_000, videoResolution: "1280x720")),
        .init(name: "720p 3 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 75, maxVideoBitrateKbps: 3_000, videoResolution: "1280x720")),
        .init(name: "720p 2 Mbps", deviceProfile: "Universal TV",
              settings: .init(videoQuality: 60, maxVideoBitrateKbps: 2_000, videoResolution: "1280x720")),
        .init(name: "480p 1.5 Mbps", deviceProfile: "Universal Mobile",
              settings: .init(videoQuality: 60, maxVideoBitrateKbps: 1_500, videoResolution: "720x480")),
    ]

    private static var customDownloadProfileNames: [String] {
        [compatibleOriginalQualityName] + customDownloadProfiles.map(\.name)
    }

    static func customDownloadProfile(named name: String) -> CustomDownloadProfile? {
        customDownloadProfiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    static func isPlexOriginalQualityTarget(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(compatibleOriginalQualityName) == .orderedSame
        || name.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(plexOriginalQualityTargetName) == .orderedSame
    }

    // #135 Stage 5c: `internal` so DownloadManager+Jellyfin.swift can read the resolved preset's
    // bitrate/dimension caps when building the transcoded-download request + size estimate.
    struct JellyfinTranscodeProfile {
        let videoBitrateBps: Int
        let maxWidth: Int?
        let maxHeight: Int?
    }

    static let jellyfinDefaultDownloadPreset = "1080p 8 Mbps"

    private static func jellyfinDownloadPreset(named name: String) -> String {
        // Jellyfin does not have Plex's server-side "Original video quality" optimize queue.
        // If a row was written with that global/default label, retry via the explicit bitrate
        // ladder so Jellyfin still produces an MP4-compatible transcoded download.
        customDownloadProfile(named: name)?.settings.maxVideoBitrateKbps == nil
            ? jellyfinDefaultDownloadPreset
            : name
    }

    static func jellyfinTranscodeProfile(named name: String) -> JellyfinTranscodeProfile {
        let settings = customDownloadProfile(named: jellyfinDownloadPreset(named: name))?.settings
        let bitrateKbps = settings?.maxVideoBitrateKbps ?? 8_000
        let resolution = settings?.videoResolution
        let dimensions = resolution?
            .lowercased()
            .split(separator: "x")
            .compactMap { Int($0) }
        let width = dimensions?.indices.contains(0) == true ? dimensions?[0] : nil
        let height = dimensions?.indices.contains(1) == true ? dimensions?[1] : nil
        return JellyfinTranscodeProfile(videoBitrateBps: bitrateKbps * 1_000,
                                        maxWidth: width,
                                        maxHeight: height)
    }

    private static func estimatedTranscodeBytes(for record: DownloadRecord) -> Int? {
        if record.metadata?.resolvedDownloadLane() == .compatibleRemux {
            // Compatible remux copies the source video and usually transcodes only audio/container,
            // so the original source part size is the closest expected-total estimate.
            if let size = record.metadata?.sourcePartSize, size > 0 { return size }
        }
        guard let targetName = record.metadata?.optimizeTargetName, !targetName.isEmpty else {
            return nil
        }
        let profile = jellyfinTranscodeProfile(named: targetName)
        // #135 Stage 1b: the pure duration × bitrate estimate lives in `TranscodeSizeEstimator`.
        return TranscodeSizeEstimator.bytes(durationMs: record.metadata?.duration,
                                            videoBitrateBps: profile.videoBitrateBps)
    }

    /// Unified download fraction for a row's bar + caption (#97), so Plex/Jellyfin/Emby
    /// all present progress the same way. Returns the EXACT `Content-Length` fraction when
    /// the server reported a size (`record.progress`), otherwise an ESTIMATED fraction
    /// (`bytes` / duration×bitrate estimate) for transcoder-streamed JF/Emby rows that ship
    /// no `Content-Length`. `nil` when neither is available (no bytes yet, or no estimate) →
    /// the caller keeps today's spinner. The estimated fraction is clamped strictly below
    /// 1.0 so the bar never reads 100% before the real `.complete` status flips the row.
    /// The selection is keyed on `record.progress`, not the backend kind, so it survives a
    /// relaunch (the in-memory `transcodeSourcedDownloads` set does not).
    public func displayFraction(for record: DownloadRecord) -> DownloadProgressDisplay.Fraction? {
        let bytes = liveDisplayBytes(for: record) ?? record.bytes
        if record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange,
           bytes > 0 {
            if let staticExpectedBytes = liveRangeProgress[record.ratingKey]?.expectedBytes ?? staticRangeExpectedBytes(for: record) {
                return DownloadProgressDisplay.Fraction(value: min(Double(bytes) / Double(staticExpectedBytes), 1.0),
                                                        isEstimated: false)
            }
            if let estimatedBytes = Self.estimatedTranscodeBytes(for: record), estimatedBytes > 0 {
                return DownloadProgressDisplay.Fraction(value: min(Double(bytes) / Double(estimatedBytes),
                                                                  DownloadProgressDisplay.estimatedCeiling),
                                                        isEstimated: true)
            }
        }
        return DownloadProgressDisplay.fraction(progress: record.progress,
                                                bytes: bytes,
                                                estimatedTotalBytes: Self.estimatedTranscodeBytes(for: record))
    }

    private func expectedDownloadBytes(for record: DownloadRecord, liveBytes: Int? = nil) -> Int? {
        if let expected = liveRangeProgress[record.ratingKey]?.expectedBytes, expected > 0 {
            return expected
        }
        let bytes = liveBytes ?? record.bytes
        if record.progress > 0, bytes > 0 {
            return Int(Double(bytes) / record.progress)
        }
        if let staticExpectedBytes = staticRangeExpectedBytes(for: record) {
            return staticExpectedBytes
        }
        return Self.estimatedTranscodeBytes(for: record)
    }

    private func liveDisplayBytes(for record: DownloadRecord, now: Date = Date()) -> Int? {
        DownloadLiveRangeProgressPolicy.liveDisplayBytes(
            for: record,
            sample: liveRangeProgress[record.ratingKey],
            now: now,
            isCheckpointPausing: staticRangeRecovery.isCheckpointPausing(record.ratingKey))
    }

    private func staticRangeExpectedBytes(for record: DownloadRecord) -> Int? {
        guard record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange,
              let sourcePartSize = record.metadata?.sourcePartSize,
              sourcePartSize > 0 else { return nil }
        return sourcePartSize
    }

    private func makeOfflineLibrarySnapshot(from records: [DownloadRecord]) -> OfflineLibrarySnapshot {
        OfflineLibrarySnapshotBuilder.make(
            records: records,
            isQueuePaused: isQueuePaused,
            downloadSpeed: downloadSpeed,
            backendKind: { record in backendKind(for: record) },
            errorMessage: { record in
                guard record.status == .failed else { return nil }
                return lastError[record.ratingKey].map(message(for:))
            },
            displayProgress: { record in rowDisplayProgress(for: record) },
            statusCaption: { record, backend in statusCaption(for: record, backend: backend) },
            isRetrying: { ratingKey in retryPresentationRows.contains(ratingKey) },
            isCheckpointPausing: { ratingKey in staticRangeRecovery.isCheckpointPausing(ratingKey) }
        )
    }


    private func rowDisplayProgress(for record: DownloadRecord) -> Double? {
        if record.bytes == 0,
           record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .serverPrepThenStatic,
           let prep = optimizeProgress[record.ratingKey] {
            return max(0, min(prep, 0.999))
        }
        return displayFraction(for: record)?.value
    }

    /// Backend that owns this row, via the single migration fallback on the
    /// persisted snapshot (#84): a stored `backendKind` wins; pre-#84 rows fall
    /// back to the ratingKey prefix. Kept in the manager's UI snapshot so the
    /// hot Offline row bodies don't repeatedly re-scan all records or manager state.
    private func backendKind(for record: DownloadRecord) -> DownloadBackendKind {
        record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
    }

    private func statusCaption(for record: DownloadRecord, backend: DownloadBackendKind) -> String {
        let isCheckpointPausing = staticRangeRecovery.isCheckpointPausing(record.ratingKey)
        let isActive = activeJobs.contains(record.ratingKey) || record.status == .downloading || isCheckpointPausing
        let failureCaption = record.status == .failed ? lastError[record.ratingKey].map(message(for:)) : nil
        return DownloadRowStatusCaptionPolicy.caption(.init(
            status: record.status,
            progress: record.progress,
            bytes: record.bytes,
            lane: record.metadata?.resolvedDownloadLane() ?? .original,
            backend: backend,
            resumeMode: record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey),
            isServerPreparedVersion: record.metadata?.isServerPreparedVersion == true,
            resolutionLabel: record.metadata?.resolutionLabel,
            displayFraction: displayFraction(for: record),
            isActive: isActive,
            isCheckpointPausing: isCheckpointPausing,
            isBackendConfigured: isBackendConfigured(for: record),
            isTranscodeLimited: Self.isDownloadTranscodeLimited(record),
            serverPrepState: optimizeState[record.ratingKey],
            serverPrepProgress: optimizeProgress[record.ratingKey],
            serverPrepETA: optimizeETA[record.ratingKey],
            downloadETA: downloadETA[record.ratingKey],
            downloadSpeedBytesPerSecond: downloadSpeed[record.ratingKey],
            hasServerPrepQueueTitle: record.metadata?.optimizeQueueTitle?.isEmpty == false,
            isRetrying: retryPresentationRows.contains(record.ratingKey),
            failureCaption: failureCaption
        ))
    }

    /// User-facing copy for failed rows. Pure phase/caption composition lives in PMSKit; the app
    /// still maps local error cases here because `DownloadError` is an app-layer coordinator type.
    private func message(for error: DownloadError) -> String {
        switch error {
        case .notAuthenticated:        return "Sign in to download."
        case .optimizeFailed(let m):   return "Optimize failed: \(m)"
        case .optimizeTimedOut:        return "Optimize timed out on the server."
        case .noOptimizedPart:         return "No optimized version was produced."
        case .storageFull:             return "Not enough free space."
        case .storageLimitExceeded(let m): return m
        case .transferFailed(let m):   return "Download failed: \(m)"
        case .invalidDownload(let m):  return "Download invalid: \(m)"
        case .interruptedResumable:    return "Download paused — tap Resume to continue."
        }
    }

    static func jellyfinMediaSourceID(media: Media?, part: Part?) -> String? {
        let keys = [part?.key] + (media?.part.map(\.key) ?? [])
        for key in keys.compactMap({ $0 }) {
            guard let marker = key.range(of: "/media/") else { continue }
            let source = String(key[marker.upperBound...])
            if !source.isEmpty { return source }
        }
        return nil
    }

    static func jellyfinTranscodedDownloadRequest(_ server: URL,
                                                          _ token: String,
                                                          _ identity: JellyfinClientIdentity,
                                                          _ itemId: String,
                                                          _ mediaSourceId: String?,
                                                          _ playSessionId: String,
                                                          _ profile: JellyfinTranscodeProfile) -> URLRequest {
        let base = server.appendingPathComponent("/Videos/\(itemId)/stream.mp4")
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "container", value: "mp4"),
            URLQueryItem(name: "videoCodec", value: "h264"),
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "videoBitRate", value: String(profile.videoBitrateBps)),
            URLQueryItem(name: "audioBitRate", value: "192000"),
            URLQueryItem(name: "maxAudioChannels", value: "6"),
            URLQueryItem(name: "allowVideoStreamCopy", value: "false"),
            URLQueryItem(name: "allowAudioStreamCopy", value: "false"),
            URLQueryItem(name: "enableAutoStreamCopy", value: "false"),
            URLQueryItem(name: "breakOnNonKeyFrames", value: "false"),
            URLQueryItem(name: "deviceId", value: identity.deviceId),
            URLQueryItem(name: "playSessionId", value: playSessionId),
        ]
        if let mediaSourceId, !mediaSourceId.isEmpty {
            query.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceId))
        }
        if let maxWidth = profile.maxWidth {
            query.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        if let maxHeight = profile.maxHeight {
            query.append(URLQueryItem(name: "maxHeight", value: String(maxHeight)))
        }
        comps.queryItems = query
        let url = comps.url!
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(JellyfinAuth.authorizationHeader(identity: identity, token: token),
                         forHTTPHeaderField: "Authorization")
        return request
    }

    private static func dedup(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
    }

    /// Conventional Plex target tag ids (fallback only — the live server's ids win when the
    /// targets endpoint resolves them). Phase 0 confirms the real ids.
    static func conventionalTagID(forName name: String) -> Int {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "optimized for mobile": return 1
        case "original quality", "original video quality": return 3
        default: return 2   // "Optimized for TV"
        }
    }

    /// Best-known render settings per preset name (fallback caps; the server preset governs).
    static func mediaSettings(forTargetName name: String) -> OptimizeRequest.MediaSettings {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "optimized for mobile":
            return .init(videoQuality: 100, maxVideoBitrateKbps: 2000, videoResolution: "1280x720")
        case "original quality", "original video quality":
            return .init(videoQuality: 100, maxVideoBitrateKbps: nil, videoResolution: nil)
        default:
            return .init(videoQuality: 100, maxVideoBitrateKbps: 8000, videoResolution: "1920x1080")
        }
    }

    // MARK: - Poll for optimized part

    /// Poll the item's metadata until an optimized (extra) `Part` shows up.
    ///
    /// Heuristic: the optimized version appears as an additional `Media`/`Part`
    /// alongside the original. We snapshot the original part ids first, then poll;
    /// the first part whose id is NOT in that original set is the optimized output.
    /// If the item had no media at all, we take the highest-id new part.
    func pollForOptimizedPart(ratingKey: String,
                                      originalPartIDs: Set<Int>,
                                      targetName: String,
                                      sourceHeight: Int?,
                                      backgroundProcessingKey: String?,
                                      queueTitle: String?,
                                      mediaTitle: String,
                                      server: URL,
                                      token: String,
                                      identity: ClientIdentity) async throws -> Part {
        while !Task.isCancelled {
            if let metadata = await fetchCurrentMediaItem(ratingKey: ratingKey, server: server,
                                                          token: token, identity: identity) {
                if let newPart = Self.optimizedDownloadCandidate(from: metadata.media ?? [],
                                                                 baselinePartIDs: originalPartIDs,
                                                                 targetName: targetName,
                                                                 sourceHeight: sourceHeight) {
                    clearOptimizeProgress(ratingKey: ratingKey)
                    return newPart
                }
            }
            // Surface server-side optimize/transcode progress for the "Preparing on
            // server…" caption. Best-effort: failures or no-match leave the existing
            // behavior untouched.
            // Do not use the historical sole-optimizer fallback here. Live PMS can run several
            // background transcodes while `/activities` exposes only one `media.download` entry,
            // so "one VisionPlay active job" is not enough to prove that lone activity belongs
            // to us. `recordServerQueueProbe` below reads `/status/sessions/background`, whose
            // per-job `ratingKey` is the safer progress source under concurrency.
            await pollOptimizeActivity(ratingKey: ratingKey, mediaTitle: mediaTitle,
                                       allowSoleFallback: false,
                                       server: server, token: token, identity: identity)
            // Disambiguation probe: distinguish "completed-item clutter" (inert) from a genuinely
            // stalled or idle-paused server conversion queue. Privacy-safe COUNTS + short state
            // tokens only — never a media title/path/URL.
            await recordServerQueueProbe(ratingKey: ratingKey, mediaTitle: mediaTitle, server: server,
                                         token: token, identity: identity)
            if let backgroundProcessingKey,
               let queueTitle,
               let status = await optimizerQueueStatus(backgroundProcessingKey: backgroundProcessingKey,
                                                       queueTitle: queueTitle, server: server,
                                                       token: token, identity: identity),
               status.isFailed {
                downloadLog.error("optimizer-failed failed=\(status.itemsFailedCount ?? -1, privacy: .public) successful=\(status.itemsSuccessfulCount ?? -1, privacy: .public)")
                recordDownloadDiagnostic("downloads.optimize_status_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "failed_count": .int(status.itemsFailedCount ?? -1),
                    "successful_count": .int(status.itemsSuccessfulCount ?? -1),
                ])
                throw DownloadError.optimizeFailed("Plex server could not create an optimized version; optimized-version storage may be read-only.")
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(optimizePollInterval * 1_000_000_000))
            } catch {
                throw error
            }
        }
        throw CancellationError()
    }

    /// Pick only a NEW Plex server-optimized output that the local/offline player can open.
    ///
    /// GH #135 Stage 1a: the bounding-box / bitrate matching now lives in the pure, unit-tested
    /// `OptimizedVersionMatch`. This thin shim keeps the app-side target-name → settings resolution
    /// and injects the already-resolved tier into the matcher.
    private static func optimizedDownloadCandidate(from media: [Media],
                                                   baselinePartIDs: Set<Int>,
                                                   targetName: String,
                                                   sourceHeight: Int?) -> Part? {
        let settings = customDownloadProfile(named: targetName)?.settings ?? mediaSettings(forTargetName: targetName)
        let targetDimensions = settings.videoResolution
            .flatMap(DownloadResolutionLabel.dimensions(forVideoResolution:))
        return OptimizedVersionMatch.candidate(
            from: media,
            baselinePartIDs: baselinePartIDs,
            targetDimensions: targetDimensions,
            targetVideoKbps: settings.maxVideoBitrateKbps,
            isOriginalQuality: isPlexOriginalQualityTarget(targetName),
            sourceHeight: sourceHeight)
    }

    func fetchCurrentMediaItem(ratingKey: String, server: URL, token: String,
                                       identity: ClientIdentity) async -> MediaItem? {
        // Use the full detail shape, not the lean optimize status shape, so any offline
        // snapshot refreshed from this item carries chapters and part/stream metadata.
        // Optimized downloads need that source metadata just as much as original downloads:
        // the optimized MP4 itself is downloaded later, but chapters and external text
        // subtitles come from the source item.
        let req = PlexRequest(url: server.appendingPathComponent("/library/metadata/\(ratingKey)"),
                              method: "GET",
                              queryItems: [
                                  .init(name: "includeChapters", value: "1"),
                                  .init(name: "includeMarkers", value: "1"),
                                  .init(name: "includeExtras", value: "1"),
                              ],
                              headers: PlexHeaders.standard(identity: identity, token: token))
        return (try? await appModel.client.send(req, as: MetadataResponse.self))?
            .mediaContainer.metadata.first
    }


    func bgKeyForPolling(server: URL, token: String, identity: ClientIdentity) async -> String? {
        guard let pl = try? await appModel.client.send(
            OptimizeRequest.backgroundProcessingRequest(server: server, token: token, identity: identity),
            as: BackgroundProcessingPlaylist.self)
        else { return nil }
        return pl.key
    }

    private struct OptimizerQueueResponse: Decodable {
        struct Container: Decodable {
            let item: [Item]
            enum CodingKeys: String, CodingKey { case item = "Item" }
        }
        struct Item: Decodable {
            let title: String?
            let status: Status?
            enum CodingKeys: String, CodingKey { case title; case status = "Status" }
        }
        struct Status: Decodable {
            let itemsSuccessfulCount: Int?
            let itemsFailedCount: Int?
            let state: String?
            var isFailed: Bool {
                (itemsFailedCount ?? 0) > 0 && (itemsSuccessfulCount ?? 0) == 0
                    && state?.lowercased() == "complete"
            }
        }
        let mediaContainer: Container
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    }

    private func optimizerQueueStatus(backgroundProcessingKey: String, queueTitle: String,
                                      server: URL, token: String,
                                      identity: ClientIdentity) async -> OptimizerQueueResponse.Status? {
        let trimmed = backgroundProcessingKey.hasPrefix("/")
            ? String(backgroundProcessingKey.dropFirst()) : backgroundProcessingKey
        let req = PlexRequest(url: server.appendingPathComponent(trimmed), method: "GET",
                              queryItems: [],
                              headers: PlexHeaders.standard(identity: identity, token: token))
        guard let response = try? await appModel.client.send(req, as: OptimizerQueueResponse.self)
        else { return nil }
        return response.mediaContainer.item.last(where: { $0.title == queueTitle })?.status
    }

    // MARK: - Server-side optimize progress (GET /activities)

    /// Fetch `GET /activities`, correlate the matching optimize activity to this job, and
    /// publish `optimizeProgress`/`optimizeETA`/`optimizeState`. Best-effort: a request
    /// failure or absent match leaves the current state untouched (graceful fallback).
    ///
    /// PRIVACY: media titles in `Activity.title`/`subtitle` are matched in memory ONLY and
    /// never logged. We emit a single redaction-safe shape probe per poll (structural facts
    /// + numeric progress only) so the real PMS shape can be confirmed from logs.
    private func pollOptimizeActivity(ratingKey: String, mediaTitle: String,
                                      allowSoleFallback: Bool,
                                      server: URL, token: String,
                                      identity: ClientIdentity) async {
        let req = ActivitiesRequest.list(server: server, token: token, identity: identity)
        guard let activities = try? await appModel.client.send(req, as: Activities.self) else {
            return
        }

        // PROBE: redaction-safe shape of the raw /activities decode for live validation.
        // `probeShape` emits ONLY counts / field-presence flags / dotted types / numeric
        // progress — never a title/subtitle VALUE. The "types" string is a list of dotted
        // activity types (e.g. "media.optimize,library.update.section"), which are
        // server-vocabulary identifiers, not media titles, and pass through unredacted.
        let shape = activities.probeShape(ratingKey: ratingKey, title: mediaTitle,
                                          allowSoleFallback: allowSoleFallback)
        var probeFields: [String: DiagnosticFieldValue] = [
            "download_id": .identifier(ratingKey),
            "activity_count": .int(Int(shape["activity_count"] ?? "0") ?? 0),
            "optimize_count": .int(Int(shape["optimize_count"] ?? "0") ?? 0),
            "matched": .label(shape["matched"]),
            // Dotted activity-type vocabulary (NOT media titles); aids shape confirmation.
            "activity_types": .label(shape["types"]),
        ]
        // NOTE: the diagnostic redactor auto-omits any field whose KEY contains "title".
        // The presence flags below carry only "1"/"0"/"nil" (never a title value), so we
        // map the title/subtitle presence flags to redactor-safe key names to keep the
        // boolean visible — the VALUE is structural, not a media title.
        let probeKeyRemap: [String: String] = [
            "match_has_title": "match_has_name",
            "match_has_subtitle": "match_has_subname",
        ]
        for k in ["match_progress", "match_has_uuid", "match_has_context_ratingkey",
                  "match_has_metadata_id", "match_correlation_equal",
                  "match_has_title", "match_has_subtitle", "match_cancellable"] {
            if let v = shape[k] { probeFields[probeKeyRemap[k] ?? k] = .label(v) }
        }
        recordDownloadDiagnostic("downloads.optimize_activity_probe", fields: probeFields)

        guard let activity = activities.optimizeActivity(ratingKey: ratingKey,
                                                         title: mediaTitle,
                                                         allowSoleFallback: allowSoleFallback) else {
            return
        }

        // progress is 0…100, or -1 indeterminate. -1 / missing → "queued" (job seen but no
        // measurable progress yet); a real percent → "transcoding".
        guard let pct = activity.progress, pct >= 0 else {
            optimizeState[ratingKey] = DownloadOptimizeStateLabel.queued
            optimizeProgress[ratingKey] = nil
            optimizeETA[ratingKey] = nil
            refreshRecords()
            return
        }
        let p = min(1.0, Double(pct) / 100.0)
        optimizeProgress[ratingKey] = p
        optimizeState[ratingKey] = p >= 1.0
            ? DownloadOptimizeStateLabel.finalizing
            : DownloadOptimizeStateLabel.transcoding
        if p >= 1.0 { optimizeETA[ratingKey] = nil }
        updateOptimizeETA(ratingKey: ratingKey, progress: p)
        refreshRecords()
    }

    /// Fold the moving optimize percent into an EMA (same 0.75/0.25 weights as the transfer
    /// speed EMA) to derive a smooth `~N min left`. Suppress the ETA when the instantaneous
    /// rate is non-positive (progress stalled or went backwards) or implausibly large.
    func updateOptimizeETA(ratingKey: String, progress p: Double) {
        let now = Date()
        guard let prev = optimizeProgressSamples[ratingKey] else {
            optimizeProgressSamples[ratingKey] = (p, now)
            return
        }
        let dt = now.timeIntervalSince(prev.time)
        let dp = p - prev.p
        // Resample on a ≥1s window for a less-noisy instantaneous rate; require forward
        // progress. (Matches the transfer-speed EMA cadence in refreshRecords.)
        guard dt >= 1.0, dp > 0 else {
            if p >= 1.0 { optimizeETA[ratingKey] = 0 }
            return
        }
        let instantaneous = dp / dt   // fraction per second
        let smoothed = optimizeRate[ratingKey].map { 0.75 * $0 + 0.25 * instantaneous }
            ?? instantaneous
        optimizeRate[ratingKey] = smoothed
        optimizeProgressSamples[ratingKey] = (p, now)
        if smoothed > 0 {
            let eta = (1.0 - p) / smoothed
            // Only surface a plausible estimate (< 12h); otherwise suppress (too noisy).
            optimizeETA[ratingKey] = (eta.isFinite && eta < 60 * 60 * 12) ? eta : nil
        }
    }

    /// PREFERRED transcode-ETA estimate from the server-reported realtime `speed` multiplier.
    ///
    /// `remaining_video_seconds = duration_sec × (1 − progress/100)`, then
    /// `transcode_remaining = remaining_video_seconds / speed`. The media duration (ms) is read
    /// from the persisted offline-metadata snapshot for this ratingKey. Returns `nil` (so the
    /// caller leaves the EMA estimate in place) when the duration is unknown, the inputs are
    /// degenerate, or the estimate is implausible (>12h) — same suppression as `updateOptimizeETA`.
    private func speedBasedTranscodeETA(ratingKey: String, progressPercent pct: Int,
                                        speed: Double) -> TimeInterval? {
        guard speed > 0, pct >= 0, pct < 100,
              // Prefer the already-published snapshot, but fall back to the store in case this
              // probe races a refresh during optimize resume/retry. Without a duration the
              // server-speed estimate cannot be converted into wall-clock seconds; the progress
              // EMA below still covers subsequent polls.
              let durationMs = (records.first(where: { $0.ratingKey == ratingKey })
                    ?? store.records.first(where: { $0.ratingKey == ratingKey }))?
                    .metadata?.duration,
              durationMs > 0 else { return nil }
        let durationSec = Double(durationMs) / 1000.0
        let remainingVideoSeconds = durationSec * (1.0 - Double(pct) / 100.0)
        let eta = remainingVideoSeconds / speed
        guard eta.isFinite, eta > 0, eta < 60 * 60 * 12 else { return nil }
        return eta
    }

    /// Drop all server-optimize progress state for a ratingKey (part found / job ended).
    /// Mirrors the `downloadSpeed` prune idiom in `refreshRecords`.
    func clearOptimizeProgress(ratingKey: String) {
        optimizeProgress[ratingKey] = nil
        optimizeETA[ratingKey] = nil
        optimizeState[ratingKey] = nil
        optimizeProgressSamples[ratingKey] = nil
        optimizeRate[ratingKey] = nil
    }

    func markServerPrepFinalizing(ratingKey: String) {
        optimizeProgress[ratingKey] = 1.0
        optimizeETA[ratingKey] = nil
        optimizeState[ratingKey] = DownloadOptimizeStateLabel.finalizing
    }

    // MARK: - Server conversion queue probe

    /// Disambiguation probe (server-side conversion-queue health). Emits `downloads.optimize_server_probe`
    /// with PRIVACY-SAFE counts / numeric progress / short state tokens only — NEVER a media
    /// title/path/URL. Lets us tell completed-`Optimized`-item clutter (inert) apart from a
    /// stalled or idle-paused background queue, by reading the SEPARATE conversion machinery the
    /// type-42 registry doesn't expose. Each of the three GETs is independent + best-effort: a
    /// failure on one omits only its fields and never fails the download.
    private func recordServerQueueProbe(ratingKey: String, mediaTitle: String, server: URL, token: String,
                                        identity: ClientIdentity) async {
        var fields: [String: DiagnosticFieldValue] = ["download_id": .identifier(ratingKey)]

        // 1. /playQueues/1 → ordered conversion queue (Conversion). This tells us whether this
        //    row is still in the optimize queue, but it is NOT a complete active-job signal:
        //    live PMS can run several optimizations concurrently while playQueues/1 exposes only
        //    one selected item. Use /status/sessions/background below for per-job attribution.
        var thisIsQueuedConversion = false
        var thisIsActiveConversion = false
        if let queue = try? await appModel.client.send(
            BackgroundQueueRequest.conversionQueueRequest(server: server, token: token, identity: identity),
            as: ConversionQueue.self) {
            fields["conversion_count"] = .int(queue.count)
            fields["active_conversion_present"] = .bool(queue.hasActiveConversion)
            let inQueue = queue.items.contains { $0.ratingKey == ratingKey }
            fields["conversion_contains_rk"] = .bool(inQueue)
            if let selected = queue.activeItem?.ratingKey {
                let selectedMatches = selected == ratingKey
                // Historical/diagnostic only: this may be ONE selected conversion, not the full
                // set of active conversions. Do not use it to decide this row is inactive.
                fields["selected_rk_match"] = .bool(selectedMatches)
                thisIsActiveConversion = selectedMatches
            }
            thisIsQueuedConversion = inQueue
        }

        // 2. /status/sessions/background → running/paused optimization jobs (TranscodeJob).
        if let jobs = try? await appModel.client.send(
            BackgroundQueueRequest.transcodeJobsRequest(server: server, token: token, identity: identity),
            as: BackgroundTranscodeJobs.self) {
            fields["bg_job_count"] = .int(jobs.jobs.count)
            let matchingJob = jobs.job(ratingKey: ratingKey)
            let matchingTitleJob = jobs.uniqueJob(title: mediaTitle)
            let attributedJob: BackgroundTranscodeJobs.Job? = matchingJob
                // PMS shapes that omit per-job ratingKey may still carry a title/subtitle. Use it
                // only when it uniquely identifies this media among running background jobs; the
                // title value stays in memory and is never logged.
                ?? matchingTitleJob
                // If Plex's conversion queue says THIS item is the active conversion, then a single
                // background transcode job is attributable even while another backend (e.g. Emby) is
                // also active in VisionPlay. This is the live Devil Wears Prada shape: the background
                // job has progress/speed but no per-job ratingKey.
                ?? ((jobs.jobs.count == 1 && thisIsActiveConversion) ? jobs.jobs.first : nil)
                // Legacy fallback for older PMS shapes without per-job ratingKey/title/queue active
                // attribution: if there is exactly one background job and exactly one active
                // VisionPlay download, it is unambiguous. Never use first-job fallback when PMS
                // reports multiple jobs.
                ?? ((jobs.jobs.count == 1 && activeJobs.count == 1) ? jobs.jobs.first : nil)
            let isActiveConversion = attributedJob != nil
            if matchingJob != nil { fields["bg_rk_match"] = .bool(true) }
            if matchingTitleJob != nil { fields["bg_name_match"] = .bool(true) }
            if let p = attributedJob?.progress { fields["bg_progress"] = .int(p) }
            // `state` is a queued/running/paused-style vocabulary token, not a media title.
            if let s = attributedJob?.state { fields["bg_state"] = .label(s) }
            // Server-reported realtime multiplier (a number, never a title) — preferred ETA source.
            if let speed = attributedJob?.speed { fields["bg_speed"] = .double(speed) }
            fields["bg_attributed"] = .label(isActiveConversion ? "active"
                                             : (thisIsQueuedConversion ? "queued" : "none"))

            if isActiveConversion {
                // FROZEN-% FIX: the UI's "Transcoding NN%" reads `optimizeProgress`, normally set by
                // `pollOptimizeActivity` matching the `/activities` feed. Under concurrent/ambiguous
                // jobs that match returns none and the value FREEZES. The server's own `bg_progress`
                // (here) keeps climbing, so feed it into the SAME store — last-write-wins with the
                // activity match. Also feed the same background progress into the ETA EMA: the
                // activity feed can expose only one optimize activity even while PMS runs several
                // background transcoders, so a row could show "Transcoding 7%" from this endpoint
                // but never get a time estimate if ETA sampling stayed activity-only.
                var didUpdateProgressState = false
                if let pct = attributedJob?.progress, pct >= 0, pct <= 100 {
                    let bgFraction = min(1.0, Double(pct) / 100.0)
                    updateOptimizeETA(ratingKey: ratingKey, progress: bgFraction)
                    // Monotonic for display: never let it visibly step backward (prefer the
                    // larger), so a brief disagreement with the activity match can't jitter the bar.
                    optimizeProgress[ratingKey] = max(bgFraction, optimizeProgress[ratingKey] ?? 0)
                    optimizeState[ratingKey] = bgFraction >= 1.0
                        ? DownloadOptimizeStateLabel.finalizing
                        : DownloadOptimizeStateLabel.transcoding
                    didUpdateProgressState = true
                }

                // PREFERRED transcode-ETA source: remaining_video_seconds / speed (steadier than
                // the progress-rate EMA), written into the SINGLE published `optimizeETA` store —
                // superseding the EMA set above/earlier this poll by `pollOptimizeActivity` (last
                // write wins), falling back to the EMA when the server reports no usable speed.
                if let speed = attributedJob?.speed, speed > 0,
                   let pct = attributedJob?.progress, pct >= 0, pct < 100,
                   let etaSeconds = speedBasedTranscodeETA(ratingKey: ratingKey,
                                                           progressPercent: pct, speed: speed) {
                    optimizeETA[ratingKey] = etaSeconds
                    fields["bg_speed_eta_sec"] = .int(Int(etaSeconds))
                    didUpdateProgressState = true
                }
                if didUpdateProgressState { refreshRecords() }
            } else if thisIsQueuedConversion {
                // Waiting behind the active conversion, with no measurable progress yet. Keep the
                // public caption flattened to "Preparing on server…" for a stable user-facing phase,
                // but remember the coarse queued state so a real % is never clobbered if the row
                // briefly drops out of the active slot.
                if optimizeProgress[ratingKey] == nil {
                    optimizeState[ratingKey] = DownloadOptimizeStateLabel.queued
                    refreshRecords()
                }
            }
        }

        // 3. /:/prefs → BackgroundQueueIdlePaused (the gate on whether the queue runs at all).
        if let prefs = try? await appModel.client.send(
            BackgroundQueueRequest.prefsRequest(server: server, token: token, identity: identity),
            as: ServerPrefs.self),
           let paused = prefs.backgroundQueueIdlePaused {
            fields["idle_paused"] = .bool(paused)
        }

        recordDownloadDiagnostic("downloads.optimize_server_probe", fields: fields)
    }

}

// #135 Stage 5c: `internal` (not `private`) so DownloadManager+PlexOptimize.swift can percent-encode
// metadata keys when building the optimize `library://…/item/…` source URI.
extension String {
    var urlQueryEscapedForPlexPath: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}
