import Foundation
import Observation
import PMSKit

/// Pure exact-attempt state machine for local playback revalidation. Wall-clock tasks live in the
/// manager; this type only issues/validates opaque timer tokens, so every overtaking order is
/// deterministic in tests.
struct UnverifiedRevalidationCoordinator: Sendable {
    enum Retry: Sendable, Equatable { case soon, delayed }

    private(set) var inFlight: Set<DownloadAttemptKey> = []
    private(set) var desired: Set<DownloadAttemptKey> = []
    private(set) var timerTokens: [DownloadAttemptKey: UUID] = [:]
    private(set) var requestIDs: [DownloadAttemptKey: UUID] = [:]
    private var automaticRetryCounts: [DownloadAttemptKey: Int] = [:]

    mutating func begin(_ key: DownloadAttemptKey, preservesOvertakenRequest: Bool) -> Bool {
        guard !inFlight.contains(key) else {
            if preservesOvertakenRequest { desired.insert(key) }
            return false
        }
        inFlight.insert(key)
        return true
    }

    mutating func started(_ key: DownloadAttemptKey, requestID: UUID) -> UUID {
        desired.remove(key)
        requestIDs[key] = requestID
        return armTimer(for: key)
    }

    mutating func deferred(_ key: DownloadAttemptKey, requestID: UUID? = nil) {
        if let requestID, requestIDs[key] != requestID { return }
        inFlight.remove(key)
        desired.insert(key)
        timerTokens.removeValue(forKey: key)
    }

    mutating func alreadyFinalizing(_ key: DownloadAttemptKey) { deferred(key) }

    mutating func unavailable(_ key: DownloadAttemptKey) -> Retry? {
        inFlight.remove(key)
        timerTokens.removeValue(forKey: key)
        return desired.contains(key) ? .soon : nil
    }

    @discardableResult
    mutating func gateDrained(
        _ keys: Set<DownloadAttemptKey>, sceneIsActive: Bool
    ) -> Bool {
        inFlight.subtract(keys)
        desired.formUnion(keys)
        for key in keys {
            timerTokens.removeValue(forKey: key)
            automaticRetryCounts[key] = 0
        }
        return sceneIsActive && !keys.isEmpty
    }

    mutating func parkUntilActive(_ keys: Set<DownloadAttemptKey>) {
        inFlight.subtract(keys)
        desired.formUnion(keys)
        for key in keys { timerTokens.removeValue(forKey: key) }
    }

    /// Park every request generation that still owns a session finalizer claim. A watchdog may
    /// have moved a long limiter wait from `inFlight` to `desired`, so `requestIDs`—not merely the
    /// admission set—is the authority for foreground work that must be cancelled on deactivation.
    mutating func parkRunningRequestsUntilActive() -> Set<DownloadAttemptKey> {
        let keys = Set(requestIDs.keys)
        parkUntilActive(keys)
        return keys
    }

    mutating func permitRetry(_ key: DownloadAttemptKey, sceneIsActive: Bool) -> Bool {
        guard sceneIsActive else {
            parkUntilActive([key])
            return false
        }
        return true
    }

    mutating func finished(
        _ key: DownloadAttemptKey, requestID: UUID, cancelled: Bool,
        remainsUnverified: Bool
    ) -> Retry? {
        guard requestIDs[key] == requestID else { return nil }
        requestIDs.removeValue(forKey: key)
        let ownedClaim = inFlight.remove(key) != nil
        let hadDesiredEdge = desired.contains(key)
        timerTokens.removeValue(forKey: key)
        guard ownedClaim || hadDesiredEdge else { return nil }
        guard remainsUnverified else {
            desired.remove(key)
            automaticRetryCounts.removeValue(forKey: key)
            return nil
        }
        if cancelled || desired.remove(key) != nil { return .soon }
        guard automaticRetryCounts[key, default: 0] < 1 else { return nil }
        automaticRetryCounts[key, default: 0] += 1
        return .delayed
    }

    mutating func armTimer(for key: DownloadAttemptKey) -> UUID {
        let token = UUID()
        timerTokens[key] = token
        return token
    }

    mutating func timerFired(
        for key: DownloadAttemptKey, token: UUID, remainsUnverified: Bool
    ) -> Bool {
        guard timerTokens[key] == token else { return false }
        timerTokens.removeValue(forKey: key)
        guard remainsUnverified else {
            inFlight.remove(key)
            desired.remove(key)
            automaticRetryCounts.removeValue(forKey: key)
            requestIDs.removeValue(forKey: key)
            return false
        }
        if inFlight.remove(key) != nil { desired.insert(key) }
        return true
    }

    mutating func resetAutomaticRetryBudget(_ keys: Set<DownloadAttemptKey>) {
        for key in keys { automaticRetryCounts[key] = 0 }
    }
}
import AVFoundation   // D1: AVURLAsset playability probe on a finished download
import os

/// Diagnostic log for the offline-download pipeline. Inspect with:
///   log show --predicate 'subsystem == "com.jlipworth.Labstream"' --last 10m
/// Only scrubbed values are logged — never the token or full URL (the transcode
/// URL carries `X-Plex-Token` as a query param), so we log `url.path` only.
let downloadLog = Logger(subsystem: "com.jlipworth.Labstream", category: "Downloads")

enum DownloadOptimizeStateLabel {
    static let queued = "queued"
    static let transcoding = "transcoding"
    static let finalizing = "finalizing"
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

    #if DEBUG && os(tvOS)
    /// Independent UI-test evidence that tvOS composition did not instantiate the download
    /// subsystem. This counter is intentionally owned by the subsystem under test rather than
    /// by the app's launch-argument plumbing, so an accidental tvOS construction makes the
    /// streaming-only launch assertion fail.
    private(set) static var debugConstructionCount = 0
    #endif

    public enum StartupRecoveryState: Sendable, Equatable {
        case preparing
        case ready
        case blocked(message: String)
    }

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

    /// Compatibility alias for older app call sites (`DownloadManager.DownloadChoice`). The actual
    /// user intent model lives in PMSKit so route planners, storage estimates, diagnostics, and
    /// tests share one definition.
    public typealias DownloadChoice = DownloadIntentChoice

    /// Internal control-flow error for async server-prep work that outlived the row it belonged to.
    ///
    /// Deleting/retrying a server-prep row removes the visible row and can immediately enqueue a
    /// replacement with a new attempt identity. The old async poller is not a URLSession task, so it
    /// may wake up later after the server has produced a file. Treat that as a no-op, not as a
    /// user-visible failure, and never let it overwrite the newer row or start a duplicate transfer.
    enum DownloadLifecycleCancellation: Error {
        case staleOptimizeAttempt
        /// A-1 (audit lens 8): the Plex lane signed out or was re-pointed at a different server
        /// while the server-prep poller was mid-render. Not a failure — the row is parked for
        /// deferred resume and the prep scanner reattaches once the matching session returns.
        case plexSessionUnavailable
    }

    /// Live records (in-progress + completed), backed by `DownloadStore`.
    public private(set) var records: [DownloadRecord] = []
    /// Fail-closed schema/task admission state. The message is fixed application text: no paths,
    /// tokens, persistence error descriptions, or server values are exposed to UI/diagnostics.
    public private(set) var startupRecoveryState: StartupRecoveryState = .preparing
    @ObservationIgnored private var startupRecoveryInFlight = false
    @ObservationIgnored private var didRunInitialStartupReattach = false
    @ObservationIgnored private var startupRecoveryErrorKeys: Set<String> = []
    @ObservationIgnored private var startupRecoveryRetryTask: Task<Void, Never>?
    @ObservationIgnored private var startupRecoveryRetryCount = 0
    /// Short-lived worker for ordinary episode rows carrying the durable one-time planner marker.
    /// No season/batch entity is retained; relaunch simply rediscovers marked rows.
    @ObservationIgnored var seasonPlannerAdmissionTask: Task<Void, Never>?
    @ObservationIgnored var seasonPlannerAdmittingKeys: Set<String> = []

    /// Coarse, pre-derived UI state for `OfflineLibraryView`.
    ///
    /// Rows used to read `records`, progress dictionaries, ETA dictionaries, active jobs, and
    /// errors directly from SwiftUI. Under Observation that makes every progress tick invalidate a
    /// broad part of the list. Keep the hot derived strings/fractions in one snapshot so the view
    /// observes a single value and row bodies stay manager-free.
    var offlineLibrarySnapshot: OfflineLibrarySnapshot = .empty

    /// ratingKeys with an active (optimize or transfer) job in flight.
    public internal(set) var activeJobs: Set<String> = []
    /// Exact owner of each compatibility `activeJobs` slot. The Set remains the UI-facing shape;
    /// this tracker is the authority used by compare-release.
    @ObservationIgnored var inFlightAttempts = DownloadInFlightAttemptTracker()
    /// App-level retry guard/presentation/handoff markers. The handoff sentinel prevents refresh
    /// cleanup from treating a transient `.failed` retry row as terminal before replacement work is
    /// seeded, while `retrying` still guards async retry continuations.
    private var retryState = DownloadRetryStateTracker()
    @ObservationIgnored private var refreshRecordsTask: Task<Void, Never>?
    private var serverPrepResumeRetryTask: Task<Void, Never>?
    @ObservationIgnored private var serverPrepPollerTasks: [DownloadAttemptKey: Task<Void, Never>] = [:]
    /// Server-prep attempt identities for Plex optimize and Emby convert. Keeps protected Plex
    /// queue titles, Plex poller ownership, and Emby convert attempt UUIDs in one IO-free model.
    /// The queue title must stay protected for the REAL download lifetime (until the file
    /// finishes/fails), not merely until optimize kickoff returns.
    var serverPrepAttempts = ServerPrepAttemptTracker()
    /// Per-key entry-point start-attempt tokens (lens 6 F1–F3). Minted when a download entry point
    /// accepts the in-flight slot, cleared by `releaseInFlight` (terminal/pause/delete). Entry
    /// chains re-check their token after every negotiation await that precedes a store write or
    /// `session.start`, so a delete/pause landing during PlaybackInfo/preflight cannot be undone by
    /// the resumed chain re-seeding the row and starting the transfer.
    @ObservationIgnored var startAttempts = DownloadStartAttemptTracker()
    /// Attempt-scoped ownership for async finalizers and side-cache tails. A replacement seed
    /// cancels only the previous owner's cancellable work; durable cleanup remains registered.
    @ObservationIgnored let downloadWorkRegistry = DownloadWorkRegistry()
    /// Process-wide pacing/coalescing for optional download hydration. DownloadManager remains the
    /// lifecycle owner, while the shared default prevents multiple app scenes/managers from creating
    /// independent request budgets for the same server origin.
    @ObservationIgnored let sideAssetFetchCoordinator: SideAssetFetchCoordinator
    private var serverPrepRefreshKickScheduled = false
    private var lastServerPrepRefreshKickAt: Date?
    private var lastServerPrepQueuePausedLogAt: Date?
    /// Static byte-range recovery bookkeeping that belongs to app queue/retry policy rather than
    /// URLSession mechanics: pending backend-auth rebuilds, finalization re-entry guards,
    /// queue-paused manual resumes, and one-shot restart-counter
    /// preservation.
    private var staticRangeRecovery = StaticRangeRecoveryTracker()
    /// Launch-scoped bound on completed-row optional side-asset rehydrate so a row referencing an
    /// asset the server can never produce (a 404'd poster, a chapter-thumb ref with no generated
    /// thumbnail) stops re-arming the same failing fetch on every foreground/scene-active trigger.
    /// See `rehydrateMissingOptionalSideAssetsForCompletedRows`.
    @ObservationIgnored var completedRowSideAssetRetryBudget = DownloadSideAssetRetryBudget()
    @ObservationIgnored private let staticCheckpointResolutions =
        OrderedAsyncWorkCoordinator<
            DownloadAttemptKey, DownloadStore.AttemptStaticRangeCheckpointResetResult>()
    /// Reentrancy depth of `resumeStaticRangeWhenReady`, which deliberately dispatches
    /// synchronously with `refreshRecords`. Guards against the #210 recursion family.
    private var staticResumeReentryDepth = 0
    @ObservationIgnored private var unverifiedRevalidation = UnverifiedRevalidationCoordinator()
    @ObservationIgnored private var isAppSceneActive = false
    @ObservationIgnored private var downloadWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var forwardOnlyStallTracker = DownloadForwardOnlyStallTracker()
    @ObservationIgnored private var lastDownloadHealthDiagnosticAt: Date?

    /// Ephemeral live Range bytes. Persisted records stay pinned to durable checkpoints so storage
    /// and Pause/Pause All accounting never claim non-resumable OS temp bytes. This overlay drives
    /// active row progress, speed, and ETA between checkpoints.
    private var liveRangeProgress: [String: DownloadLiveRangeProgressSample] = [:]

    /// Emby convert cleanup tombstones whose durable persist FAILED (disk full — exactly when a
    /// user deletes downloads). The delete still completes; these in-memory copies keep the
    /// cleanup intent alive for this process and each convert-resume sweep retries persisting
    /// them. Lost on app death — an accepted trade-off versus wedging delete() forever.
    @ObservationIgnored var deferredEmbyCleanupTombstones: [DownloadStore.EmbyConvertCleanupTombstone] = []
    /// Process-lifetime fallback when the durable cleanup journal is temporarily unavailable.
    /// User deletion must still remove the row/file; these exact intents retry opportunistically
    /// and are removed only after the same confirmation paths as durable journal entries.
    @ObservationIgnored private var deferredCleanupIntents: [UUID: DurableDownloadCleanupIntent] = [:]
    /// Tombstone ids whose recovery is currently running. Sweeps fire from many lifecycle edges
    /// (pause, retry ladder, backend-ready) and each spawned a fresh GET /Sync/Jobs (+ racing
    /// DELETE) per tombstone; this is the tombstone twin of the `activeJobs` row guard.
    @ObservationIgnored var embyCleanupTombstonesInFlight: Set<UUID> = []

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

    /// Background URLSession can report a large amount of already-transferred body data in
    /// its first foreground callback. That is real byte progress, but it did not occur inside
    /// the foreground sampling interval; suppress and continually re-baseline the UI estimator
    /// until a fresh window is available (#224).
    private var rateEstimatorForegroundGraceUntil: [String: Date] = [:]

    /// Static rows awaiting their first live Range watermark after scene activation. The original
    /// #224 fix started a fixed four-second grace at the scene event, but current device evidence
    /// shows reattach/retry can deliver the first range callback 7-15 seconds later. Keep the
    /// activation time so that first callback can explicitly rebaseline the estimator at the data
    /// boundary rather than relying on a wall-clock guess.
    private var rateEstimatorForegroundProgressPending: [String: Date] = [:]

    /// One-shot evidence marker: after the first post-foreground callback rebaselines a row, record
    /// the first rate the UI is allowed to publish. This makes physical validation compare the
    /// hidden catch-up boundary with the subsequent settled computed rate without logging every
    /// one-second estimator sample.
    private var rateEstimatorForegroundSettledPending: Set<String> = []

    /// A headset wake can leave static Range tasks untracked until the background session is
    /// enumerated again. Coalesce the recovery sweep so repeated active/inactive scene events
    /// cannot race duplicate reattach/retry work.
    private var foregroundStaticRangeRecoveryInFlight = false

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
    var transcodeSourcedDownloads: Set<DownloadAttemptKey> = []

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
    var embyPlaySessionByAttempt: [DownloadAttemptKey: String] = [:]
    var jellyfinPlaySessionByAttempt: [DownloadAttemptKey: String] = [:]
    /// Last (progress 0…1, time) sample per ratingKey, used to derive `optimizeETA` rate.
    private var optimizeProgressSamples: [String: (p: Double, time: Date)] = [:]
    /// Smoothed %/sec rate per ratingKey (EMA), used to derive `optimizeETA`.
    private var optimizeRate: [String: Double] = [:]

    // #135 Stage 5c: `internal` (not `private`) so the per-backend lane subsystems split into their
    // own files (e.g. DownloadManager+EmbyConvert.swift) can reach the shared download services.
    let appModel: AppModel
    let store: DownloadStore
    let session: BackgroundDownloadSession
    /// Owns exact-attempt Jellyfin/Emby encoder keepalive tasks and auth quarantine.
    @ObservationIgnored private let keepaliveCoordinator: DownloadKeepaliveCoordinator
    /// Attempt-scoped server cleanup survives row/file removal in a separate durability domain.
    let cleanupIntentJournal: DownloadCleanupIntentJournal
    @ObservationIgnored private var cleanupIntentsInFlight: Set<UUID> = []

    /// Poll cadence for Plex server-side optimize jobs. Deliberately no wall-clock timeout:
    /// long 4K/HDR software transcodes can legitimately run for hours, and the app must base
    /// failure only on server truth (metadata/background queue status), not elapsed time.
    let optimizePollInterval: TimeInterval = 5

    init(appModel: AppModel,
         store injectedStore: DownloadStore? = nil,
         session injectedSession: BackgroundDownloadSession? = nil,
         cleanupIntentJournal injectedCleanupIntentJournal: DownloadCleanupIntentJournal? = nil,
         sideAssetFetchCoordinator injectedSideAssetFetchCoordinator: SideAssetFetchCoordinator? = nil,
         registerForBackgroundEvents: Bool = true) {
        #if DEBUG && os(tvOS)
        Self.debugConstructionCount += 1
        #endif
        self.appModel = appModel
        let store = injectedStore ?? DownloadStore()
        // Commit typed row ownership before the background session can be constructed/activated.
        // A failure remains explicit and leaves session admission dormant.
        let startupAdmission = store.startupIndexAdmission()
        self.store = store
        self.session = injectedSession ?? BackgroundDownloadSession(store: store)
        self.keepaliveCoordinator = DownloadKeepaliveCoordinator(appModel: appModel, store: store)
        self.sideAssetFetchCoordinator = injectedSideAssetFetchCoordinator ?? .shared
        self.cleanupIntentJournal = injectedCleanupIntentJournal
            ?? DownloadCleanupIntentJournal(directory: store.durableCleanupAuthorityDirectory)
        self.records = store.records
        self.offlineLibrarySnapshot = makeOfflineLibrarySnapshot(from: self.records)
        // Reattach to any transfers that survived a relaunch + receive progress.
        self.session.onChange = { [weak self] in
            Task { @MainActor in
                self?.scheduleRefreshRecords(reason: "session_change")
                self?.revalidateUnverifiedDownloads(reason: "session_change")
            }
        }
        self.session.onFinalizerRequest = { [weak self, weak session] request in
            Task { @MainActor in
                guard let self, let session else {
                    session?.abandonFinalizerRequest(request)
                    return
                }
                // The session claims synchronously, but its broker hop is queued on MainActor.
                // Scene deactivation can overtake that hop; never install a foreground-only probe
                // after the coordinator has parked it. Publishing finalizers remain admitted.
                guard !request.isRevalidation || self.isAppSceneActive else {
                    session.abandonFinalizerRequest(request)
                    return
                }
                guard !self.store.isDeletionPending(for: request.attemptKey) else {
                    session.abandonFinalizerRequest(request)
                    return
                }
                guard self.downloadWorkRegistry.startIfAbsent(
                    for: request.attemptKey,
                    kind: request.isRevalidation ? .revalidationFinalizer : .finalizer,
                    operation: { [weak session] in
                        guard let session else { return }
                        await session.executeFinalizerRequest(request)
                    }) != nil else {
                    session.abandonFinalizerRequest(request)
                    return
                }
            }
        }
        self.session.onRevalidationProbeDeferred = { [weak self] key, requestID in
            Task { @MainActor in
                // `started` meant only that a finalizer was claimed; the session discovered the
                // global wake gate before touching AVFoundation. This is not an in-flight probe.
                self?.unverifiedRevalidation.deferred(key, requestID: requestID)
            }
        }
        self.session.onRevalidationRequestFinished = { [weak self] key, requestID, outcome in
            Task { @MainActor in
                guard let self else { return }
                let retry = self.unverifiedRevalidation.finished(
                    key, requestID: requestID, cancelled: outcome == .cancelled,
                    remainsUnverified: self.store.record(for: key)?.status == .unverified)
                if let retry {
                    self.scheduleUnverifiedRevalidationRetry(
                        for: key, delay: retry == .soon ? .seconds(1) : .seconds(90))
                }
            }
        }
        self.session.onBackgroundCompletionGateDrained = { [weak self] deferredKeys in
            Task { @MainActor in
                guard let self else { return }
                // Force-clear the exact keys delivered by the session. This also makes ordering
                // safe if the gate-drain callback overtakes the per-request deferred callback.
                let shouldStart = self.unverifiedRevalidation.gateDrained(
                    deferredKeys, sceneIsActive: self.isAppSceneActive)
                if shouldStart {
                    self.revalidateUnverifiedDownloads(reason: "background_gate_drained")
                }
            }
        }
        // D3: surface background-delegate failures instead of silently dropping the
        // row. Hard failures record a `.failed` status in the store and hand us the
        // reason here so `lastError` can drive the OfflineLibraryView message + retry.
        self.session.onError = { [weak self] ratingKey, error in
            Task { @MainActor in
                guard let self else { return }
                // A-3 (audit lens 8): the range engine's terminal branch surfaces persistent
                // 401/403 rehydration exhaustion as a generic "Server returned HTTP 401." — remap
                // it here (manager-side) to the sign-in-again affordance.
                var surfaced = error
                if case .transferFailed(let message) = error,
                   DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage(message) {
                    surfaced = .notAuthenticated
                    self.recordDownloadDiagnostic("downloads.transfer_auth_dead", fields: [
                        "download_id": .identifier(ratingKey),
                    ])
                }
                self.lastError[ratingKey] = surfaced
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
        // Finding 6: logout revokes the JF/Emby token server-side, so an in-flight remainder can
        // 401/403 after its retry/rehydration budget is spent purely because the user signed out.
        // Decide on the main actor: if the backend session is actually gone, park the row in the same
        // deferred "waiting for a valid session" state the resume path uses; otherwise (still signed
        // in) it is a real auth error and stays `.failed`.
        self.session.onRangeAuthHTTPFailure = { [weak self] ratingKey, httpStatus, attemptKey in
            Task { @MainActor in
                guard let self,
                      let record = self.store.records.first(where: { $0.ratingKey == ratingKey }) else { return }
                // A stale attempt's off-main 401 can emit this handoff after the `Task { @MainActor }`
                // hop, by which point the user's Retry may have minted a newer attempt for the row.
                // The session-side quiesce/fail calls below are already fenced on `attemptKey`, but the
                // manager-side writes (deferStaticRangeResume re-derives the row's CURRENT attempt;
                // the `.fail` branch stamps `.notAuthenticated`) are not — a superseded handoff would
                // park or fail the newer, healthy attempt. Gate the whole handoff on the failing attempt
                // still owning the row so a superseded handoff becomes a full no-op.
                guard self.store.ownsAttempt(attemptKey) else { return }
                let kind = DownloadJobSnapshot(record: record).backend
                let hasLiveSession = self.appModel.backendSession(for: kind) != nil
                switch PostLogoutDownloadFailurePolicy.disposition(httpStatus: httpStatus,
                                                                   hasLiveSession: hasLiveSession) {
                case .deferAwaitingSession:
                    self.recordDownloadDiagnostic("downloads.range_auth_deferred_signed_out", fields: [
                        "download_id": .identifier(ratingKey),
                        "backend": .label(kind.rawValue),
                        "status_code": .int(httpStatus),
                    ])
                    // Quiesce the live train BEFORE parking (preserving held segments): the parked
                    // `.paused`/`.queued` row is otherwise auto-promoted back to `.downloading` by a
                    // same-attempt sibling's progress callback, defeating the deferral.
                    self.session.quiesceStaticRangeForDeferredResume(attemptKey: attemptKey)
                    self.deferStaticRangeResume(record: record, reason: "backend_signed_out")
                case .fail:
                    // Drive the full session-side terminal teardown (purge held segments, supersede live
                    // siblings, advance the train epoch, attempt-fenced `.failed` write) that the range
                    // engine's early handoff skipped — a bare store `.failed` write leaves the train live
                    // and a sibling progress callback auto-promotes the row straight back to `.downloading`.
                    self.session.failStaticRangeAuthTerminal(attemptKey: attemptKey)
                    // Surface the terminal auth failure through the same notAuthenticated remap +
                    // diagnostic as the pre-branch onError flow (A-3): the callback only ever fires for a
                    // deferrable 401/403, so this is exactly the message the remap would have caught. Keep
                    // the sign-in-again affordance instead of a generic "Server returned HTTP 401.".
                    self.recordDownloadDiagnostic("downloads.transfer_auth_dead", fields: [
                        "download_id": .identifier(ratingKey),
                    ])
                    self.lastError[ratingKey] = .notAuthenticated
                    self.refreshRecords()
                }
            }
        }
        // `liveBytes` arrives already normalized against the resume display watermark — the
        // session owns the durable base offset the rebase needs, so it publishes display-ready
        // totals and records the rebase diagnostic itself.
        self.session.onRangeLiveProgress = { [weak self] ratingKey, liveBytes, expectedBytes in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                self.liveRangeProgress[ratingKey] = DownloadLiveRangeProgressPolicy.mergedSample(
                    liveBytes: liveBytes,
                    expectedBytes: expectedBytes,
                    previous: self.liveRangeProgress[ratingKey],
                    updatedAt: now)
                if self.isAppSceneActive,
                   let foregroundedAt = self.rateEstimatorForegroundProgressPending
                    .removeValue(forKey: ratingKey) {
                    let baselineBytes = self.liveRangeProgress[ratingKey]?.bytes ?? liveBytes
                    var estimator = self.rateEstimators[ratingKey]
                        ?? DownloadRateEstimator(rebaselineSuppressWindow: 4.0)
                    estimator.rebaseline(bytes: baselineBytes, at: now)
                    self.rateEstimators[ratingKey] = estimator
                    self.rateEstimatorForegroundGraceUntil[ratingKey] = now.addingTimeInterval(4)
                    self.rateEstimatorForegroundSettledPending.insert(ratingKey)
                    self.downloadSpeed.removeValue(forKey: ratingKey)
                    self.downloadETA.removeValue(forKey: ratingKey)
                    self.recordDownloadDiagnostic("downloads.rate_foreground_rebaseline", fields: [
                        "download_id": .identifier(ratingKey),
                        "foreground_delay_ms": .int(
                            max(0, Int(now.timeIntervalSince(foregroundedAt) * 1_000))),
                        "baseline_bytes": .bytes(baselineBytes),
                    ])
                }
                // Range delegates can fire many times per second across several active downloads.
                // Publishing the whole offline snapshot at the default 500 ms cadence made the
                // headset main thread alternate between smooth frames and 300+ ms microhangs while
                // scrolling. Keep live Range UI responsive, but cap full snapshot rebuilds to ~1 Hz.
                self.scheduleRefreshRecords(reason: "range_live_progress", delay: .seconds(1))
            }
        }
        // Register only after callbacks exist, but while the session is still dormant. If the app
        // delegate already holds a background completion handler, registration records it in the
        // session's completion gate before activation constructs URLSession and events can arrive.
        if registerForBackgroundEvents {
            BackgroundDownloadCompletionRegistry.shared.register(self.session)
        }
        continueStartupRecovery(with: startupAdmission)
    }

    /// Explicit retry hook for a prior persistence/activation failure. It is intentionally not an
    /// automatic repair loop: persistent disk failure or malformed v3 ownership keeps admission
    /// closed until the user/lifecycle layer explicitly asks again, and malformed rows remain
    /// blocked rather than receiving a guessed owner.
    public func retryDownloadStartupRecovery() {
        guard startupRecoveryState != .ready, !startupRecoveryInFlight else { return }
        startupRecoveryRetryTask?.cancel()
        startupRecoveryRetryTask = nil
        startupRecoveryState = .preparing
        continueStartupRecovery(with: store.startupIndexAdmission())
    }

    private func scheduleTransientStartupRecoveryRetry() {
        guard startupRecoveryRetryTask == nil, startupRecoveryRetryCount < 3 else { return }
        startupRecoveryRetryCount += 1
        let attempt = startupRecoveryRetryCount
        startupRecoveryRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Double(attempt) * 2)) }
            catch { return }
            guard let self else { return }
            self.startupRecoveryRetryTask = nil
            guard self.startupRecoveryState != .ready, !self.startupRecoveryInFlight else { return }
            self.startupRecoveryState = .preparing
            self.continueStartupRecovery(with: self.store.startupIndexAdmission())
        }
    }

    private func continueStartupRecovery(
        with admission: DownloadStore.StartupIndexAdmission
    ) {
        guard !startupRecoveryInFlight else { return }
        switch admission {
        case .requiresDestructiveReset:
            activateDownloadsAfterUnsupportedSchemaReset()
        case .unreadableIndex:
            blockDownloadStartup(
                affectedRatingKeys: [],
                message: "Download recovery data is unreadable. Downloads are paused for safety.",
                reason: "unreadable_download_index"
            )
        case .current:
            store.stageHeldBodyDeletionJobs()
            activateDownloadsForCurrentStore()
        case .malformedCurrentRows(let ratingKeys):
            blockDownloadStartup(
                affectedRatingKeys: Set(ratingKeys),
                message: "Download recovery data is inconsistent. Downloads are paused for safety.",
                reason: "malformed_current_ownership"
            )
        }
    }

    private func activateDownloadsAfterUnsupportedSchemaReset() {
        startupRecoveryInFlight = true
        session.activateAfterResettingUnsupportedStore { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .activated, .alreadyActive:
                    self.startupRecoveryInFlight = false
                    self.startupRecoveryState = .ready
                    self.records = self.store.records
                    self.offlineLibrarySnapshot = self.makeOfflineLibrarySnapshot(from: self.records)
                    self.performInitialStartupReattachIfNeeded()
                case .alreadyPurging:
                    self.recordDownloadDiagnostic("downloads.startup_reset_coalesced")
                case .failed:
                    self.startupRecoveryInFlight = false
                    self.blockDownloadStartup(
                        affectedRatingKeys: [],
                        message: "Unsupported download data could not be reset safely. Retry when storage and the system download service are available.",
                        reason: "unsupported_schema_reset_failed")
                    self.scheduleTransientStartupRecoveryRetry()
                }
            }
        }
    }

    private func activateDownloadsForCurrentStore() {
        startupRecoveryInFlight = true
        session.activateCurrentStore { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .activated, .alreadyActive:
                    self.startupRecoveryInFlight = false
                    self.startupRecoveryState = .ready
                    self.startupRecoveryRetryTask?.cancel()
                    self.startupRecoveryRetryTask = nil
                    self.startupRecoveryRetryCount = 0
                    for key in self.startupRecoveryErrorKeys { self.lastError[key] = nil }
                    self.startupRecoveryErrorKeys.removeAll()
                    self.performInitialStartupReattachIfNeeded()
                case .alreadyPurging:
                    // A coalesced caller owns the live completion. Keep admission visibly pending;
                    // never launch a second task enumeration/reconcile pass.
                    self.recordDownloadDiagnostic("downloads.startup_admission_coalesced")
                case .failed:
                    self.startupRecoveryInFlight = false
                    self.blockDownloadStartup(
                        affectedRatingKeys: [],
                        message: "Download recovery did not finish. Retry when storage and the system download service are available.",
                        reason: "activation_failed"
                    )
                    self.scheduleTransientStartupRecoveryRetry()
                }
            }
        }
    }

    private func blockDownloadStartup(
        affectedRatingKeys: Set<String>,
        message: String,
        reason: String
    ) {
        // Every terminal startup block leaves session admission dormant. No finish-events callback
        // is then guaranteed, so release a stored OS wake after the failure has been observed.
        session.releaseBackgroundCompletionAfterStartupFailure()
        startupRecoveryInFlight = false
        startupRecoveryState = .blocked(message: message)
        startupRecoveryErrorKeys = affectedRatingKeys
        for key in affectedRatingKeys { lastError[key] = .transferFailed(message) }
        recordDownloadDiagnostic("downloads.startup_admission_blocked", fields: [
            "reason": .label(reason),
            "affected_count": .int(affectedRatingKeys.count),
            "pending_background_handler": .bool(
                BackgroundDownloadCompletionRegistry.shared.hasPendingHandler(
                    identifier: BackgroundDownloadSession.identifier
                )
            ),
            "action": .label("release_handler_and_retry_explicitly"),
        ])
    }

    /// A season transaction reached an unprovable persistence state. Stop all new/current queue
    /// admission and reuse the startup safety surface rather than continuing with ambiguous rows.
    func blockAfterIndeterminateSeasonPersistence() {
        pauseQueue()
        blockDownloadStartup(
            affectedRatingKeys: [],
            message: "Download storage is inconsistent. Downloads are paused for safety.",
            reason: "season_plan_persistence_indeterminate")
    }

    private static func startupPersistenceFailureLabel(
        _ result: DownloadStore.PersistenceFlushResult
    ) -> String {
        switch result {
        case .committed:
            return "unexpected_commit_mismatch"
        case .failed(_, let stage, _):
            return "migration_\(stage)_failed"
        case .timedOut:
            return "migration_timed_out"
        }
    }

    private static func cleanupOrderingFailureLabel(
        _ failure: DownloadCleanupOrdering.JournalFailure
    ) -> String {
        switch failure {
        case .conflictingID:
            return "cleanup_journal_conflicting_id"
        case .persistence(let failure):
            return "cleanup_journal_\(failure.stage.rawValue)_failed"
        }
    }

    /// The manager is the sole owner of initial reattach/reconcile. Registry registration and
    /// app-delegate handler storage never invoke this path, preventing duplicate launch snapshots.
    private func performInitialStartupReattachIfNeeded() {
        guard !didRunInitialStartupReattach else { return }
        didRunInitialStartupReattach = true
        let interruptedStaticKeys = store.interruptedStaticByteRangeKeys()
        for ratingKey in store.allRatingKeys {
            guard let record = store.record(for: ratingKey),
                  let key = attemptKey(for: record),
                  let evidence = store.staticRangeRecoveryEvidence(for: key) else { continue }
            recordDownloadDiagnostic("downloads.range_launch_checkpoint", fields: [
                "download_id": .identifier(evidence.ratingKey),
                "status": .label(evidence.status.rawValue),
                "durable_bytes": .bytes(evidence.durableBytes),
                "durable_bytes_exact": .int(evidence.durableBytes),
                "resume_manifest_recorded": .bool(evidence.resumeManifestRecorded),
                "resume_blob_present": .bool(evidence.resumeBlobPresent),
                "resume_blob_bytes": .bytes(evidence.resumeBlobBytes),
                "held_body_count": .int(evidence.heldBodyCount),
                "held_body_bytes": .bytes(evidence.heldBodyBytes),
            ])
        }
        let snapshotRatingKeys = store.allRatingKeys
        session.reattach { [weak self, store] liveKeys in
            store.reconcile(liveRatingKeys: liveKeys, snapshotRatingKeys: snapshotRatingKeys)
            Task { @MainActor in
                guard let self else { return }
                self.refreshRecords()
                // Pending deletion is the first recovery concern after publishing the reconciled
                // snapshot. It must migrate (or fail closed and halt A) before finalization,
                // revalidation, server-prep polling, or static auto-resume scans can run.
                self.migrateAndRetryActiveEncodingCleanupOnLaunch()
                self.finalizeCompletedStaticRangeDownloads(reason: "launch_recovered")
                self.revalidateUnverifiedDownloads(reason: "launch_recovered")
                if !self.isQueuePaused {
                    self.resumePendingServerPrepDownloads()
                    self.resumeInterruptedStaticByteRangeDownloads(
                        candidateKeys: interruptedStaticKeys,
                        liveKeys: liveKeys
                    )
                }
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
        migrateAndRetryActiveEncodingCleanupOnLaunch()
    }

    /// Move row-owned ActiveEncoding handles into the independent journal before executing them.
    /// The journal is the authority once a row is deleted; an unreadable/unwritable journal is
    /// never treated as an empty queue.
    func migrateAndRetryActiveEncodingCleanupOnLaunch() {
        guard startupRecoveryState == .ready else { return }

        for record in records {
            guard let attemptID = record.attemptID else { continue }
            let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
            if let pending = store.deletionPendingCleanupIntents(for: key) {
                switch DownloadCleanupOrdering.prepareForDestructiveDeletion(
                    candidates: pending,
                    key: key,
                    journal: cleanupIntentJournal,
                    store: store
                ) {
                case .ready(let durable):
                    // Every cleanup operation is now independent of row lifetime. Remove A under
                    // exact ownership before starting cleanup; a replacement B is rejected while
                    // the deletion-pending reservation exists.
                    session.cancel(ratingKey: key.ratingKey)
                    let submission = store.submitCompletePendingDeletion(for: key)
                    if case .accepted = submission {
                        _ = downloadWorkRegistry.cancelCancellableWork(for: key)
                    }
                    Task { [weak self] in
                        guard let self else { return }
                        let outcome = await store.resolveRowDeletion(submission)
                        guard case .removed = outcome else {
                            // A non-`.removed` outcome means the accepted completion never proved
                            // exact removal (terminal-barrier persistence/cleanup failed, or the
                            // owner changed underneath us). Mirror the interactive delete() and
                            // removeAttempt() paths: emit a diagnostic and surface a retry-able
                            // lastError instead of guard-returning silently, which left the
                            // deletion-pending row frozen until a manual Delete. The durable
                            // reservation survives, so the next launch's migration re-drives it and
                            // the surfaced "tap Delete to retry" gives the user an in-session action.
                            recordStartupDeletionResolutionFailure(outcome, key: key)
                            lastError[key.ratingKey] = .transferFailed(
                                "Deletion could not finish safely. Free storage if needed, then tap Delete to retry.")
                            refreshRecords()
                            return
                        }
                        for intent in durable {
                            deferredCleanupIntents[intent.id] = intent
                            switch intent.operation {
                            case .activeEncoding: executeActiveEncodingCleanupIntent(intent)
                            case .embyConvert: executeEmbyConvertCleanupIntent(intent)
                            }
                        }
                        lastError[key.ratingKey] = nil
                        refreshRecords()
                    }
                case .deletionPending:
                    haltManagerOwnedWorkForPendingDeletion(key)
                    lastError[key.ratingKey] = .transferFailed(
                        "Deletion is pending until server cleanup can be saved. Tap Delete to retry.")
                case .indexPersistenceFailed:
                    lastError[key.ratingKey] = .transferFailed(
                        "Deletion could not be saved. Free storage if needed, then tap Delete to retry.")
                case .staleOrMissing:
                    break
                }
                continue
            }
            guard let metadata = record.metadata else { continue }
            let terminal = record.status == .failed || record.status == .complete
                || record.status == .unverified
            guard terminal else { continue }

            let backend = metadata.resolvedBackendKind(ratingKey: record.ratingKey)
            if backend == .plex {
                // Plex has no ActiveEncoding cleanup. Preserve the prior stale-handle repair, but
                // use exact attempt/value authority so this sweep cannot clear a replacement row.
                if let playSessionID = metadata.playSessionID, !playSessionID.isEmpty {
                    switch store.clearPlaySessionID(for: key, expectedPlaySessionID: playSessionID) {
                    case .cleared, .alreadyAbsent:
                        break
                    case .expectedValueMismatch, .staleOrMissing, .persistenceFailed:
                        break
                    }
                }
                continue
            }

            var cleanupAuthorityDurable = true
            if let playSessionID = metadata.playSessionID, !playSessionID.isEmpty {
                if let intent = persistActiveEncodingCleanupIntent(
                    attemptKey: key, metadata: metadata, playSessionID: playSessionID
                ) {
                    executeActiveEncodingCleanupIntent(intent)
                } else {
                    cleanupAuthorityDurable = false
                }
            }
            if Self.hasEmbyConvertCleanupAuthority(metadata) {
                if let intent = persistEmbyConvertCleanupIntent(
                    attemptKey: key, metadata: metadata
                ) {
                    executeEmbyConvertCleanupIntent(intent)
                } else {
                    cleanupAuthorityDurable = false
                }
            }
            _ = cleanupAuthorityDurable
        }


        guard case .loaded(let intents) = cleanupIntentJournal.load() else {
            recordDownloadDiagnostic("downloads.cleanup_intent_load_failed")
            return
        }
        for intent in intents {
            switch intent.operation {
            case .activeEncoding: executeActiveEncodingCleanupIntent(intent)
            case .embyConvert: executeEmbyConvertCleanupIntent(intent)
            }
        }
    }

    /// Diagnostic for a launch-time pending-deletion completion that did not resolve to `.removed`.
    /// Named/shaped to parallel `removeAttempt`'s remove_* diagnostics so the frozen-row case is
    /// no longer silent.
    private func recordStartupDeletionResolutionFailure(
        _ outcome: DownloadStore.RowDeletionResult, key: DownloadAttemptKey
    ) {
        switch outcome {
        case .removed:
            break
        case .staleOrMissing:
            recordDownloadDiagnostic("downloads.migrate_deletion_owner_stale", fields: [
                "download_id": .identifier(key.ratingKey),
            ])
        case .persistenceFailed(_, let failure):
            recordDownloadDiagnostic("downloads.migrate_deletion_persist_failed", fields: [
                "download_id": .identifier(key.ratingKey),
                "failure": .label(Self.startupPersistenceFailureLabel(failure)),
            ])
        case .cleanupFailed(_, let count):
            recordDownloadDiagnostic("downloads.migrate_deletion_artifact_failed", fields: [
                "download_id": .identifier(key.ratingKey),
                "failure_count": .int(count),
            ])
        }
    }

    /// Return the existing exact operation when already durable; otherwise append one new intent.
    /// The server identity comes from persisted row authority, never from whichever lane happens
    /// to be selected when cleanup runs.
    private func persistActiveEncodingCleanupIntent(
        attemptKey: DownloadAttemptKey,
        metadata: OfflineMetadata,
        playSessionID: String
    ) -> DurableDownloadCleanupIntent? {
        guard let candidate = Self.makeActiveEncodingCleanupIntent(
            attemptKey: attemptKey, metadata: metadata, playSessionID: playSessionID
        ) else { return nil }
        switch cleanupIntentJournal.ensure(candidate) {
        case .committed(let durable): return durable
        case .conflictingID, .failed: return nil
        }
    }

    nonisolated static func makeActiveEncodingCleanupIntent(
        attemptKey: DownloadAttemptKey,
        metadata: OfflineMetadata,
        playSessionID: String
    ) -> DurableDownloadCleanupIntent? {
        let backend = metadata.resolvedBackendKind(ratingKey: attemptKey.ratingKey)
        guard backend == .jellyfin || backend == .emby,
              let baseURLString = metadata.backendBaseURLString,
              let baseURL = URL(string: baseURLString),
              let userID = metadata.backendUserID,
              let server = DurableDownloadCleanupIntent.ServerIdentity(
                baseURL: baseURL, serverID: metadata.backendServerID, userID: userID
              ) else { return nil }
        return DurableDownloadCleanupIntent(
            attemptKey: attemptKey,
            backend: backend,
            server: server,
            operation: .activeEncoding(playSessionID: playSessionID)
        )
    }

    private func persistEmbyConvertCleanupIntent(
        attemptKey: DownloadAttemptKey,
        metadata: OfflineMetadata
    ) -> DurableDownloadCleanupIntent? {
        guard let candidate = Self.makeEmbyConvertCleanupIntent(
            attemptKey: attemptKey, metadata: metadata
        ) else { return nil }
        switch cleanupIntentJournal.ensure(candidate) {
        case .committed(let durable): return durable
        case .conflictingID, .failed: return nil
        }
    }

    nonisolated static func makeEmbyConvertCleanupIntent(
        attemptKey: DownloadAttemptKey,
        metadata: OfflineMetadata
    ) -> DurableDownloadCleanupIntent? {
        guard metadata.resolvedBackendKind(ratingKey: attemptKey.ratingKey) == .emby,
              let baseURLString = metadata.backendBaseURLString,
              let baseURL = URL(string: baseURLString),
              let userID = metadata.backendUserID,
              let server = DurableDownloadCleanupIntent.ServerIdentity(
                baseURL: baseURL, serverID: metadata.backendServerID, userID: userID
              ) else { return nil }
        let operation: DurableDownloadCleanupIntent.Operation
        if let jobID = metadata.embyConvertJobID {
            operation = .embyConvert(.knownJob(jobID: jobID))
        } else if let baseline = metadata.embyConvertJobBaselineIDs,
                  let fingerprint = metadata.embyConvertRecoveryFingerprint,
                  let started = metadata.embyConvertRecoveryStartedAtEpochSeconds,
                  let phase = metadata.embyConvertRecoveryPhase {
            operation = .embyConvert(.ambiguousCreate(
                baselineJobIDs: baseline,
                fingerprint: fingerprint,
                attemptStartedAtEpochSeconds: started,
                phase: phase))
        } else {
            return nil
        }
        return DurableDownloadCleanupIntent(
            attemptKey: attemptKey, backend: .emby, server: server, operation: operation)
    }

    nonisolated private static func hasEmbyConvertCleanupAuthority(
        _ metadata: OfflineMetadata
    ) -> Bool {
        metadata.embyConvertJobID != nil || metadata.hasEmbyConvertCrashWindowIdentity
    }

    private func executeActiveEncodingCleanupIntent(_ intent: DurableDownloadCleanupIntent) {
        guard case .activeEncoding(let playSessionID) = intent.operation,
              !cleanupIntentsInFlight.contains(intent.id),
              let live = appModel.backendSession(for: intent.backend),
              intent.matches(session: live) else { return }
        cleanupIntentsInFlight.insert(intent.id)
        downloadWorkRegistry.start(
            for: intent.attemptKey,
            kind: .requiredCleanup
        ) { [weak self] in
            guard let self else { return }
            let confirmedGone: Bool
            switch intent.backend {
            case .jellyfin:
                confirmedGone = await JellyfinBrowseService(appModel: self.appModel)
                    .stopActiveEncoding(playSessionId: playSessionID, session: live)
            case .emby:
                confirmedGone = await EmbyBrowseService(appModel: self.appModel)
                    .stopActiveEncoding(playSessionId: playSessionID, session: live)
            case .plex:
                confirmedGone = false
            }
            self.cleanupIntentsInFlight.remove(intent.id)
            guard confirmedGone else { return }
            self.deferredCleanupIntents.removeValue(forKey: intent.id)
            switch self.store.clearPlaySessionID(
                for: intent.attemptKey, expectedPlaySessionID: playSessionID
            ) {
            case .persistenceFailed:
                // Repeat the idempotent DELETE later; never drop the only durable cleanup record
                // while the row clear is still dirty/unproven.
                return
            case .cleared, .alreadyAbsent, .expectedValueMismatch, .staleOrMissing:
                _ = self.cleanupIntentJournal.remove(
                    id: intent.id, attemptKey: intent.attemptKey, operation: intent.operation)
            }
        }
    }

    private func executeEmbyConvertCleanupIntent(_ intent: DurableDownloadCleanupIntent) {
        guard case .embyConvert(let convertIdentity) = intent.operation,
              !cleanupIntentsInFlight.contains(intent.id),
              let live = appModel.backendSession(for: .emby),
              let currentUserID = live.userID,
              intent.matches(session: live) else { return }
        cleanupIntentsInFlight.insert(intent.id)
        downloadWorkRegistry.start(for: intent.attemptKey, kind: .requiredCleanup) { [weak self] in
            guard let self else { return }
            defer { self.cleanupIntentsInFlight.remove(intent.id) }
            do {
                let resolved: EmbyConvertCleanupResolution
                switch convertIdentity {
                case .knownJob(let jobID):
                    resolved = .cancel(jobID: jobID)
                case .ambiguousCreate(let baseline, let fingerprint, let started, let phase):
                    guard EmbyConvertRecoveryPolicy.publicUserMatches(
                        currentSessionUserID: currentUserID,
                        persistedBackendUserID: intent.server.userID,
                        fingerprintUserID: fingerprint.userId) else { return }
                    let listRequest = try EmbyConvertRequest.jobListRequest(
                        server: live.baseURL, token: live.token, identity: self.appModel.identity.emby)
                    let (data, response) = try await URLSession.shared.data(for: listRequest)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                    let list = try EmbyConvertRequest.decodeJobList(from: data)
                    // Preserve the legacy tombstone sweep's one-train exclusion exactly: every
                    // job currently owned by any live row is protected, including a job this same
                    // attempt may have adopted after its ambiguous intent was journaled.
                    let liveJobIDs = Set(self.store.records.compactMap {
                        $0.metadata?.embyConvertJobID
                    })
                    switch EmbyConvertRecoveryPolicy.cleanupAction(
                        baselineJobIDs: Set(baseline), jobs: list.items,
                        listIsComplete: list.isComplete, fingerprint: fingerprint,
                        attemptStartedAtEpochSeconds: started, phase: phase,
                        nowEpochSeconds: Date().timeIntervalSince1970,
                        liveJobIDs: liveJobIDs
                    ) {
                    case .retainTombstone: return
                    case .discardTombstone: resolved = .discard
                    case .cancel(let jobID): resolved = .cancel(jobID: jobID)
                    }
                }

                if case .cancel(let jobID) = resolved {
                    let request = try EmbyConvertRequest.deleteJobRequest(
                        server: live.baseURL, token: live.token,
                        identity: self.appModel.identity.emby, jobId: jobID)
                    let (_, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) || [404, 410].contains(http.statusCode)
                    else { return }
                }

                guard self.clearEmbyConvertMetadataIfExact(intent) else { return }
                self.deferredCleanupIntents.removeValue(forKey: intent.id)
                _ = self.cleanupIntentJournal.remove(
                    id: intent.id, attemptKey: intent.attemptKey, operation: intent.operation)
            } catch {
                // Transport/decode/identity uncertainty retains the durable intent for a later pass.
                return
            }
        }
    }

    private enum EmbyConvertCleanupResolution {
        case cancel(jobID: Int)
        case discard
    }

    /// Clear only the exact row authority represented by this completed cleanup. A replacement
    /// attempt, a newly adopted job, or a changed ambiguous-create fingerprint remains untouched.
    private func clearEmbyConvertMetadataIfExact(
        _ intent: DurableDownloadCleanupIntent
    ) -> Bool {
        guard case .embyConvert(let identity) = intent.operation else { return false }
        let result = store.updateMetadata(for: intent.attemptKey) { metadata in
            switch identity {
            case .knownJob(let expectedJobID):
                guard metadata.embyConvertJobID == expectedJobID else { return }
                metadata.embyConvertJobID = nil
            case .ambiguousCreate(let baseline, let fingerprint, let started, let phase):
                guard metadata.embyConvertJobID == nil,
                      metadata.embyConvertJobBaselineIDs == baseline,
                      metadata.embyConvertRecoveryFingerprint == fingerprint,
                      metadata.embyConvertRecoveryStartedAtEpochSeconds == started,
                      metadata.embyConvertRecoveryPhase == phase else { return }
                metadata.clearEmbyConvertRecoveryIdentity()
            }
        }
        switch result {
        case .persistenceFailed: return false
        case .applied, .noChange, .staleOrMissing: return true
        }
    }

    /// Resolve the full durable row only at an action/playback boundary, and only if the rendered
    /// attempt is still the current owner. Rendering itself remains snapshot-only.
    public func currentRecord(for identity: OfflineDownloadRowActionIdentity) -> DownloadRecord? {
        guard let current = store.record(for: identity.ratingKey),
              current.attemptID == identity.attemptID else { return nil }
        return current
    }

    /// Absolute local URL for a completed download, if present on disk.
    public func localURL(for ratingKey: String) -> URL? {
        store.localURL(for: ratingKey)
    }

    /// Absolute cached Plex BIF index URL for a completed download, if present on disk.
    public func plexBIFURL(for ratingKey: String) -> URL? {
        store.plexBIFURL(for: ratingKey)
    }

    /// Absolute cached selected-source Emby BIF URL for a completed download, if present on disk.
    public func embyBIFURL(for ratingKey: String) -> URL? {
        store.embyBIFURL(for: ratingKey)
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
        return DownloadDisplayClassifier.isLiveTranscoderSourced(record)
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
                "local_playable": .bool(OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)),
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
        return DownloadPresetPolicy.visiblePresetNames(serverTargets: serverTargets)
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
    func acquireInFlightSlotForStart(ratingKey: String,
                                     backend: String,
                                     allowReplacingExistingActiveRow: Bool = false) -> Bool {
        let existingStatus = store.status(for: ratingKey)
        if allowReplacingExistingActiveRow,
           existingStatus?.isActiveWork == true,
           activeJobs.contains(ratingKey),
           !session.isTrackingTransfer(ratingKey: ratingKey) {
            // A static-range system resume may persist an active `.queued` row while the app-level
            // activeJobs slot outlives the URLSession task that was cancelled/superseded. If the
            // backend rebuild then tries to seed the replacement with both markers present, the
            // duplicate guard rejects it and the auto-resume scanner keeps burning a slot on a row
            // that never reaches `range_start`. Treat "active row + active slot + no live task" as
            // stale only for explicit recovery replacement.
            recordDownloadDiagnostic("downloads.inflight_recovered", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label(backend),
                "reason": .label("replace_active_without_task"),
            ])
            recoverStaleInFlightSlot(ratingKey: ratingKey, reason: "replace_active_without_task")
        }
        switch DownloadStartSlotPolicy.decision(existingRecordStatus: existingStatus,
                                                hasActiveSlot: activeJobs.contains(ratingKey),
                                                allowReplacingExistingActiveRow: allowReplacingExistingActiveRow) {
        case .accept:
            break
        case .rejectExistingActiveRow(let status):
            recordDownloadDiagnostic("downloads.enqueue_ignored", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label(backend),
                "reason": .label("existing_active_row"),
                "status": .label(status.rawValue),
            ])
            // Only the resume-handoff caller owns the pendingResume marker. If ITS start is the
            // one being rejected (a live slot exists after all), the handoff is moot — drop the
            // marker so it cannot outlive the attempt. An ordinary duplicate tap must NOT clear
            // it: a deferred backend-unavailable resume legitimately parks a marked queued row.
            if allowReplacingExistingActiveRow {
                clearStaticRangePendingResume(ratingKey: ratingKey)
            }
            return false
        case .rejectAlreadyActive:
            recordDownloadDiagnostic("downloads.enqueue_ignored", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label(backend),
                "reason": .label("already_active"),
            ])
            if allowReplacingExistingActiveRow {
                clearStaticRangePendingResume(ratingKey: ratingKey)
            }
            return false
        case .recoverStaleSlotAndAccept:
            recordDownloadDiagnostic("downloads.inflight_recovered", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label(backend),
                "reason": .label("active_without_row"),
            ])
            recoverStaleInFlightSlot(ratingKey: ratingKey, reason: "active_without_row")
        }
        activeJobs.insert(ratingKey)
        return true
    }

    /// What a download entry point captures when its start is accepted: the minted start-attempt
    /// token plus whether a visible row already existed at entry (retry/replacement) — the guard
    /// only treats a missing row as "deleted mid-await" for chains that entered with one.
    struct DownloadStartAttemptHandle {
        let ratingKey: String
        let attemptID: DownloadAttemptID
        let expectedPreviousOwner: DownloadAttemptID?
        let enteredWithExistingRow: Bool
    }

    /// Acquire the in-flight slot AND mint this chain's start-attempt token (lens 6 F1–F3).
    /// Returns nil when the slot is rejected (duplicate/already active), mirroring
    /// `acquireInFlightSlotForStart`'s false.
    func acquireStartAttempt(ratingKey: String,
                             backend: String,
                             allowReplacingExistingActiveRow: Bool = false) -> DownloadStartAttemptHandle? {
        guard startupRecoveryState == .ready else {
            lastError[ratingKey] = .transferFailed(
                "Downloads are paused while recovery is completed. Retry recovery first."
            )
            recordDownloadDiagnostic("downloads.start_blocked", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label(backend),
                "reason": .label("startup_admission_closed"),
            ])
            return nil
        }
        let existingRecord = store.record(for: ratingKey)
        let enteredWithExistingRow = existingRecord != nil
        guard acquireInFlightSlotForStart(ratingKey: ratingKey,
                                          backend: backend,
                                          allowReplacingExistingActiveRow: allowReplacingExistingActiveRow) else {
            return nil
        }
        let attemptID = startAttempts.begin(ratingKey)
        inFlightAttempts.acquire(DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID))
        return DownloadStartAttemptHandle(
            ratingKey: ratingKey,
            attemptID: attemptID,
            expectedPreviousOwner: existingRecord?.attemptID,
            enteredWithExistingRow: enteredWithExistingRow
        )
    }

    /// Post-await currency check for download entry points (lens 6 F1–F3). Call after EVERY await
    /// that precedes a store write or `session.start`. On failure this records
    /// `downloads.start_superseded_after_await` and returns false — the caller must exit WITHOUT
    /// upserting (a pause parked the row `.paused`; a delete removed it; a newer start owns the
    /// key) and release only what its own chain minted (e.g. a just-minted PlaySessionId).
    func startAttemptStillCurrent(_ handle: DownloadStartAttemptHandle,
                                  backend: String,
                                  phase: String) -> Bool {
        let row = store.record(for: handle.ratingKey)
        let verdict = DownloadStartGuardPolicy.verdict(
            tokenIsCurrent: startAttempts.isCurrent(handle.ratingKey, id: handle.attemptID),
            hasActiveSlot: activeJobs.contains(handle.ratingKey),
            enteredWithExistingRow: handle.enteredWithExistingRow,
            rowIsPresent: row != nil,
            rowStatus: row?.status)
        guard case .superseded(let reason) = verdict else { return true }
        recordDownloadDiagnostic("downloads.start_superseded_after_await", fields: [
            "download_id": .identifier(handle.ratingKey),
            "backend": .label(backend),
            "phase": .label(phase),
            "reason": .label(reason.rawValue),
        ])
        return false
    }

    /// Persist the row's typed owner before any server poller, side-cache task, encoder handle, or
    /// URLSession task is admitted. Replacement is compare-and-swap against the exact owner captured
    /// by `acquireStartAttempt`; a failure is surfaced and the caller must stop the start chain.
    @discardableResult
    func persistAttemptSeed(
        _ record: DownloadRecord,
        for handle: DownloadStartAttemptHandle,
        backend: String
    ) -> Bool {
        guard record.ratingKey == handle.ratingKey,
              startAttemptStillCurrent(handle, backend: backend, phase: "persist_seed") else {
            return false
        }
        let result = store.createAttemptOwnedRecord(
            record,
            attemptID: handle.attemptID,
            replacing: handle.expectedPreviousOwner
        )
        switch result {
        case .committed(let key) where key.attemptID == handle.attemptID:
            if let previousOwner = handle.expectedPreviousOwner,
               previousOwner != key.attemptID {
                let previousKey = DownloadAttemptKey(
                    ratingKey: handle.ratingKey, attemptID: previousOwner)
                _ = downloadWorkRegistry.cancelCancellableWork(for: previousKey)
                cancelOptionalSideAssetHydration(for: previousKey)
            }
            return true
        case .committed:
            lastError[handle.ratingKey] = .transferFailed(
                "Download ownership changed before the transfer could start."
            )
            recordDownloadDiagnostic("downloads.attempt_seed_failed", fields: [
                "download_id": .identifier(handle.ratingKey),
                "backend": .label(backend),
                "reason": .label("committed_owner_mismatch"),
            ])
        case .rejectedOwnership(_, _, let reason):
            lastError[handle.ratingKey] = .transferFailed(
                "Download ownership changed before the transfer could start."
            )
            recordDownloadDiagnostic("downloads.attempt_seed_failed", fields: [
                "download_id": .identifier(handle.ratingKey),
                "backend": .label(backend),
                "reason": .label(reason.rawValue),
            ])
        case .failed(_, let persistence):
            lastError[handle.ratingKey] = .transferFailed(
                "The download could not be saved safely. Check storage and try again."
            )
            recordDownloadDiagnostic("downloads.attempt_seed_failed", fields: [
                "download_id": .identifier(handle.ratingKey),
                "backend": .label(backend),
                "reason": .label("persistence_failed"),
                "persistence": .label(String(describing: persistence)),
            ])
        }
        return false
    }

    /// Best-effort teardown of a server session a SUPERSEDED negotiation minted before its chain
    /// noticed the delete/pause. No transfer ever started, so at worst this DELETEs an encoder that
    /// never spun up (harmless) — but if the backend did start one for the minted PlaySessionId, it
    /// would otherwise leak with no row, no task, and no activeJobs slot pointing at it.
    func stopSupersededMediaBrowserEncoder(ratingKey: String,
                                           playSessionID: String?,
                                           backendKind: DownloadBackendKind,
                                           backendSession: BackendSession) {
        guard let playSessionID, !playSessionID.isEmpty else { return }
        recordDownloadDiagnostic("downloads.superseded_encoder_teardown", fields: [
            "download_id": .identifier(ratingKey),
            "backend": .label(backendKind.rawValue),
        ])
        switch backendKind {
        case .jellyfin:
            let service = JellyfinBrowseService(appModel: appModel)
            Task { _ = await service.stopActiveEncoding(playSessionId: playSessionID, session: backendSession) }
        case .emby:
            let service = EmbyBrowseService(appModel: appModel)
            Task { _ = await service.stopActiveEncoding(playSessionId: playSessionID, session: backendSession) }
        case .plex:
            break
        }
    }

    /// Pause one visible download row. Active URLSession transfers are cancelled with resume data
    /// when the backend lane supports it; server-prep rows are marked paused so relaunch/refresh
    /// does not auto-poll/retry until the user resumes.
    public func pause(ratingKey: String) {
        guard let record = records.first(where: { $0.ratingKey == ratingKey }) else { return }
        pause(record: record)
    }

    /// Execute a rendered row's pause only while its exact persisted attempt still owns the key.
    /// A replacement retry/re-download makes the stale action a no-op.
    @discardableResult
    public func pause(_ identity: OfflineDownloadRowActionIdentity) -> Bool {
        guard let record = currentRecord(for: identity) else { return false }
        pause(record: record)
        return true
    }

    private func pause(record: DownloadRecord) {
        let ratingKey = record.ratingKey
        guard let releaseKey = attemptKey(for: record) else { return }
        let pauseAction = DownloadPausePolicy.rowAction(
            status: record.status,
            isStaticRangeRecord: StaticRangeRecoveryPolicy.isStaticRangeRecord(record),
            isTrackingTransfer: session.isTrackingTransfer(ratingKey: ratingKey),
            isServerPrepRecord: DownloadRetryPolicy.isPlexServerPrepResumeCandidate(record)
        )
        guard pauseAction != .ignore else { return }

        recordDownloadDiagnostic("downloads.pause", fields: [
            "download_id": .identifier(ratingKey),
        ])
        retryState.removeRetrying(ratingKey)
        // A stale-queued/system-recovery pass may have marked this row for automatic backend-ready
        // resume while range IO was still draining. User pause supersedes that intent; otherwise a
        // later backend refresh silently retries the row a few seconds after it reached `.paused`.
        staticRangeRecovery.removePendingResume(ratingKey)
        staticRangeRecovery.removeManualQueueResume(ratingKey)
        lastError[ratingKey] = .interruptedResumable

        switch pauseAction {
        case .ignore:
            break
        case .parkStaticWithoutLiveTask:
            // A freshly seeded URLSession task can still be `.queued` until first progress. Route
            // queued rows through the session too, but park no-live static gaps immediately.
            guard let key = attemptKey(for: record),
                  setAttemptStatus(.paused, for: key, context: "user_pause") else { return }
            session.pause(ratingKey: ratingKey)
        case .cancelTaskOnly:
            session.pause(ratingKey: ratingKey)
        case .parkPreparing:
            guard let key = attemptKey(for: record),
                  setAttemptStatus(.paused, for: key, context: "user_pause") else { return }
        }
        clearOptimizeProgress(ratingKey: ratingKey)
        setOptionalSideAssetHydrationParked(true, for: releaseKey)
        releaseInFlight(for: releaseKey, cancellationMode: .preservingSideCache)
        refreshRecords()
    }

    /// Stop only the incomplete rows that belong to a backend which is being signed out.
    ///
    /// An open URLSession download has already copied its Authorization header into the request,
    /// so remote logout alone cannot be relied on to stop the currently streaming response. This
    /// is deliberately a normal resumable pause rather than a destructive cancel: static Range
    /// downloads ask URLSession for resume data, and forward-only/server-prep lanes are parked
    /// without allowing more bytes to flow under the retired session. AuthManager invokes this
    /// while the backend credentials still exist, immediately before it clears them, which also
    /// lets `releaseInFlight` perform any best-effort encoder teardown against the right server.
    func pauseDownloadsForBackendSignOut(_ backend: MediaBackendKind) {
        let candidates = records.filter { record in
            guard record.status.isActiveWork else { return false }
            let rowBackend = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
                ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
            return rowBackend == backend.downloadBackendKind
        }
        guard !candidates.isEmpty else { return }

        for record in candidates {
            recordDownloadDiagnostic("downloads.pause_for_sign_out", fields: [
                "download_id": .identifier(record.ratingKey),
                "backend": .label(backend.rawValue),
            ])
            pause(ratingKey: record.ratingKey)
        }
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
        rehydrateMissingOptionalSideAssetsForCompletedRows(reason: "queue_resumed")
        resumePendingServerPrepDownloads()
        resumePendingStaticRangeDownloads()
        refreshRecords()
    }


    /// Auth restore and background URLSession reattachment can complete in different turns.
    /// Server-prep rows have no URLSession task yet, and relaunch-adopted Range tasks may need the
    /// backend lane to rehydrate an authenticated request before the next remainder can start. Retry a
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

    /// Typed app-lifecycle hint for UI refresh/finalization work. Static range transfer shape is no
    /// longer scene-dependent.
    func noteAppSceneRecovery(_ reason: DownloadRecoveryReason) {
        let isActive = reason == .aggregateSceneBecameActive
        isAppSceneActive = isActive
        if isActive {
            beginDownloadRateForegroundRebaseline()
            // #187: headset reattach can deliver a burst of background-session progress and scene
            // activation events while the Offline window is being reconstructed. Coalesce the first
            // refresh onto the next run-loop turn instead of invalidating the whole downloads list
            // synchronously during scene activation.
            scheduleRefreshRecords(reason: "scene_active")
            rehydrateMissingOptionalSideAssetsForCompletedRows(reason: "scene_active")
            resetUnverifiedAutomaticRetryBudget()
            revalidateUnverifiedDownloads(reason: "scene_active")
            recoverStaticRangeTransfersAfterForeground()
        } else {
            // A muted AVPlayer probe cannot make useful progress once visionOS suspends the scene.
            // Park its exact request edge before cancellation so its completion cannot consume the
            // retry. Publishing finalizers are a different registry kind and continue untouched.
            let running = unverifiedRevalidation.parkRunningRequestsUntilActive()
            for key in running {
                _ = downloadWorkRegistry.cancelRevalidationFinalizer(for: key)
            }
        }
    }

    /// Test/source compatibility for the previous string edge. Production lifecycle routing is
    /// typed through `RuntimeLifecycleCoordinator`.
    func noteAppScenePhase(_ phase: String) {
        noteAppSceneRecovery(
            phase == "active" ? .aggregateSceneBecameActive : .aggregateSceneBecameInactive)
    }

    /// Start the UI-rate lifecycle boundary independently of task recovery readiness. On a cold
    /// foreground launch, `startupRecoveryState` is not ready yet and the old placement inside
    /// `recoverStaticRangeTransfersAfterForeground` skipped #224 protection entirely. Include
    /// queued static rows captured before reconcile as well as rows already downloading; either can
    /// be the row whose first reattached/restarted callback exposes accumulated background bytes.
    private func beginDownloadRateForegroundRebaseline() {
        let now = Date()
        let interruptedStaticKeys = Set(store.interruptedStaticByteRangeKeys())
        let downloadingRecords = store.records.filter { $0.status == .downloading }
        for ratingKey in downloadingRecords.map(\.ratingKey) {
            rateEstimatorForegroundGraceUntil[ratingKey] = now.addingTimeInterval(4)
            downloadSpeed.removeValue(forKey: ratingKey)
            downloadETA.removeValue(forKey: ratingKey)
        }
        let downloadingStaticKeys = downloadingRecords.compactMap { record -> String? in
            record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .staticByteRange
                ? record.ratingKey
                : nil
        }
        for ratingKey in interruptedStaticKeys.union(downloadingStaticKeys) {
            rateEstimatorForegroundProgressPending[ratingKey] = now
        }
    }

    /// Re-run the same authoritative task reconciliation used at launch when a headset returns
    /// from sleep. A missing background task is converted to a resumable paused row and restarted
    /// automatically, which is the recovery users previously got only by Pause All → Resume All.
    private func recoverStaticRangeTransfersAfterForeground() {
        guard startupRecoveryState == .ready else { return }
        guard !foregroundStaticRangeRecoveryInFlight else { return }
        foregroundStaticRangeRecoveryInFlight = true

        let interruptedStaticKeys = store.interruptedStaticByteRangeKeys()

        // B.13: same snapshot rule as launch — rows created while `getAllTasks` runs are skipped.
        let snapshotRatingKeys = store.allRatingKeys
        session.reattach { [weak self, store] liveKeys in
            store.reconcile(liveRatingKeys: liveKeys, snapshotRatingKeys: snapshotRatingKeys)
            Task { @MainActor in
                guard let self else { return }
                self.foregroundStaticRangeRecoveryInFlight = false
                self.refreshRecords()
                guard !self.isQueuePaused else { return }
                self.resumeInterruptedStaticByteRangeDownloads(candidateKeys: interruptedStaticKeys,
                                                                liveKeys: liveKeys)
            }
        }
    }

    private func staticRangeBackendSession(for record: DownloadRecord) -> BackendSession? {
        let kind = DownloadJobSnapshot(record: record).backend
        guard let session = appModel.backendSession(for: kind) else { return nil }
        if let metadata = record.metadata, !session.matchesPersistedServer(metadata) {
            return nil
        }
        return session
    }

    private func attemptKey(for record: DownloadRecord) -> DownloadAttemptKey? {
        guard let attemptID = record.attemptID else { return nil }
        return DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
    }

    private func isDeletionPending(_ record: DownloadRecord) -> Bool {
        guard let key = attemptKey(for: record) else { return false }
        return store.isDeletionPending(for: key)
    }

    /// Exact Store checkpoint mutations can fail because the row was replaced/reset or because
    /// the resulting full snapshot did not commit. Both outcomes halt the caller before it creates
    /// dependent transfer work; a later refresh/retry will acquire a fresh row owner.
    private func resolveStaticRangeCheckpoint(
        for record: DownloadRecord,
        expectedBytes: Int? = nil,
        context: String,
        completion: @escaping (Int?) -> Void
    ) {
        guard let key = attemptKey(for: record) else { return }
        staticCheckpointResolutions.enqueue(key: key, operation: { [store] in
            let submission = store.submitStaticRangeCheckpointReset(
                for: key, expectedBytes: expectedBytes)
            return await store.resolveStaticCheckpoint(submission)
        }, completion: { [weak self] result in
            guard let self else { return }
            // The result belongs only to the exact owner captured by the queued request. Avoid
            // mutating manager trackers/errors when a replacement won while the worker was busy.
            guard store.record(for: key) != nil else {
                completion(nil)
                return
            }
            switch result {
            case .applied(let bytes), .unchanged(let bytes):
                completion(bytes)
            case .notStatic:
                completion(nil)
            case .staleOrMissing:
                recordDownloadDiagnostic("downloads.range_checkpoint_owner_stale", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "context": .label(context),
                ])
                completion(nil)
            case .persistenceFailed(_, let failure):
                recordDownloadDiagnostic("downloads.range_checkpoint_persist_failed", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "context": .label(context),
                    "failure": .label(Self.startupPersistenceFailureLabel(failure)),
                ])
                completion(nil)
            }
        })
    }

    func setAttemptStatus(
        _ status: DownloadStatus,
        for key: DownloadAttemptKey,
        context: String
    ) -> Bool {
        switch store.setStatus(for: key, status) {
        case .applied, .noChange:
            return true
        case .staleOrMissing:
            recordDownloadDiagnostic("downloads.status_owner_stale", fields: [
                "download_id": .identifier(key.ratingKey),
                "context": .label(context),
            ])
            return false
        case .persistenceFailed(let failure):
            recordDownloadDiagnostic("downloads.status_persist_failed", fields: [
                "download_id": .identifier(key.ratingKey),
                "context": .label(context),
                "failure": .label(Self.startupPersistenceFailureLabel(failure)),
            ])
            return false
        }
    }

    private func removeAttempt(_ key: DownloadAttemptKey, context: String) async -> Bool {
        switch await store.resolveRowDeletion(store.submitRemove(for: key)) {
        case .removed:
            return true
        case .staleOrMissing:
            recordDownloadDiagnostic("downloads.remove_owner_stale", fields: [
                "download_id": .identifier(key.ratingKey),
                "context": .label(context),
            ])
            return false
        case .persistenceFailed(_, let failure):
            recordDownloadDiagnostic("downloads.remove_persist_failed", fields: [
                "download_id": .identifier(key.ratingKey),
                "context": .label(context),
                "failure": .label(Self.startupPersistenceFailureLabel(failure)),
            ])
            return false
        case .cleanupFailed(_, let count):
            recordDownloadDiagnostic("downloads.remove_artifact_failed", fields: [
                "download_id": .identifier(key.ratingKey),
                "context": .label(context),
                "failure_count": .int(count),
            ])
            return false
        }
    }

    @discardableResult
    private func deferStaticRangeRetryIfBackendUnavailable(record: DownloadRecord, reason: String) -> Bool {
        guard StaticRangeRecoveryPolicy.isStaticRangeRecord(record) else {
            staticRangeRecovery.removePendingResume(record.ratingKey)
            return false
        }
        if staticRangeBackendSession(for: record) != nil {
            // Backend ready: KEEP the pendingResume handoff marker — retry() set it just before
            // calling here so the stale-queued detector leaves the row alone while the backend
            // entry point rebuilds the request. Removing it here re-exposed the still-queued row
            // to the detector, which re-drove retry in an endless loop on every refresh (the
            // async cousin of the #210 refresh⇄resume recursion). It is cleared when the transfer
            // starts or a no-start failure is surfaced.
            return false
        }
        deferStaticRangeResume(record: record, reason: reason)
        return true
    }

    private func deferStaticRangeResume(record: DownloadRecord,
                                        reason: String,
                                        preserveActiveIntent: Bool = false) {
        let ratingKey = record.ratingKey
        let backend = DownloadJobSnapshot(record: record).backend
        guard let key = attemptKey(for: record) else { return }
        resolveStaticRangeCheckpoint(for: record, context: "defer_resume") {
            [weak self] checkpointBytes in
            guard let self, let checkpointBytes else { return }
            switch StaticRangeRecoveryPolicy.deferredResumeDisposition(
                checkpointBytes: checkpointBytes,
                preserveActiveIntent: preserveActiveIntent
            ) {
            case .queuedActiveIntent:
                guard setAttemptStatus(.queued, for: key, context: "defer_resume") else { return }
                lastError[ratingKey] = checkpointBytes > 0
                    ? .interruptedResumable
                    : .transferFailed(
                        "Download will restart when the \(backend.displayName) session is ready.")
            case .pausedAtCheckpoint:
                guard setAttemptStatus(.paused, for: key, context: "defer_resume") else { return }
                lastError[ratingKey] = .interruptedResumable
            case .failedNoCheckpoint:
                guard setAttemptStatus(.failed, for: key, context: "defer_resume") else { return }
                lastError[ratingKey] = .transferFailed(
                    "No completed checkpoint was saved before the interruption; retry will restart this download from 0%.")
            }
            // Status compare-and-set is the final exact-owner fence before manager-only trackers
            // are changed; no suspension occurs between this point and those mutations.
            staticRangeRecovery.addPendingResume(ratingKey)
            clearRetryHandoff(ratingKey: ratingKey)
            retryState.removeRetrying(ratingKey)
            recordDownloadDiagnostic("downloads.range_resume_deferred", fields: [
                "download_id": .identifier(ratingKey),
                "backend": .label(backend.rawValue),
                "reason": .label(reason),
                "checkpoint_bytes": .bytes(checkpointBytes),
            ])
            refreshRecords()
        }
    }


    private func finalizeCompletedStaticRangeIfNeeded(record: DownloadRecord, reason: String) -> Bool {
        let ratingKey = record.ratingKey
        guard let key = attemptKey(for: record),
              !store.isDeletionPending(for: key),
              let checkpointBytes = store.durableStaticRangeCheckpointSize(for: key) else {
            return false
        }
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
        // Backstop for the #210 family: this function and refreshRecords dispatch each other
        // synchronously on purpose (see the stale-queued comment in refreshRecords), and a marker
        // bookkeeping bug turns that pair into unbounded mutual recursion — it has blown the
        // main-thread stack twice now. Legitimate nesting is depth ≤ 2 (refresh → resume →
        // its own refresh), so bail loudly past that instead of crashing; the pendingResume
        // marker survives the bail and a later sweep re-drives the row.
        guard staticResumeReentryDepth < 3 else {
            recordDownloadDiagnostic("downloads.range_resume_reentry_bailout", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(reason),
                "depth": .int(staticResumeReentryDepth),
            ])
            return
        }
        staticResumeReentryDepth += 1
        defer { staticResumeReentryDepth -= 1 }
        if StaticRangeRecoveryPolicy.shouldWaitForManualResume(
            isQueuePaused: isQueuePaused,
            wasManuallyResumedWhileQueuePaused: staticRangeRecovery.wasManuallyResumedWhileQueuePaused(ratingKey)
        ) {
            guard let record = store.record(for: ratingKey) else {
                staticRangeRecovery.removePendingResume(ratingKey)
                return
            }
            guard StaticRangeRecoveryPolicy.isStaticRangeRecord(record) else {
                staticRangeRecovery.removePendingResume(ratingKey)
                return
            }
            guard let key = attemptKey(for: record) else { return }
            resolveStaticRangeCheckpoint(for: record, context: "queue_paused") {
                [weak self] checkpointBytes in
                guard let self, let checkpointBytes else { return }
                if checkpointBytes > 0 {
                    guard setAttemptStatus(
                        .paused, for: key, context: "queue_paused") else { return }
                    lastError[ratingKey] = .interruptedResumable
                }
                staticRangeRecovery.removePendingResume(ratingKey)
                recordDownloadDiagnostic("downloads.range_resume_queue_paused", fields: [
                    "download_id": .identifier(ratingKey),
                    "reason": .label(reason),
                    "checkpoint_bytes": .bytes(checkpointBytes),
                ])
                refreshRecords()
            }
            return
        }
        guard let record = store.record(for: ratingKey) else {
            staticRangeRecovery.removePendingResume(ratingKey)
            return
        }
        guard StaticRangeRecoveryPolicy.isStaticRangeRecord(record) else {
            staticRangeRecovery.removePendingResume(ratingKey)
            return
        }
        guard let key = attemptKey(for: record) else { return }
        guard !store.isDeletionPending(for: key) else {
            staticRangeRecovery.removePendingResume(ratingKey)
            staticRangeRecovery.unmarkFinalizing(ratingKey)
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
        guard let checkpointBytes = store.durableStaticRangeCheckpointSize(for: key) else { return }
        staticRangeRecovery.addPendingResume(ratingKey)
        recordDownloadDiagnostic("downloads.range_resume_ready", fields: [
            "download_id": .identifier(ratingKey),
            "backend": .label(DownloadJobSnapshot(record: record).backend.rawValue),
            "reason": .label(reason),
            "checkpoint_bytes": .bytes(checkpointBytes),
        ])
        if retryState.isRetrying(ratingKey) {
            return
        }
        // A relaunch-adopted range task can leave app-level retry/active bookkeeping behind even though
        // URLSession has no live task and the row is merely a queued continuation intent. Clear that
        // presentation/handoff state before driving the backend retry, or `retry` can no-op and the
        // user has to manually Pause→Resume to kick the exact same request.
        retryState.removeRetrying(ratingKey)
        clearRetryHandoff(ratingKey: ratingKey)
        if StaticRangeRecoveryPolicy.shouldPreserveRangeRestartCounters(reason: reason) {
            staticRangeRecovery.preserveRestartCountersForNextStart(ratingKey)
        }
        refreshRecords()
        retry(ratingKey: ratingKey,
              allowReplacingExistingActiveRow: StaticRangeRecoveryPolicy.shouldMarkSystemResumeInactiveBeforeRetry(record))
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
        guard startupRecoveryState == .ready else { return }
        let keys = staticRangeRecovery.resumablePendingKeys(isQueuePaused: isQueuePaused)
        guard !keys.isEmpty else { return }
        for key in keys.sorted() {
            recordDownloadDiagnostic("downloads.range_auto_resume", fields: [
                "download_id": .identifier(key),
                "reason": .label("backend_ready"),
            ])
            resumeStaticRangeWhenReady(ratingKey: key, reason: "backend_ready")
        }
    }

    /// Retry a previously `.failed` download (D3/D5). We rebuild the source `MediaItem`
    /// from the persisted `OfflineMetadata` snapshot (real type + media/part index) and
    /// re-run the probe-driven download path — re-probing so a now-compatible file goes
    /// direct. Rows persisted before D5 lack a snapshot, so we fall back to a minimal movie.
    public func retry(ratingKey: String, allowReplacingExistingActiveRow: Bool = false) {
        guard let record = records.first(where: { $0.ratingKey == ratingKey }) else { return }
        retry(record: record, allowReplacingExistingActiveRow: allowReplacingExistingActiveRow)
    }

    /// Execute a rendered row's retry/resume only while its exact persisted attempt still owns
    /// the key. This fence is checked before any retry trackers or transfer state are mutated.
    @discardableResult
    public func retry(
        _ identity: OfflineDownloadRowActionIdentity,
        allowReplacingExistingActiveRow: Bool = false
    ) -> Bool {
        guard let record = currentRecord(for: identity) else { return false }
        retry(record: record, allowReplacingExistingActiveRow: allowReplacingExistingActiveRow)
        return true
    }

    private func retry(record: DownloadRecord, allowReplacingExistingActiveRow: Bool) {
        let ratingKey = record.ratingKey
        guard startupRecoveryState == .ready else {
            lastError[ratingKey] = .transferFailed(
                "Downloads are paused while recovery is completed. Retry recovery first."
            )
            return
        }
        guard !retryState.isRetrying(ratingKey) else { return }
        guard let currentKey = attemptKey(for: record),
              !store.isDeletionPending(for: currentKey) else { return }
        setOptionalSideAssetHydrationParked(false, for: currentKey)
        guard record.status != .complete, record.status != .unverified else { return }
        let shouldPromotePausedStatic = StaticRangeRecoveryPolicy.shouldMarkPausedRowInactiveBeforeBackendRetry(record)
        let shouldReplacePersistedActiveStatic = allowReplacingExistingActiveRow
            || StaticRangeRecoveryPolicy.shouldMarkSystemResumeInactiveBeforeRetry(record)
        let allowActiveRowReplacement = shouldPromotePausedStatic || shouldReplacePersistedActiveStatic
        if allowActiveRowReplacement {
            // Keep refresh reconciliation from re-classifying this queued/downloading static row as
            // stale while the backend entry point is still rebuilding PlaybackInfo and before
            // URLSession has been re-acquired. The marker is cleared once a transfer starts or an
            // immediate start failure is surfaced.
            staticRangeRecovery.addPendingResume(ratingKey)
        }
        let isManualStaticResumeWhileQueuePaused = DownloadRetryPreparationPolicy.isManualStaticResumeWhileQueuePaused(
            isQueuePaused: isQueuePaused,
            isStaticRangeRecord: StaticRangeRecoveryPolicy.isStaticRangeRecord(record),
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
        // Lens 6 F5: retry continuations are attempt-scoped. Each begin mints a token the async
        // bodies below verify, so a pause→resume (which re-begins) cannot revive THIS chain after
        // it was superseded.
        let retryToken = retryState.begin(ratingKey)
        guard let retryAttemptKey = attemptKey(for: record) else {
            retryState.removeRetrying(ratingKey)
            return
        }
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
            isEmbyRecord: DownloadRecordIdentity.isEmbyRecordKey(ratingKey),
            hasEmbyConvertJobID: record.metadata?.embyConvertJobID != nil,
            hasEmbyConvertRecoveryIdentity: record.metadata?.hasEmbyConvertRecoveryIdentity == true
        ) {
            guard setAttemptStatus(
                .preparing, for: retryAttemptKey, context: "retry_emby_convert") else {
                retryState.removeRetrying(ratingKey)
                return
            }
            resumePendingEmbyConvertDownloads()
            refreshRecords()
            return
        }
        let persistedResumeData = store.resumeData(for: retryAttemptKey)
        let supportsPersistedResumeData =
            record.metadata?.resolvedResumeMode(ratingKey: ratingKey) != .liveForwardOnly
        if DownloadRetryPreparationPolicy.shouldResumePersistedURLSessionData(
            status: record.status,
            supportsPersistedResumeData: supportsPersistedResumeData,
            hasResumeData: persistedResumeData != nil
        ), let resumeData = persistedResumeData {
            // Consume the blob path, but keep its display watermark until the resumed task proves
            // equal/greater progress. URLSession can report a blob-resumed download task's
            // `countOfBytesReceived` from near zero even while it still owns a large resumable temp
            // body; clearing the watermark here made the Offline UI flash 0% / tiny bytes on Resume.
            switch store.clearResumeData(for: retryAttemptKey, clearDisplayBytes: false) {
            case .applied, .noChange:
                break
            case .staleOrMissing:
                retryState.removeRetrying(ratingKey)
                return
            case .persistenceFailed(let failure):
                recordDownloadDiagnostic("downloads.resume_manifest_clear_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "failure": .label(Self.startupPersistenceFailureLabel(failure)),
                ])
                retryState.removeRetrying(ratingKey)
                return
            }
            guard setAttemptStatus(
                .downloading, for: retryAttemptKey, context: "resume_blob") else {
                retryState.removeRetrying(ratingKey)
                return
            }
            // #227: static range rows with persisted resume data MUST resume on the
            // range lane; the opaque lane would treat the blob task's partial-body temp as a
            // whole-file move at completion and corrupt the durable partial.
            let lane = DownloadRetryPreparationPolicy.persistedResumeDataLane(
                resumeMode: record.metadata?.resolvedResumeMode(ratingKey: ratingKey)
            )
            let resumed: Bool
            switch lane {
            case .staticRange:
                resumed = session.resumeRange(
                    ratingKey: ratingKey,
                    resumeData: resumeData,
                    expectedBytes: BackgroundDownloadProgressPolicy.derivedExpectedBytes(record)
                )
            case .opaque:
                resumed = session.resume(ratingKey: ratingKey, resumeData: resumeData)
            }
            if resumed {
                activeJobs.insert(ratingKey)
                inFlightAttempts.acquire(retryAttemptKey)
                // The original terminal failure released and cancelled best-effort side-cache
                // work. A resume-data retry restarts only the media URLSession task and returns
                // before the normal backend entry points run, so explicitly restart any missing
                // poster/chapter/trick-play/subtitle hydration for this exact persisted attempt.
                rehydrateMissingOptionalSideAssets(record: record,
                                                    attemptKey: retryAttemptKey,
                                                    reason: "transfer_resume")
                refreshRecords()
                return
            }
            // The blob was refused/stale — fall through to a clean restart below (for range rows
            // the durable partial remains the checkpoint; only the blob's temp is lost).
            guard setAttemptStatus(
                .failed, for: retryAttemptKey, context: "resume_blob_refused") else {
                retryState.removeRetrying(ratingKey)
                return
            }
        }
        if DownloadRetryPreparationPolicy.shouldResumePausedPlexServerPrep(
            status: record.status,
            resumeMode: record.metadata?.resolvedResumeMode(ratingKey: ratingKey),
            isJellyfinRecord: DownloadRecordIdentity.isJellyfinRecordKey(ratingKey),
            isEmbyRecord: DownloadRecordIdentity.isEmbyRecordKey(ratingKey),
            optimizeTargetName: record.metadata?.optimizeTargetName,
            hasIncompleteStaticPartial: DownloadRetryPolicy.shouldPromotePausedStaticPartial(record)
        ), let targetName = record.metadata?.optimizeTargetName {
            resumePausedPlexServerPrep(record: record, targetName: targetName)
            return
        }
        // #131/#146/#168/#169 live checks: paused static-byte-range rows may have only the durable
        // partial file as their checkpoint (no URLSession resume blob), or may have no durable bytes
        // yet (user paused before the first range body committed / validator restart from zero). Promote
        // them out of `.paused` before backend-specific retry dispatch, because Jellyfin/Emby retry
        // bodies also pass through `retryAttemptCanContinue`; if the row is still `.paused`, that
        // async guard treats the user's Resume tap as cancelled and silently no-ops.
        if shouldPromotePausedStatic {
            // A partial static retry is not active yet; it is about to re-acquire a URLSession task
            // against the same destination file. Keep the visible row as queued while letting the
            // backend entry point intentionally replace this persisted active intent, instead of
            // briefly showing user-visible `.failed` as a retry trampoline.
            guard setAttemptStatus(
                .queued, for: retryAttemptKey, context: "retry_static") else {
                retryState.removeRetrying(ratingKey)
                return
            }
        }
        if DownloadRecordIdentity.isJellyfinRecordKey(ratingKey) {
            retryJellyfin(record: record, allowReplacingExistingActiveRow: allowActiveRowReplacement,
                          attemptToken: retryToken)
            return
        }
        if DownloadRecordIdentity.isEmbyRecordKey(ratingKey) {
            retryEmby(record: record, allowReplacingExistingActiveRow: allowActiveRowReplacement,
                      attemptToken: retryToken)
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
                guard self.setAttemptStatus(
                    .failed, for: retryAttemptKey, context: "retry_auth") else { return }
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
                self.releaseInFlight(for: retryAttemptKey)
            }
            let currentItem = await self.fetchCurrentMediaItem(ratingKey: ratingKey,
                                                               server: server,
                                                               token: token,
                                                               identity: self.appModel.identity) ?? item
            guard self.retryAttemptCanContinue(for: retryAttemptKey, token: retryToken) else { return }

            // #131/#184: static retries must preserve the exact Part identity whenever possible,
            // not only when a durable partial exists. Plex optimized/final static rows keep
            // `sourcePartID`/serverPreparedVersion after restart; re-probing them can create or
            // chase a different optimize job and leave the user tapping repeatedly. Route back to
            // the persisted static target, preserving the partial when present and otherwise
            // redownloading the same existing Part from byte 0.
            if StaticRangeRecoveryPolicy.isStaticRangeRecord(record),
               (DownloadRetryPolicy.shouldPromotePausedStaticPartial(record) || metadata?.sourcePartID != nil || metadata?.isServerPreparedVersion == true) {
                let resolved = self.resolveStaticRetryTarget(record: record,
                                                            fallbackMediaIndex: mediaIndex,
                                                            fallbackPartIndex: partIndex,
                                                            in: currentItem)
                guard let retryChoice = resolved.choice else {
                    self.recordDownloadDiagnostic("downloads.retry_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "backend": .label("Plex"),
                        "reason": .label("persisted_source_part_missing"),
                    ])
                    self.lastError[ratingKey] = .transferFailed(
                        "The saved server version is no longer available. Choose another version and retry.")
                    self.clearStaticRangePendingResume(ratingKey: ratingKey)
                    self.releaseInFlight(for: retryAttemptKey)
                    guard self.setAttemptStatus(
                        .failed, for: retryAttemptKey, context: "retry_part_missing") else { return }
                    self.refreshRecords()
                    return
                }
                self.releaseInFlight(for: retryAttemptKey)
                // Keep the row in place even when there is no durable media partial yet. `upsert`
                // preserves cached poster/chapter/trickplay paths, while the static Range lane resumes
                // from the durable file size (0 when no checkpoint exists). Removing here made Plex
                // existing-version retries forget side materials and appear to restart from scratch.
                await self.download(currentItem, choice: retryChoice,
                                    mediaIndex: resolved.mediaIndex, partIndex: resolved.partIndex,
                                    audioStreamIndex: metadata?.audioStreamIndex,
                                    allowReplacingExistingActiveRow: allowActiveRowReplacement)
                self.refreshRecords()
                return
            }

            // #112: legacy rows without sourcePartID that downloaded an EXISTING server version
            // retry by re-downloading that same non-source Media index as-is.
            if mediaIndex > 0,
               metadata?.resolvedDownloadLane() == .original,
               currentItem.media?.indices.contains(mediaIndex) == true {
                self.releaseInFlight(for: retryAttemptKey)
                // Preserve side materials for the same static existing-version row; the replacement
                // upsert updates transfer fields without deleting cached assets.
                await self.download(currentItem, choice: .existingVersion,
                                    mediaIndex: mediaIndex, partIndex: partIndex,
                                    audioStreamIndex: metadata?.audioStreamIndex,
                                    allowReplacingExistingActiveRow: allowActiveRowReplacement)
                self.refreshRecords()
                return
            }
            let probe = await self.directPlayProbe(for: currentItem, server: server, token: token,
                                                   mediaIndex: mediaIndex, partIndex: partIndex)
            let media = currentItem.media?.indices.contains(mediaIndex) == true ? currentItem.media?[mediaIndex] : currentItem.media?.first
            let part = probe.part ?? (media?.part.indices.contains(partIndex) == true ? media?.part[partIndex] : media?.part.first)
            let choice: DownloadChoice = (probe.direct && OfflineDownloadDecision.isLocallyPlayableOriginal(part: part))
                ? .original
                : .optimize(targetName: Self.originalFallbackOptimizeTarget())
            // Drop the stale `.failed` row only once we know the replacement can be seeded.
            // This also removes any leftover invalid/partial file from the failed attempt.
            guard self.retryAttemptCanContinue(for: retryAttemptKey, token: retryToken) else { return }
            self.releaseInFlight(for: retryAttemptKey)
            if !DownloadRetryPolicy.shouldPromotePausedStaticPartial(record) {
                guard await self.removeAttempt(retryAttemptKey, context: "retry_replace") else { return }
            }
            await self.download(currentItem, choice: choice, mediaIndex: mediaIndex, partIndex: partIndex,
                                audioStreamIndex: metadata?.audioStreamIndex,
                                allowReplacingExistingActiveRow: allowActiveRowReplacement)
            self.refreshRecords()
        }
    }

    /// Lens 6 F5: `token` scopes the guard to the CALLER's retry attempt — a superseded chain
    /// stays dead even after pause→resume re-begins retrying for the same key. `nil` preserves the
    /// legacy any-current-attempt semantics for paths that predate token threading.
    private func retryAttemptCanContinue(
        for key: DownloadAttemptKey,
        token: UUID? = nil
    ) -> Bool {
        let row = store.record(for: key)
        let attemptIsCurrent = token.map {
            retryState.isCurrentRetryAttempt(key.ratingKey, id: $0)
        } ?? retryState.isRetrying(key.ratingKey)
        return DownloadRetryPreparationPolicy.attemptCanContinue(
            isRetrying: attemptIsCurrent,
            rowIsPresent: row != nil,
            rowStatus: row?.status
        )
    }

    private func resolveStaticRetryTarget(record: DownloadRecord,
                                          fallbackMediaIndex: Int,
                                          fallbackPartIndex: Int,
                                          in item: MediaItem) -> (choice: DownloadChoice?, mediaIndex: Int, partIndex: Int) {
        let target = DownloadStaticRetryTargetPolicy.target(metadata: record.metadata,
                                                            item: item,
                                                            fallbackMediaIndex: fallbackMediaIndex,
                                                            fallbackPartIndex: fallbackPartIndex)
        let choice: DownloadChoice?
        switch target.intent {
        case .original: choice = .original
        case .existingVersion: choice = .existingVersion
        case .unavailable: choice = nil
        }
        return (choice,
                target.mediaIndex,
                target.partIndex)
    }

    /// Resume a paused Plex server-prep row by reattaching to its existing optimize queue item.
    ///
    /// Do not call `retryPausedPlexOptimize` here: that path creates a fresh optimize request after
    /// fetching current metadata. A server-prep row already has the queue title/baseline needed by
    /// `resumePendingServerPrepDownloads`, so recreating risks a duplicate Plex transcode.
    private func resumePausedPlexServerPrep(record: DownloadRecord, targetName: String) {
        guard let key = attemptKey(for: record) else { return }
        guard let backendSession = appModel.backendSession(for: .plex) else {
            lastError[record.ratingKey] = .notAuthenticated
            clearRetryHandoff(ratingKey: record.ratingKey)
            retryState.removeRetrying(record.ratingKey)
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
            retryState.removeRetrying(record.ratingKey)
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
        retryState.removeRetrying(record.ratingKey)
        clearRetryHandoff(ratingKey: record.ratingKey)
        guard setAttemptStatus(.queued, for: key, context: "plex_prep_resume") else { return }
        optimizeState[record.ratingKey] = DownloadOptimizeStateLabel.queued
        refreshRecords()
        resumePendingServerPrepDownloads(allowWhileQueuePaused: true)
    }

    private func retryPausedPlexOptimize(record: DownloadRecord, targetName: String) {
        guard let key = attemptKey(for: record) else { return }
        let metadata = record.metadata
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: record.ratingKey, title: record.title, type: "movie")
        let mediaIndex = metadata?.mediaIndex ?? 0
        let partIndex = metadata?.partIndex ?? 0
        Task { [weak self] in
            guard let self else { return }
            guard let backendSession = self.appModel.backendSession(for: .plex) else {
                self.lastError[record.ratingKey] = .notAuthenticated
                _ = self.setAttemptStatus(.paused, for: key, context: "plex_optimize_auth")
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
                _ = self.setAttemptStatus(.paused, for: key, context: "plex_optimize_server")
                self.refreshRecords()
                return
            }
            let currentItem = await self.fetchCurrentMediaItem(ratingKey: record.ratingKey,
                                                               server: backendSession.baseURL,
                                                               token: backendSession.token,
                                                               identity: self.appModel.identity) ?? item
            guard self.retryAttemptCanContinue(for: key) else { return }
            self.recordDownloadDiagnostic("downloads.paused_optimize_resume", fields: [
                "download_id": .identifier(record.ratingKey),
                "target": .label(targetName),
            ])
            self.releaseInFlight(for: key)
            if !DownloadRetryPolicy.shouldPromotePausedStaticPartial(record) {
                guard await self.removeAttempt(key, context: "plex_optimize_replace") else { return }
            }
            await self.download(currentItem, choice: .optimize(targetName: targetName),
                                mediaIndex: mediaIndex, partIndex: partIndex,
                                audioStreamIndex: record.metadata?.audioStreamIndex)
            self.refreshRecords()
        }
    }

    private func retryJellyfin(record: DownloadRecord, allowReplacingExistingActiveRow: Bool = false,
                               attemptToken: UUID) {
        guard let key = attemptKey(for: record) else { return }
        let retryIntent = DownloadBackendRetryIntentPolicy.jellyfinIntent(
            for: record,
            fallbackItemID: DownloadRecordIdentity.jellyfinItemID(fromRecordKey: record.ratingKey),
            fallbackOriginalIsLocallyPlayable: false)

        Task { [weak self] in
            guard let self else { return }
            // #84: gate on the Jellyfin lane being configured (resolved from its own session),
            // independent of `activeBackend`; an unconfigured lane stays retryable with the
            // accurate not-signed-in reason.
            guard let backendSession = self.appModel.backendSession(for: .jellyfin) else {
                if self.deferStaticRangeRetryIfBackendUnavailable(record: record,
                                                                  reason: "jellyfin_backend_not_ready") {
                    return
                }
                self.clearRetryHandoff(ratingKey: record.ratingKey)
                self.lastError[record.ratingKey] = .notAuthenticated
                _ = self.setAttemptStatus(.failed, for: key, context: "jellyfin_retry_auth")
                self.refreshRecords()
                return
            }
            // A-5 (audit lens 8): a lane pointed at a DIFFERENT Jellyfin server must defer, not
            // retry — a forward-only/convert row replayed against a foreign server fails with a
            // misleading 404. Static-range rows park via the deferred-resume path; others keep
            // the retry affordance with an accurate reason.
            if let metadata = record.metadata, !backendSession.matchesPersistedServer(metadata) {
                if self.deferStaticRangeRetryIfBackendUnavailable(record: record,
                                                                  reason: "jellyfin_session_mismatch") {
                    return
                }
                self.recordDownloadDiagnostic("downloads.retry_deferred", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "backend": .label("Jellyfin"),
                    "reason": .label("jellyfin_session_mismatch"),
                ])
                self.clearRetryHandoff(ratingKey: record.ratingKey)
                self.retryState.removeRetrying(record.ratingKey)
                self.lastError[record.ratingKey] = .transferFailed(
                    "Waiting for the original Jellyfin server session.")
                _ = self.setAttemptStatus(.failed, for: key, context: "jellyfin_retry_server")
                self.refreshRecords()
                return
            }
            if self.activeJobs.contains(record.ratingKey) {
                self.recordDownloadDiagnostic("downloads.inflight_recovered", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "backend": .label("Jellyfin"),
                    "reason": .label("retry_failed_row"),
                ])
                self.releaseInFlight(for: key)
            }
            guard self.retryAttemptCanContinue(for: key, token: attemptToken) else { return }
            // Keep the failed row visible until `downloadJellyfin` successfully seeds the
            // replacement. If PlaybackInfo/auth/network preflight fails, its start-failed path can
            // mark this existing row `.failed` instead of making the retry affordance disappear.
            await self.downloadJellyfin(retryIntent.item, choice: retryIntent.choice,
                                        mediaIndex: retryIntent.mediaIndex,
                                        partIndex: retryIntent.partIndex,
                                        audioStreamIndex: retryIntent.audioStreamIndex,
                                        mediaSourceIDOverride: retryIntent.mediaSourceIDOverride,
                                        allowReplacingExistingActiveRow: allowReplacingExistingActiveRow)
            self.refreshRecords()
        }
    }

    private func retryEmby(record: DownloadRecord, allowReplacingExistingActiveRow: Bool = false,
                           attemptToken: UUID) {
        guard let key = attemptKey(for: record) else { return }
        let retryIntent = DownloadBackendRetryIntentPolicy.embyIntent(
            for: record,
            fallbackItemID: DownloadRecordIdentity.embyItemID(fromRecordKey: record.ratingKey))

        Task { [weak self] in
            guard let self else { return }
            // #84: gate on the Emby lane being configured (resolved from its own session),
            // independent of `activeBackend`; an unconfigured lane stays retryable with the
            // accurate not-signed-in reason.
            guard let backendSession = self.appModel.backendSession(for: .emby) else {
                if self.deferStaticRangeRetryIfBackendUnavailable(record: record,
                                                                  reason: "emby_backend_not_ready") {
                    return
                }
                self.clearRetryHandoff(ratingKey: record.ratingKey)
                self.lastError[record.ratingKey] = .notAuthenticated
                _ = self.setAttemptStatus(.failed, for: key, context: "emby_retry_auth")
                self.refreshRecords()
                return
            }
            // A-5 (audit lens 8): same server-identity guard as the Jellyfin retry funnel — a
            // convert/forward-only row retried against a different Emby server defers with an
            // accurate reason instead of failing with a foreign 404.
            if let metadata = record.metadata, !backendSession.matchesPersistedServer(metadata) {
                if self.deferStaticRangeRetryIfBackendUnavailable(record: record,
                                                                  reason: "emby_session_mismatch") {
                    return
                }
                self.recordDownloadDiagnostic("downloads.retry_deferred", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "backend": .label("Emby"),
                    "reason": .label("emby_session_mismatch"),
                ])
                self.clearRetryHandoff(ratingKey: record.ratingKey)
                self.retryState.removeRetrying(record.ratingKey)
                self.lastError[record.ratingKey] = .transferFailed(
                    "Waiting for the original Emby server session.")
                _ = self.setAttemptStatus(.failed, for: key, context: "emby_retry_server")
                self.refreshRecords()
                return
            }
            if self.activeJobs.contains(record.ratingKey) {
                self.recordDownloadDiagnostic("downloads.inflight_recovered", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "backend": .label("Emby"),
                    "reason": .label("retry_failed_row"),
                ])
                self.releaseInFlight(for: key)
            }
            guard self.retryAttemptCanContinue(for: key, token: attemptToken) else { return }
            // Keep the failed row visible until `downloadEmby` successfully seeds the replacement.
            // If PlaybackInfo/auth/network preflight fails, its start-failed path can mark this
            // existing row `.failed` instead of making the retry affordance disappear.
            await self.downloadEmby(retryIntent.item, choice: retryIntent.choice,
                                    mediaIndex: retryIntent.mediaIndex,
                                    partIndex: retryIntent.partIndex,
                                    audioStreamIndex: retryIntent.audioStreamIndex,
                                    mediaSourceIDOverride: retryIntent.mediaSourceIDOverride,
                                    allowReplacingExistingActiveRow: allowReplacingExistingActiveRow)
            self.refreshRecords()
        }
    }

    /// Re-hydrate `.preparing` Emby convert rows after an app relaunch and RESUME polling their
    /// server-side Sync job (rather than restarting the conversion — it runs server-side and
    /// survives app death, which is the whole point of this lane). A `.failed` row retaining a
    /// complete pre-POST recovery identity also re-enters recovery here; it must never blind-POST a
    /// replacement. Idempotent: a row already being polled (`activeJobs`) is skipped. Best-effort —
    /// a row whose Emby lane is signed out stays parked and resumes once the lane returns.
    private func resumePendingEmbyConvertDownloads() {
        guard startupRecoveryState == .ready else { return }
        // Use the store's current rows, not the published `records` snapshot. Manual Resume paths
        // mutate the store and then call this immediately; reading stale published rows can skip the
        // just-promoted `.preparing` record and strand it until another lifecycle edge.
        let embyPreparing = store.records.filter { record in
            guard !isDeletionPending(record) else { return false }
            let backend = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
                ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
            let hasCrashWindowIdentity = record.metadata?.hasEmbyConvertCrashWindowIdentity == true
            return (record.status == .preparing || (record.status == .failed && hasCrashWindowIdentity))
                && backend == .emby
                && record.metadata?.resolvedDownloadLane() == .optimize
                && !activeJobs.contains(record.ratingKey)
        }
        // First prove the canonical queue is readable. Treating read/decode failure as empty could
        // resume a row whose delete intent is hidden in that queue.
        switch store.loadEmbyConvertCleanupTombstones() {
        case .loaded:
            break
        case .failed(let failure):
            recordDownloadDiagnostic("downloads.convert_cleanup_deferred", fields: [
                "reason": .label("tombstone_\(failure.stage.rawValue)_failed"),
                "error_type": .label(failure.errorType),
            ])
            refreshRecords()
            return
        }

        // Re-attempt exact-ID tombstones whose durable write failed at delete time. Keep failed
        // values in memory, but include the pre-retry snapshot in this sweep even if persistence
        // succeeds so cleanup is not delayed until another lifecycle edge.
        let deferredForSweep = deferredEmbyCleanupTombstones
        var committedDeferredIDs = Set<UUID>()
        for tombstone in deferredForSweep {
            switch store.addEmbyConvertCleanupTombstone(tombstone) {
            case .committed:
                committedDeferredIDs.insert(tombstone.id)
            case .failed(let failure):
                recordDownloadDiagnostic("downloads.convert_cleanup_deferred", fields: [
                    "download_id": .identifier(tombstone.ratingKey),
                    "reason": .label("tombstone_\(failure.stage.rawValue)_failed"),
                    "error_type": .label(failure.errorType),
                ])
            }
        }
        deferredEmbyCleanupTombstones.removeAll { committedDeferredIDs.contains($0.id) }

        let durableTombstones: [DownloadStore.EmbyConvertCleanupTombstone]
        switch store.loadEmbyConvertCleanupTombstones() {
        case .loaded(let values):
            durableTombstones = values
        case .failed(let failure):
            recordDownloadDiagnostic("downloads.convert_cleanup_deferred", fields: [
                "reason": .label("tombstone_\(failure.stage.rawValue)_failed"),
                "error_type": .label(failure.errorType),
            ])
            refreshRecords()
            return
        }
        var seenCleanupIDs = Set<UUID>()
        let cleanupTombstones = (durableTombstones + deferredForSweep).filter {
            seenCleanupIDs.insert($0.id).inserted
        }
        guard !embyPreparing.isEmpty || !cleanupTombstones.isEmpty else {
            refreshRecords()
            return
        }
        guard let session = appModel.backendSession(for: .emby),
              let userId = session.userID else {
            recordDownloadDiagnostic("downloads.convert_resume_skip", fields: [
                "candidate_count": .int(embyPreparing.count + cleanupTombstones.count),
                "reason": .label("emby_session_unavailable"),
            ])
            refreshRecords()
            return
        }
        let server = session.baseURL
        let token = session.token
        let identity = appModel.identity.emby
        for tombstone in cleanupTombstones
            where session.matchesPersistedServer(tombstone.metadata) {
            Task { [weak self] in
                await self?.recoverAndCancelEmbyConvertTombstone(
                    tombstone, server: server, token: token, identity: identity,
                    currentUserID: userId)
            }
        }
        for record in embyPreparing {
            guard let metadata = record.metadata,
                  metadata.resolvedBackendKind(ratingKey: record.ratingKey) == .emby,
                  let key = attemptKey(for: record) else { continue }
            guard session.matchesPersistedServer(metadata) else {
                var fields: [String: DiagnosticFieldValue] = [
                    "download_id": .identifier(record.ratingKey),
                    "reason": .label("emby_session_mismatch"),
                ]
                if let jobId = metadata.embyConvertJobID { fields["job_id"] = .int(jobId) }
                recordDownloadDiagnostic("downloads.convert_resume_skip", fields: fields)
                continue
            }
            let ratingKey = record.ratingKey
            let targetName = metadata.optimizeTargetName ?? ""
            // Use the FULL pre-conversion File-source snapshot persisted at trigger time so the
            // freshly converted source is identified as "not in the snapshot" even when a PRIOR
            // converted version already existed. Fall back to the original source id alone for rows
            // written before the snapshot was persisted; the h264/mp4 recency heuristic in
            // `finishEmbyConvert` covers any residual ambiguity. `makeMediaItem` rebuilds the item.
            let item = metadata.makeMediaItem()
            let resumeSnapshot: Set<String> = metadata.embyConvertSnapshotIDs.map { Set($0) }
                ?? (metadata.mediaSourceID.map { [$0] } ?? [])

            switch EmbyConvertRecoveryPolicy.relaunchAction(
                jobID: metadata.embyConvertJobID,
                baselineJobIDs: metadata.embyConvertJobBaselineIDs,
                fingerprint: metadata.embyConvertRecoveryFingerprint,
                attemptStartedAtEpochSeconds: metadata.embyConvertRecoveryStartedAtEpochSeconds,
                phase: metadata.embyConvertRecoveryPhase) {
            case .poll(let jobId):
                activeJobs.insert(ratingKey)
                inFlightAttempts.acquire(key)
                let attemptID = beginEmbyConvertAttempt(for: key)
                recordDownloadDiagnostic("downloads.convert_resume", fields: [
                    "download_id": .identifier(ratingKey),
                    "job_id": .int(jobId),
                ])
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.pollAndDownloadEmbyConvertJob(
                        item: item, ratingKey: ratingKey, jobId: jobId,
                        snapshotIds: resumeSnapshot, targetName: targetName, server: server,
                        token: token, identity: identity, userId: userId,
                        audioStreamIndex: metadata.audioStreamIndex,
                        attemptKey: key, attemptID: attemptID)
                }
                registerServerPrepPollerTask(task, for: key)
            case .recover(let baseline, let fingerprint, let startedAt, let recoveryPhase):
                guard EmbyConvertRecoveryPolicy.publicUserMatches(
                    currentSessionUserID: userId,
                    persistedBackendUserID: metadata.backendUserID,
                    fingerprintUserID: fingerprint.userId) else {
                    recordDownloadDiagnostic("downloads.convert_resume_skip", fields: [
                        "download_id": .identifier(ratingKey),
                        "reason": .label("emby_user_mismatch"),
                    ])
                    continue
                }
                // A prior bounded/list attempt may have parked this row failed while preserving
                // ownership evidence. Relaunch/retry re-enters recovery, never a blind new POST.
                guard setAttemptStatus(
                    .preparing, for: key, context: "emby_convert_recover") else { continue }
                activeJobs.insert(ratingKey)
                inFlightAttempts.acquire(key)
                let attemptID = beginEmbyConvertAttempt(for: key)
                recordDownloadDiagnostic("downloads.convert_recovery", fields: [
                    "download_id": .identifier(ratingKey),
                    "baseline_count": .int(baseline.count),
                ])
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.recoverAndResumeEmbyConvertJob(
                        item: item, ratingKey: ratingKey, baselineJobIDs: Set(baseline),
                        fingerprint: fingerprint, attemptStartedAtEpochSeconds: startedAt,
                        recoveryPhase: recoveryPhase, snapshotIds: resumeSnapshot,
                        targetName: targetName, server: server, token: token, identity: identity,
                        userId: userId, audioStreamIndex: metadata.audioStreamIndex,
                        attemptKey: key, attemptID: attemptID)
                }
                registerServerPrepPollerTask(task, for: key)
            case .failMissingIdentity:
                recordDownloadDiagnostic("downloads.convert_failed", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "phase": .label("resume_missing_job_id"),
                ])
                lastError[record.ratingKey] = .transferFailed(
                    "Server conversion did not finish starting; retry to create a new conversion.")
                if metadata.embyConvertRecoveryPhase == .prepared {
                    // Durable proof POST was never handed to URLSession: safe to discard this
                    // baseline so a user retry may create a fresh job.
                    guard clearEmbyConvertRecoveryIfExact(
                        for: key, expected: metadata) else { continue }
                }
                _ = setAttemptStatus(.failed, for: key, context: "emby_convert_identity")
                clearOptimizeProgress(ratingKey: record.ratingKey)
                releaseInFlight(for: key)
            case .expireRecovery:
                // The identity is past the 24h adoption deadline: recovery could only ever fail
                // again (matchingNewJobIDs hard-returns [] after expiry), which looped
                // `.preparing` → `.failed` on every Retry forever. Hand the identity to the
                // cleanup queue (cleanupAction can still cancel a uniquely identified long-
                // retained job, and discards proven-empty evidence), release the row for a fresh
                // attempt, and fail it with an actionable message.
                recordDownloadDiagnostic("downloads.convert_failed", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "phase": .label("recovery_expired"),
                ])
                let cleanupCandidate = DownloadStore.EmbyConvertCleanupTombstone(
                    id: UUID(), ratingKey: record.ratingKey, metadata: metadata
                )
                switch store.addEmbyConvertCleanupTombstone(cleanupCandidate) {
                case .committed(let tombstone):
                    Task { [weak self] in
                        await self?.recoverAndCancelEmbyConvertTombstone(
                            tombstone, server: server, token: token, identity: identity,
                            currentUserID: userId)
                    }
                case .failed(let failure):
                    deferredEmbyCleanupTombstones.append(cleanupCandidate)
                    recordDownloadDiagnostic("downloads.convert_cleanup_deferred", fields: [
                        "download_id": .identifier(record.ratingKey),
                        "reason": .label("tombstone_\(failure.stage.rawValue)_failed"),
                        "error_type": .label(failure.errorType),
                    ])
                }
                guard clearEmbyConvertRecoveryIfExact(
                    for: key, expected: metadata) else { continue }
                lastError[record.ratingKey] = .transferFailed(
                    "Server conversion could not be recovered; retry to create a new conversion.")
                _ = setAttemptStatus(.failed, for: key, context: "emby_convert_expired")
                clearOptimizeProgress(ratingKey: record.ratingKey)
                releaseInFlight(for: key)
            }
        }
        refreshRecords()
    }

    /// #169: auto-resume static byte-range downloads that a hard app kill interrupted mid-transfer.
    ///
    /// `nsurlsessiond` keeps a background range task running while the app is merely suspended, but
    /// once the OS terminates the app under memory pressure (likely on a multi-hour 4K download),
    /// the next remainder can't auto-start — `reconcile` parks rows with a durable partial `.paused`
    /// and rows whose first body never committed `.failed`. `candidateKeys` (captured BEFORE
    /// reconcile) are the rows
    /// that were ACTIVELY transferring, so resuming them honors a system interruption while leaving a
    /// user's deliberate pause alone. `retry` rebuilds the request and continues from the durable
    /// partial (or byte 0). Rows whose background task DID survive are in `liveKeys` (already
    /// continuing) and skipped.
    private func resumeInterruptedStaticByteRangeDownloads(candidateKeys: [String], liveKeys: Set<String>) {
        for ratingKey in candidateKeys.sorted() where !liveKeys.contains(ratingKey) {
            guard let record = records.first(where: { $0.ratingKey == ratingKey }),
                  let key = attemptKey(for: record),
                  !store.isDeletionPending(for: key),
                  record.status == .paused || record.status == .failed else { continue }
            recordDownloadDiagnostic("downloads.range_auto_resume", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label("launch_interrupted"),
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
        guard startupRecoveryState == .ready else { return }
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
        let serverPrepRows = store.records
            .filter(DownloadRetryPolicy.isPlexServerPrepResumeCandidate)
            .filter { !isDeletionPending($0) }
        let candidates = serverPrepRows.filter {
            guard let key = attemptKey(for: $0) else { return false }
            return !serverPrepAttempts.hasPlexPoller(for: key)
        }
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
                  let targetName = metadata.optimizeTargetName,
                  let key = attemptKey(for: record) else { continue }
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
            inFlightAttempts.acquire(key)
            if let queueTitle = metadata.optimizeQueueTitle {
                serverPrepAttempts.protectQueueTitle(queueTitle, for: key)
            }
            recordDownloadDiagnostic("downloads.optimize_resume", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "has_queue_title": .bool(metadata.optimizeQueueTitle != nil),
            ])

            guard let pollerID = beginServerPrepPoller(for: key, source: "resume") else {
                continue
            }
            let task = Task { [weak self] in
                defer {
                    Task { [weak self] in
                        await MainActor.run {
                            self?.endServerPrepPoller(for: key, id: pollerID)
                        }
                    }
                }
                await self?.resumePendingOptimizeDownload(record: record,
                                                          metadata: metadata,
                                                          targetName: targetName,
                                                          server: server,
                                                          token: token,
                                                          pollerID: pollerID)
            }
            serverPrepPollerTasks[key] = task
        }
    }

    /// Register a server-prep chain's Task handle so `releaseInFlight` can cancel it on
    /// delete/terminal transitions. The resume path registers its detached Task directly; the
    /// FRESH-start optimize chain (audit B.9) wraps its body in a Task and registers it here —
    /// without a stored handle, delete had no way to cancel a fresh start's poll loop.
    func registerServerPrepPollerTask(_ task: Task<Void, Never>, for key: DownloadAttemptKey) {
        serverPrepPollerTasks[key] = task
    }

    /// Stop only process-owned work after the row became deletion-pending. Do not call
    /// `releaseInFlight`: it also executes/clears external encoder authority, which must remain in
    /// the sealed row until every cleanup intent is independently durable in the journal.
    private func haltManagerOwnedWorkForPendingDeletion(_ key: DownloadAttemptKey) {
        session.haltForPendingDeletion(ratingKey: key.ratingKey)
        _ = downloadWorkRegistry.cancelCancellableWork(for: key)
        _ = serverPrepAttempts.releaseAll(for: key)
        serverPrepPollerTasks.removeValue(forKey: key)?.cancel()
        keepaliveCoordinator.cancel(key)
    }

    func startJellyfinDownloadKeepalive(
        attemptKey: DownloadAttemptKey,
        itemId: String,
        mediaSourceId: String,
        playSessionId: String,
        userId: String,
        durationMs: Int?
    ) {
        keepaliveCoordinator.startJellyfinDownloadKeepalive(
            attemptKey: attemptKey,
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            userId: userId,
            durationMs: durationMs)
    }

    #if DEBUG
    func registerKeepaliveTaskForTesting(
        _ task: Task<Void, Never>,
        for key: DownloadAttemptKey,
        backend: DownloadBackendKind
    ) {
        keepaliveCoordinator.registerTaskForTesting(task, for: key, backend: backend)
    }
    #endif

    func beginServerPrepPoller(for key: DownloadAttemptKey, source: String) -> UUID? {
        let ratingKey = key.ratingKey
        guard let id = serverPrepAttempts.beginPlexPoller(for: key) else {
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

    func endServerPrepPoller(for key: DownloadAttemptKey, id: UUID) {
        guard serverPrepAttempts.endPlexPoller(for: key, id: id) else { return }
        serverPrepPollerTasks.removeValue(forKey: key)
        recordDownloadDiagnostic("downloads.optimize_poller_detached", fields: [
            "download_id": .identifier(key.ratingKey),
        ])
    }

    private func clearServerPrepPoller(ratingKey: String, reason: String) {
        guard let key = inFlightAttempts.owner(forRatingKey: ratingKey)
                ?? store.record(for: ratingKey).flatMap(attemptKey(for:)) else { return }
        let hadPoller = serverPrepAttempts.clearPlexPoller(for: key)
        let task = serverPrepPollerTasks.removeValue(forKey: key)
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
                                               token: String,
                                               pollerID: UUID) async {
        let ratingKey = record.ratingKey
        guard let key = attemptKey(for: record) else { return }
        let identity = appModel.identity
        // Legacy prep rows predate the persisted deadline. Seed it once before polling and write it
        // back to the row so another relaunch continues the same clock instead of resetting it.
        var metadata = metadata
        let optimizeStartedAt = metadata.plexOptimizeStartedAtEpochSeconds
            ?? Date().timeIntervalSince1970
        if metadata.plexOptimizeStartedAtEpochSeconds == nil {
            metadata.plexOptimizeStartedAtEpochSeconds = optimizeStartedAt
            var updatedRecord = record
            updatedRecord.metadata = metadata
            switch store.createAttemptOwnedRecord(updatedRecord, attemptID: key.attemptID) {
            case .committed(let committed) where committed == key:
                break
            case .committed, .rejectedOwnership:
                recordDownloadDiagnostic("downloads.optimize_resume_stale", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(targetName),
                    "phase": .label("deadline_publish"),
                ])
                return
            case .failed:
                lastError[ratingKey] = .transferFailed(
                    "The download could not be saved safely. Check storage and try again.")
                _ = setAttemptStatus(.failed, for: key, context: "plex_deadline_publish")
                if store.ownsAttempt(key) { releaseInFlight(for: key) }
                refreshRecords()
                return
            }
        }
        do {
            guard store.ownsAttempt(key) else {
                throw DownloadLifecycleCancellation.staleOptimizeAttempt
            }
            try assertCurrentOptimizeAttempt(attemptKey: key,
                                             metadata: metadata,
                                             targetName: targetName)
            let currentItem = await fetchCurrentMediaItem(ratingKey: ratingKey, server: server,
                                                         token: token, identity: identity)
                ?? metadata.makeMediaItem()
            guard store.ownsAttempt(key) else {
                throw DownloadLifecycleCancellation.staleOptimizeAttempt
            }
            try assertCurrentOptimizeAttempt(attemptKey: key,
                                             metadata: metadata,
                                             targetName: targetName)
            let originalPartIDs = DownloadOptimizeSourcePolicy.resumeBaselinePartIDs(metadata: metadata, item: currentItem)
            guard !originalPartIDs.isEmpty else {
                throw DownloadError.optimizeFailed("No source media parts found while resuming optimize.")
            }
            let sourceHeight = currentItem.media?[safe: metadata.mediaIndex ?? 0]?.height
                ?? metadata.sourceMediaHeight
            // Reconcile the rendered artifact BEFORE inspecting/recreating queue work. Plex may
            // already have completed and removed the type-42 item while the app was suspended; in
            // that state a missing queue entry is not evidence that another optimize POST is needed.
            if let renderedPart = Self.optimizedDownloadCandidate(
                from: currentItem.media ?? [],
                baselinePartIDs: originalPartIDs,
                targetName: targetName,
                sourceHeight: sourceHeight
            ) {
                recordDownloadDiagnostic("downloads.optimize_resume_adopt_completed", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(targetName),
                ])
                try startOptimizedPartDownload(attemptKey: key,
                                               title: record.title,
                                               part: renderedPart,
                                               metadata: metadata,
                                               server: server,
                                               token: token)
                return
            }
            // No matching rendered artifact is visible yet. Inspect the exact persisted queue item
            // before deciding whether its work disappeared and needs to be recreated.
            let backgroundProcessingKey = await bgKeyForPolling(server: server,
                                                                 token: token,
                                                                 identity: identity)
            guard store.ownsAttempt(key) else {
                throw DownloadLifecycleCancellation.staleOptimizeAttempt
            }
            let persistedQueueStatus: OptimizerQueueResponse.Status?
            if let backgroundProcessingKey, let queueTitle = metadata.optimizeQueueTitle {
                persistedQueueStatus = await optimizerQueueStatus(
                    backgroundProcessingKey: backgroundProcessingKey,
                    queueTitle: queueTitle,
                    server: server,
                    token: token,
                    identity: identity)
            } else {
                persistedQueueStatus = nil
            }
            // Recreate only when the queue was actually inspected and the item is provably
            // absent. A nil backgroundProcessingKey means the key lookup itself failed (bgKey
            // fetch swallows transient errors), which is "could not inspect", not "vanished" —
            // re-POSTing there would enqueue a duplicate optimize beside a still-running job.
            if backgroundProcessingKey != nil,
               persistedQueueStatus == nil,
               let queueTitle = metadata.optimizeQueueTitle {
                guard store.ownsAttempt(key) else {
                    throw DownloadLifecycleCancellation.staleOptimizeAttempt
                }
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
                guard store.ownsAttempt(key) else {
                    throw DownloadLifecycleCancellation.staleOptimizeAttempt
                }
                try assertCurrentOptimizeAttempt(attemptKey: key,
                                                 metadata: metadata,
                                                 targetName: targetName)
            }
            guard store.ownsAttempt(key) else {
                throw DownloadLifecycleCancellation.staleOptimizeAttempt
            }
            let part = try await pollForOptimizedPart(ratingKey: ratingKey,
                                                      originalPartIDs: originalPartIDs,
                                                      targetName: targetName,
                                                      sourceHeight: sourceHeight,
                                                      backgroundProcessingKey: backgroundProcessingKey,
                                                      queueTitle: metadata.optimizeQueueTitle,
                                                      startedAtEpochSeconds: optimizeStartedAt,
                                                      mediaTitle: record.title,
                                                      server: server,
                                                      token: token,
                                                      identity: identity)
            guard store.ownsAttempt(key) else {
                throw DownloadLifecycleCancellation.staleOptimizeAttempt
            }
            try assertCurrentOptimizeAttempt(attemptKey: key,
                                             metadata: metadata,
                                             targetName: targetName)
            try startOptimizedPartDownload(attemptKey: key,
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
            if let current = store.record(for: ratingKey),
               current.attemptID == key.attemptID,
               current.status == .queued, current.bytes == 0, current.progress == 0,
               current.metadata?.optimizeTargetName == targetName,
               current.metadata?.optimizeQueueTitle == metadata.optimizeQueueTitle {
                clearOptimizeProgress(ratingKey: ratingKey)
                releaseInFlight(for: key)
                refreshRecords()
                scheduleServerPrepResumeRetries()
            }
        } catch DownloadLifecycleCancellation.plexSessionUnavailable {
            // A-1: park for deferred resume — keep the queued server-prep row, drop the in-memory
            // slot/poller, and let the prep scanner reattach once the matching Plex lane returns.
            guard store.ownsAttempt(key) else { return }
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(for: key)
            refreshRecords()
            scheduleServerPrepResumeRetries()
        } catch let error as DownloadError {
            guard store.ownsAttempt(key),
                  resumeOptimizePollerIsCurrent(for: key, pollerID: pollerID,
                                                phase: "resume_error") else { return }
            recordDownloadDiagnostic("downloads.optimize_resume_failed", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "error": .error(error),
            ])
            lastError[ratingKey] = error
            _ = setAttemptStatus(.failed, for: key, context: "plex_poller_error")
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(for: key)
            refreshRecords()
        } catch is CancellationError {
            // A poller cancelled by pause/delete can reach here AFTER a quick resume already
            // began a NEW attempt on the same key (same optimizeQueueTitle). Releasing
            // unconditionally would strip the new attempt's slot/queue-title and cancel its
            // poller — only the still-current poller may tear down.
            guard store.ownsAttempt(key),
                  resumeOptimizePollerIsCurrent(for: key, pollerID: pollerID,
                                                phase: "resume_cancelled") else { return }
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(for: key)
            refreshRecords()
        } catch {
            guard store.ownsAttempt(key),
                  resumeOptimizePollerIsCurrent(for: key, pollerID: pollerID,
                                                phase: "resume_error") else { return }
            recordDownloadDiagnostic("downloads.optimize_resume_failed", fields: [
                "download_id": .identifier(ratingKey),
                "target": .label(targetName),
                "error": .error(error),
            ])
            lastError[ratingKey] = .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer"))
            _ = setAttemptStatus(.failed, for: key, context: "plex_poller_error")
            clearOptimizeProgress(ratingKey: ratingKey)
            releaseInFlight(for: key)
            refreshRecords()
        }
    }

    /// Attempt-currency gate for a Plex prep chain's terminal error/cancellation handlers.
    /// `pollerID` was minted by `beginPlexPoller` when this chain attached; once pause/delete
    /// ran `releaseAll` (or a newer attempt attached its own poller), this returns false and the
    /// superseded chain must not run terminal cleanup against the newer attempt's state.
    func resumeOptimizePollerIsCurrent(for key: DownloadAttemptKey, pollerID: UUID, phase: String) -> Bool {
        let ratingKey = key.ratingKey
        guard serverPrepAttempts.isCurrentPlexPoller(for: key, id: pollerID) else {
            recordDownloadDiagnostic("downloads.optimize_release_skipped_stale_poller", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label(phase),
            ])
            return false
        }
        return true
    }

    public var totalDownloadedBytes: Int {
        storageSnapshot.capEnforcementBytes
    }

    public var storageSnapshot: DownloadStorageSnapshot {
        let media = records.reduce(0) { $0 + $1.bytes }
        let sideAssets = records.reduce(0) { $0 + $1.sideAssetBytes }
        // Background URLSession temporary bodies are not synchronously enumerable here. Preserve
        // that uncertainty rather than presenting them as durable or as zero-byte reservations.
        return DownloadStorageSnapshot(
            durableMediaBytes: media,
            durableSideAssetBytes: sideAssets,
            heldOrResumeArtifactBytes: .unknown,
            liveOSTemporaryBytes: .unknown,
            expectedReservationBytes: .notApplicable)
    }

    public var storageLimitBytes: Int {
        PlaybackPreferences.downloadStorageLimitBytes()
    }

    public func storageLimitMessage(adding expectedBytes: Int?) -> String? {
        DownloadStorageLimitPolicy.rejectionMessage(adding: expectedBytes,
                                                    currentBytes: totalDownloadedBytes,
                                                    limitBytes: storageLimitBytes)
    }

    public func estimatedBytes(for item: MediaItem, choice: DownloadChoice,
                               mediaIndex: Int = 0, partIndex: Int = 0,
                               backend: DownloadBackendKind? = nil) -> Int? {
        // Resolve the backend explicitly when the caller is on a specific lane (the download
        // pipeline always passes it); the default falls back to `activeBackend` for the UI sheet,
        // which is on the active backend.
        let resolvedBackend = backend ?? appModel.activeBackend.downloadBackendKind
        return DownloadStorageEstimatePolicy.estimatedTotalBytes(for: item,
                                                                 choice: choice,
                                                                 backend: resolvedBackend,
                                                                 mediaIndex: mediaIndex,
                                                                 partIndex: partIndex)
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
        // A retry/resume handoff arrives here with a row still parked in active-work status and
        // (for static resumes) a pendingResume marker. Fail the row and drop the marker BEFORE
        // publishing the refresh — a still-queued row with a lingering marker is exempt from stale
        // demotion forever while auto-resume re-drives this same rejected start on every
        // backend-ready edge. Fresh enqueues have no row yet, so this is a no-op for them.
        markStartAbortedBeforeTransfer(ratingKey: ratingKey)
        refreshRecords()
        return true
    }

    /// Terminal bookkeeping for a download entry point that gives up before any transfer starts.
    /// Order is load-bearing: the row must leave active-work status BEFORE the pending-resume
    /// marker is dropped. A still-queued static partial with no marker re-enters the stale-queued
    /// detector on the next refresh, which re-drives the same doomed start — the churn cousin of
    /// the #210 refresh⇄resume recursion.
    func markStartAbortedBeforeTransfer(ratingKey: String) {
        if let record = store.record(for: ratingKey), record.status.isActiveWork,
           let key = attemptKey(for: record) {
            _ = setAttemptStatus(.failed, for: key, context: "start_aborted")
        }
        clearStaticRangePendingResume(ratingKey: ratingKey)
    }

    public func deleteCompletedDownloads() {
        for record in records where record.isComplete { delete(ratingKey: record.ratingKey) }
    }

    public func deleteAllDownloads() {
        for record in records { delete(ratingKey: record.ratingKey) }
    }

    /// Delete a download and its backing file.
    public func delete(ratingKey: String) {
        guard let rowToDelete = store.record(for: ratingKey) else { return }
        delete(record: rowToDelete)
    }

    /// Delete only the exact attempt represented by a rendered row. The identity remains attached
    /// through the Store's deletion submission; a newer owner is never re-resolved by rating key.
    @discardableResult
    public func delete(_ identity: OfflineDownloadRowActionIdentity) -> Bool {
        guard let rowToDelete = currentRecord(for: identity) else { return false }
        delete(record: rowToDelete)
        return true
    }

    private func delete(record rowToDelete: DownloadRecord) {
        let ratingKey = rowToDelete.ratingKey
        let rowAttemptKey = rowToDelete.attemptID.map {
            DownloadAttemptKey(ratingKey: ratingKey, attemptID: $0)
        }
        let wasDeletionPending = rowAttemptKey.map { store.isDeletionPending(for: $0) } ?? false
        var cleanupIntentsToExecute = rowAttemptKey.flatMap {
            store.deletionPendingCleanupIntents(for: $0)
        } ?? []
        // A missing server-cleanup identity lets local deletion proceed but leaks the server
        // encoder/conversion. That disclosure is ABOUT the deletion succeeding, so it must survive
        // the success path's `lastError = nil` clear below — otherwise the leak goes silent.
        var serverCleanupLeakDisclosure: DownloadError?
        if cleanupIntentsToExecute.isEmpty, let metadata = rowToDelete.metadata {
            let backend = metadata.resolvedBackendKind(ratingKey: ratingKey)
            let transientPlaySessionID: String? = switch backend {
            case .emby: rowAttemptKey.flatMap { embyPlaySessionByAttempt[$0] }
            case .jellyfin: rowAttemptKey.flatMap { jellyfinPlaySessionByAttempt[$0] }
            case .plex: nil
            }
            if backend != .plex,
               let playSessionID = metadata.playSessionID ?? transientPlaySessionID,
               !playSessionID.isEmpty {
                if let attemptID = rowToDelete.attemptID {
                    let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
                    if let intent = Self.makeActiveEncodingCleanupIntent(
                        attemptKey: key, metadata: metadata, playSessionID: playSessionID
                    ) {
                        cleanupIntentsToExecute.append(intent)
                    } else {
                        // Missing legacy server identity cannot be repaired by retaining an
                        // undeletable row forever. Delete locally and surface the cleanup gap.
                        serverCleanupLeakDisclosure = .transferFailed(
                            "Downloaded file deleted; server cleanup identity was unavailable.")
                    }
                } else {
                    recordDownloadDiagnostic("downloads.delete_deferred", fields: [
                        "download_id": .identifier(ratingKey),
                        "reason": .label("cleanup_attempt_owner_missing"),
                    ])
                }
            }
            if Self.hasEmbyConvertCleanupAuthority(metadata) {
                if let attemptID = rowToDelete.attemptID {
                    let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
                    if let intent = Self.makeEmbyConvertCleanupIntent(
                        attemptKey: key, metadata: metadata) {
                        cleanupIntentsToExecute.append(intent)
                    } else {
                        serverCleanupLeakDisclosure = .transferFailed(
                            "Downloaded file deleted; server conversion cleanup identity was unavailable.")
                    }
                } else {
                    recordDownloadDiagnostic("downloads.delete_deferred", fields: [
                        "download_id": .identifier(ratingKey),
                        "reason": .label("convert_cleanup_attempt_owner_missing"),
                    ])
                }
            }
        }
        if let rowAttemptKey, !cleanupIntentsToExecute.isEmpty {
            // Journal first, destructive local deletion second. If the standalone queue is
            // unavailable, reserve every exact operation (including transient PlaySessionId) in
            // the index and return with the row/files intact. A retry or relaunch can then migrate
            // the reservation without inventing authority from whichever attempt is current.
            switch DownloadCleanupOrdering.prepareForDestructiveDeletion(
                candidates: cleanupIntentsToExecute,
                key: rowAttemptKey,
                journal: cleanupIntentJournal,
                store: store
            ) {
            case .ready(let durable):
                cleanupIntentsToExecute = durable
            case .deletionPending(_, let failure):
                haltManagerOwnedWorkForPendingDeletion(rowAttemptKey)
                lastError[ratingKey] = .transferFailed(
                    "Deletion is pending until server cleanup can be saved. Tap Delete to retry.")
                recordDownloadDiagnostic("downloads.delete_deferred", fields: [
                    "download_id": .identifier(ratingKey),
                    "reason": .label(Self.cleanupOrderingFailureLabel(failure)),
                    "authority": .label("index_deletion_pending"),
                ])
                refreshRecords()
                return
            case .indexPersistenceFailed(_, let persistence):
                lastError[ratingKey] = .transferFailed(
                    "Deletion could not be saved. Free storage if needed, then tap Delete to retry.")
                recordDownloadDiagnostic("downloads.delete_deferred", fields: [
                    "download_id": .identifier(ratingKey),
                    "reason": .label(Self.startupPersistenceFailureLabel(persistence)),
                    "authority": .label("existing_row_unchanged"),
                ])
                refreshRecords()
                return
            case .staleOrMissing:
                recordDownloadDiagnostic("downloads.delete_deferred", fields: [
                    "download_id": .identifier(ratingKey),
                    "reason": .label("cleanup_owner_changed"),
                ])
                refreshRecords()
                return
            }
        }
        guard let deletedAttemptKey = rowAttemptKey else { return }
        let deletionSubmission = wasDeletionPending
            ? store.submitCompletePendingDeletion(for: deletedAttemptKey)
            : store.submitRemove(for: deletedAttemptKey)
        // No rating-key runtime/session/server side effect is allowed until the exact Store owner
        // has installed its deletion barrier. A replacement that won since the rendered action
        // was captured makes submission stale and leaves the replacement entirely untouched.
        guard case .accepted = deletionSubmission else {
            recordDownloadDiagnostic("downloads.delete_deferred", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label("delete_owner_changed"),
            ])
            refreshRecords()
            return
        }
        session.cancel(ratingKey: ratingKey)
        // The durable terminal barrier now rejects every tail publication. Cancel side caches,
        // finalizers, and other exact cancellable work immediately so they cannot create new
        // unlisted staging bytes while the off-lock deletion worker is still running.
        _ = downloadWorkRegistry.cancelCancellableWork(for: deletedAttemptKey)
        recordDownloadDiagnostic("downloads.cancel_or_delete", fields: [
            "download_id": .identifier(ratingKey),
        ])
        // B.14: clear ALL recovery state, not just the resume markers — a stale `finalizingKeys`
        // entry parks a re-download's byte-complete relaunch as `.alreadyFinalizing` forever, and
        // a stale preservation key leaks the deleted attempt's restart budgets into the next one.
        staticRangeRecovery.removeAll(forKey: ratingKey)
        retryState.removeRetrying(ratingKey)
        // Emby convert parity (#126 + Plex): deleting a `.preparing` row must ALSO cancel the
        // server-side "Convert Media" Sync job, or it keeps rendering after the user abandoned it.
        // Capture the row BEFORE removing it (best-effort; deleting the job never deletes an
        // already-converted file, so this only ever cancels an in-flight conversion).
        // Plex parity: deleting a row still in server prep (optimize job triggered, no rendered
        // Part handed off yet) must also remove its type-42 background-processing item, or the
        // server keeps transcoding — and later stores a rendered version — for a download the
        // user abandoned. Targeted at THIS row's queue title only; the completed-state guard in
        // `cancellableItemID` keeps finished renders (which other rows may reuse) untouched.
        let plexSession = appModel.backendSession(for: .plex)
        let plexSessionMatchesDeletedRow = rowToDelete.metadata.map { metadata in
            plexSession?.matchesPersistedServer(metadata) == true
        } ?? false
        switch DownloadDeletePolicy.plexOptimizeCancelDecision(
            for: rowToDelete,
            plexSessionMatchesPersistedServer: plexSessionMatchesDeletedRow
        ) {
        case .none:
            break
        case .cancel(let queueTitle):
            guard let plexSession else { break }
            let server = plexSession.baseURL
            let token = plexSession.token
            let identity = appModel.identity
            Task { [weak self] in
                await self?.removePlexOptimizeQueueItem(ratingKey: ratingKey,
                                                        queueTitle: queueTitle,
                                                        server: server, token: token,
                                                        identity: identity)
            }
        case .skip(_, let reason):
            recordDownloadDiagnostic("downloads.optimize_cancel_skip", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(reason),
            ])
        }
        // The prepared row-deletion recipe is submitted synchronously, but filesystem work and
        // terminal persistence run on the artifact worker. Keep the main actor responsive and do
        // not release attempt state until exact removal is proven complete.
        Task { [weak self, serverCleanupLeakDisclosure] in
            guard let self else { return }
            let outcome = await store.resolveRowDeletion(deletionSubmission)
            guard case .removed = outcome else {
                lastError[ratingKey] = .transferFailed(
                    "Deletion could not finish safely. Free storage if needed, then tap Delete to retry.")
                refreshRecords()
                return
            }
            for intent in cleanupIntentsToExecute {
                deferredCleanupIntents[intent.id] = intent
                switch intent.operation {
                case .activeEncoding: executeActiveEncodingCleanupIntent(intent)
                case .embyConvert: executeEmbyConvertCleanupIntent(intent)
                }
            }
            // Preserve the server-cleanup-identity leak disclosure across a successful deletion —
            // the row is gone but the server encoder/conversion was never torn down, and clearing
            // to nil here would silence exactly the gap the disclosure was added to surface.
            lastError[ratingKey] = serverCleanupLeakDisclosure
        // Drop server-prep progress state too, or re-downloading the same item resurfaces the
        // deleted row's stale "Preparing on server… N%" caption and seeds the ETA estimator with
        // dead samples. (`releaseInFlight` below also clears it — kept explicit here because the
        // leak was delete-shaped.)
            clearOptimizeProgress(ratingKey: ratingKey)
        // Releasing the in-flight protection here matters because the row is now GONE, so the
        // terminal-status sweep in `refreshRecords` (which keys off `.complete`/`.failed` rows)
        // can no longer find it to release — without this, a cancelled/deleted job would leak
        // its `activeJobs` slot (blocking re-download) and keep its queue title protected forever.
        // Pass the pre-removal snapshot: the store row no longer exists, so without it the
        // Jellyfin/Emby encoder-teardown server-match guard would see nil metadata and silently
        // dead-end the persisted-psid branch during this teardown.
            releaseInFlight(for: deletedAttemptKey, rowSnapshot: rowToDelete)
            refreshRecords()
        }
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
            staticRangeRecovery.removePendingResume(plan.ratingKey)
            refreshRecords()
        } catch {
            staticRangeRecovery.removePendingResume(plan.ratingKey)
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
            _ = setAttemptStatus(.failed, for: plan.attemptKey, context: "transfer_start")
            if plan.releaseInFlightOnFailure { releaseInFlight(for: plan.attemptKey) }
            refreshRecords()
        } catch {
            lastError[plan.ratingKey] = .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer"))
            _ = setAttemptStatus(.failed, for: plan.attemptKey, context: "transfer_start")
            if plan.releaseInFlightOnFailure { releaseInFlight(for: plan.attemptKey) }
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
            "download_id": .identifier(DownloadRecordIdentity.recordKey(for: item.ratingKey, backend: backendKind)),
            "backend": .label(backend),
            "choice": .label(DownloadChoicePolicy.diagnosticChoiceLabel(choice)),
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


    func updateLocalPlaybackPosition(ratingKey: String, positionMs: Int, durationMs: Int?) {
        guard let record = store.record(for: ratingKey) else { return }
        guard let attemptID = record.attemptID else { return }
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        var promoted = false
        if positionMs > 0, case .promoted = store.markCompleteIfUnverified(for: key) {
            promoted = true
        }
        switch store.setLocalPlaybackPosition(
            for: key, positionMs: positionMs, durationMs: durationMs) {
        case .applied, .noChange:
            break
        case .staleOrMissing, .persistenceFailed:
            return
        }
        if promoted {
            recordDownloadDiagnostic("downloads.unverified_playback_confirmed", fields: [
                "download_id": .identifier(ratingKey),
                "position_ms": .int(positionMs),
                "duration_ms": .int(durationMs ?? -1),
            ])
        }
        refreshRecords()
    }

    /// Heal rows that historical bugs finalized past the byte-completeness guard: a static
    /// byte-for-byte row whose durable file is smaller than the source's EXACT size can never be a
    /// playable whole (headset evidence: an HTTP 416 finalized a truncated legacy bounded body
    /// from a 5.9 GB part to `.complete`, and starting playback promoted another truncated row from `.unverified`).
    /// Demote them to `.failed` KEEPING the file — it is the resume checkpoint — so Retry
    /// continues from the durable offset. `sourceExactBytes` is nil for transcode lanes, whose
    /// outputs are legitimately smaller than their source, so they are never touched.
    private func demoteIncompleteCompletedStaticRows(reason: String) {
        for record in store.records where record.status == .complete || record.status == .unverified {
            guard let key = attemptKey(for: record),
                  !store.isDeletionPending(for: key),
                  let expected = store.sourceExactBytes(for: key),
                  let durable = store.durableStaticRangeCheckpointSize(for: key) else { continue }
            guard DownloadCompletionValidation.isIncomplete(downloadedBytes: durable,
                                                            expectedExactBytes: expected) else { continue }
            recordDownloadDiagnostic("downloads.completed_size_audit_demoted", fields: [
                "download_id": .identifier(record.ratingKey),
                "reason": .label(reason),
                "from_status": .label(record.status.rawValue),
                "bytes": .bytes(durable),
                "expected_bytes": .bytes(expected),
            ])
            resolveStaticRangeCheckpoint(
                for: record, expectedBytes: expected, context: "size_audit"
            ) { [weak self] checkpointBytes in
                guard let self, checkpointBytes != nil,
                      setAttemptStatus(.failed, for: key, context: "size_audit") else { return }
                lastError[record.ratingKey] = .transferFailed(
                    "Download is incomplete (\(durable / 1_000_000) of \(expected / 1_000_000) MB). Retry to continue.")
                refreshRecords()
            }
        }
    }

    private func revalidateUnverifiedDownloads(reason: String) {
        demoteIncompleteCompletedStaticRows(reason: reason)
        let candidates = store.records.filter { $0.status == .unverified }
        guard !candidates.isEmpty else { return }
        guard isAppSceneActive else {
            unverifiedRevalidation.parkUntilActive(Set(candidates.compactMap { attemptKey(for: $0) }))
            return
        }
        for record in candidates {
            guard let key = attemptKey(for: record),
                  !store.isDeletionPending(for: key) else { continue }
            let preservesOvertakenRequest = reason == "scene_active"
                || reason == "background_gate_drained" || reason == "timeout_retry"
            guard unverifiedRevalidation.begin(
                key, preservesOvertakenRequest: preservesOvertakenRequest) else { continue }
            recordDownloadDiagnostic("downloads.unverified_revalidate_start", fields: [
                "download_id": .identifier(record.ratingKey),
                "reason": .label(reason),
            ])
            // Bounded label (audit lens 8, B-1): a raw "unverified_\(reason)" can exceed the
            // redactor's 24-char bare-token threshold and get blanked in the jsonl.
            let admission = session.revalidateCompletedDownload(
                ratingKey: record.ratingKey,
                validationLabel: BackgroundFinalizationResultPolicy.unverifiedResultLabel(reason: reason))
            switch admission {
            case .deferredForBackgroundWake:
                unverifiedRevalidation.deferred(key)
            case .alreadyFinalizing:
                unverifiedRevalidation.alreadyFinalizing(key)
            case .unavailable:
                if unverifiedRevalidation.unavailable(key) != nil {
                    scheduleUnverifiedRevalidationRetry(for: key, delay: .seconds(1))
                }
            case .started(let requestID):
                scheduleUnverifiedRevalidationRetry(
                    for: key, delay: .seconds(90),
                    token: unverifiedRevalidation.started(key, requestID: requestID))
            }
        }
    }

    /// A timeout is a recovery edge, not merely permission for some unrelated future UI event to
    /// try again. The exact-attempt check prevents a delayed timer from touching a replacement.
    private func scheduleUnverifiedRevalidationRetry(
        for key: DownloadAttemptKey, delay: Duration, token suppliedToken: UUID? = nil
    ) {
        guard unverifiedRevalidation.permitRetry(
            key, sceneIsActive: isAppSceneActive) else { return }
        let token = suppliedToken ?? unverifiedRevalidation.armTimer(for: key)
        Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await MainActor.run {
                guard let self, self.unverifiedRevalidation.timerFired(
                    for: key, token: token,
                    remainsUnverified: self.store.record(for: key)?.status == .unverified
                ) else { return }
                guard self.unverifiedRevalidation.permitRetry(
                    key, sceneIsActive: self.isAppSceneActive) else { return }
                self.revalidateUnverifiedDownloads(reason: "timeout_retry")
            }
        }
    }

    private func resetUnverifiedAutomaticRetryBudget() {
        unverifiedRevalidation.resetAutomaticRetryBudget(Set(
            store.records.filter { $0.status == .unverified }.compactMap { attemptKey(for: $0) }))
    }

    #if DEBUG
    func unverifiedRevalidationSnapshotForTesting() -> UnverifiedRevalidationCoordinator {
        unverifiedRevalidation
    }
    #endif

    private func clearRetryHandoff(ratingKey: String) {
        retryState.clearHandoff(ratingKey)
    }

    func clearStaticRangePendingResume(ratingKey: String) {
        staticRangeRecovery.removePendingResume(ratingKey)
    }

    private func markRetryReplacementSeeded(ratingKey: String) {
        retryState.markReplacementSeeded(ratingKey)
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
            guard !isDeletionPending(record), !seasonPlannerAdmittingKeys.contains(record.ratingKey),
                  record.metadata?.seasonPlannerPendingAdmission != true else { return false }
            return DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(
                record,
                isActive: session.isTrackingTransfer(ratingKey: record.ratingKey),
                // #210: a backend-unavailable static Range resume is intentionally preserved as a
                // queued pending intent. Reprocessing it here re-enters resume/defer/refresh until
                // the main-thread stack overflows during launch.
                hasPendingResumeIntent: staticRangeRecovery.hasPendingResume(record.ratingKey)
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
                    guard let key = attemptKey(for: record) else { continue }
                    resolveStaticRangeCheckpoint(for: record, context: "stale_queue_pause") {
                        [weak self] checkpointBytes in
                        guard let self, let checkpointBytes else { return }
                        if checkpointBytes > 0 {
                            guard setAttemptStatus(
                                .paused, for: key, context: "stale_queue_pause") else { return }
                            lastError[record.ratingKey] = .interruptedResumable
                        } else if store.record(for: key) == nil {
                            return
                        }
                        staticRangeRecovery.removePendingResume(record.ratingKey)
                        recordDownloadDiagnostic("downloads.range_stale_queued_paused", fields: [
                            "download_id": .identifier(record.ratingKey),
                            "backend": .label(
                                DownloadJobSnapshot(record: record).backend.rawValue),
                            "checkpoint_bytes": .bytes(checkpointBytes),
                        ])
                        refreshRecords()
                    }
                }
                for record in manuallyResumed where !staticRangeRecovery.hasPendingResume(record.ratingKey) {
                    guard let key = attemptKey(for: record),
                          let checkpointBytes = store.durableStaticRangeCheckpointSize(
                            for: key) else { continue }
                    staticRangeRecovery.addPendingResume(record.ratingKey)
                    recordDownloadDiagnostic("downloads.range_stale_queued_manual_resume", fields: [
                        "download_id": .identifier(record.ratingKey),
                        "backend": .label(DownloadJobSnapshot(record: record).backend.rawValue),
                        "checkpoint_bytes": .bytes(checkpointBytes),
                    ])
                }
                for record in manuallyResumed {
                    resumeStaticRangeWhenReady(ratingKey: record.ratingKey,
                                               reason: "stale_queued_static_manual_resume")
                }
            } else {
                for record in staleQueuedStaticPartials where !staticRangeRecovery.hasPendingResume(record.ratingKey) {
                    guard let key = attemptKey(for: record),
                          let checkpointBytes = store.durableStaticRangeCheckpointSize(
                            for: key) else { continue }
                    staticRangeRecovery.addPendingResume(record.ratingKey)
                    recordDownloadDiagnostic("downloads.range_stale_queued_resume", fields: [
                        "download_id": .identifier(record.ratingKey),
                        "backend": .label(DownloadJobSnapshot(record: record).backend.rawValue),
                        "checkpoint_bytes": .bytes(checkpointBytes),
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
        // Season-planned rows are durably queued but intentionally have no task/poller until the
        // bounded admission worker selects them. Ordinary stale/relaunch recovery must not race
        // that marker and start the entire season at once.
        let recoveryEligibleFresh = fresh.filter {
            !isDeletionPending($0)
                && !seasonPlannerAdmittingKeys.contains($0.ratingKey)
                && $0.metadata?.seasonPlannerPendingAdmission != true
        }
        let serverPrepKeysByRatingKey = Dictionary(uniqueKeysWithValues: recoveryEligibleFresh.compactMap { record in
            attemptKey(for: record).map { (record.ratingKey, $0) }
        })
        let serverPrepRefreshPlan = ServerPrepRefreshPolicy.refreshPlan(
            records: recoveryEligibleFresh,
            isQueuePaused: isQueuePaused,
            refreshKickScheduled: serverPrepRefreshKickScheduled,
            refreshKickRecent: serverPrepKickIsRecent,
            hasPlexPoller: { [serverPrepAttempts, serverPrepKeysByRatingKey] ratingKey in
                serverPrepKeysByRatingKey[ratingKey].map(serverPrepAttempts.hasPlexPoller(for:)) ?? false
            },
            isActiveJob: { [activeJobs] ratingKey in
                activeJobs.contains(ratingKey)
            }
        )
        if isQueuePaused {
            for ratingKey in serverPrepRefreshPlan.parkWhileQueuePausedKeys {
                if let record = fresh.first(where: { $0.ratingKey == ratingKey }),
                   record.status != .paused, let key = attemptKey(for: record) {
                    _ = setAttemptStatus(.paused, for: key, context: "queue_pause_prep")
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
        for record in recoveryEligibleFresh where retryState.isRetryHandoff(record.ratingKey) {
            if staticRangeRecovery.hasPendingResume(record.ratingKey),
               record.status.isActiveWork,
               !session.isTrackingTransfer(ratingKey: record.ratingKey) {
                // A static-range resume deliberately keeps the persisted row `.queued` while the
                // backend retry is still rebuilding the replacement URLSession request. Do not
                // treat that pre-existing active row as "replacement seeded"; clearing the retry
                // marker here makes retryAttemptCanContinue() abort before it reaches download().
                continue
            }
            if record.status.isActiveWork || record.status == .complete || record.status == .unverified {
                markRetryReplacementSeeded(ratingKey: record.ratingKey)
            }
        }
        let finalizedRecoveryKeys = StaticRangeRefreshCleanupPolicy.finalizingTerminalKeys(
            records: recoveryEligibleFresh)
        staticRangeRecovery.subtractFinalizing(finalizedRecoveryKeys)
        let manualResumeTerminalKeys = StaticRangeRefreshCleanupPolicy.manualQueueResumeTerminalKeys(
            records: recoveryEligibleFresh,
            retryHandoffKeys: retryState.handoffKeys,
            retryingKeys: retryState.retryingKeys
        )
        staticRangeRecovery.subtractManualQueueResumes(manualResumeTerminalKeys)
        let activeKeys = Set(fresh.filter { $0.status == .downloading }.map(\.ratingKey))
        liveRangeProgress = liveRangeProgress.filter { key, _ in
            // An active background URLSession can keep writing while the suspended app receives no
            // delegate callbacks. Expiring its last sample after 15 seconds made the toolbar total
            // fall to the durable checkpoint and jump back at wake. Keep the monotonic watermark
            // until the row actually leaves `.downloading`; terminal/pause cleanup still removes it.
            return StaticRangeRefreshCleanupPolicy.shouldKeepLiveRangeProgress(
                key: key,
                activeDownloadingKeys: activeKeys
            )
        }
        // #123: drive one pure `DownloadRateEstimator` per actively-downloading row from its
        // cumulative byte count. The estimator owns ALL the speed/ETA math — first-emit window,
        // stall decay→nil, backwards-bytes re-baseline, and the Σdb/Σdt window average that
        // reconciles the displayed rate with Σbytes/elapsed. The actor just feeds `(bytes, now)`
        // and reads back the smoothed rate + ETA; the math is pinned by `DownloadRateEstimatorTests`.
        // #169: a background Range task can reset optimistic temp-byte progress back to the
        // durable partial checkpoint during promotion/pause/retry. Hide rate/ETA for one averaging
        // window after that backwards rebaseline instead of flashing a bogus high-speed provisional.
        for record in fresh where record.status == .downloading {
            let sampleBytes = displayBytes(for: record, now: now) ?? record.bytes
            if let graceUntil = rateEstimatorForegroundGraceUntil[record.ratingKey], now < graceUntil {
                // Keep replacing the estimator during the grace, so the first sample after the
                // grace starts from the latest post-wake byte watermark rather than a large
                // background-delivered jump.
                var estimator = DownloadRateEstimator(rebaselineSuppressWindow: 4.0)
                _ = estimator.sample(bytes: sampleBytes, at: now)
                rateEstimators[record.ratingKey] = estimator
                downloadSpeed.removeValue(forKey: record.ratingKey)
                downloadETA.removeValue(forKey: record.ratingKey)
                continue
            }
            rateEstimatorForegroundGraceUntil.removeValue(forKey: record.ratingKey)
            var estimator = rateEstimators[record.ratingKey]
                ?? DownloadRateEstimator(rebaselineSuppressWindow: 4.0)
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
            if let rate, rate > 0,
               rateEstimatorForegroundSettledPending.remove(record.ratingKey) != nil {
                recordDownloadDiagnostic("downloads.rate_foreground_settled", fields: [
                    "download_id": .identifier(record.ratingKey),
                    "sample_bytes": .bytes(sampleBytes),
                    "rate_bytes_per_second": .int(Int(rate.rounded())),
                ])
            }
        }
        let forwardOnlyRestarts = detectForwardOnlyStreamStalls(
            in: recoveryEligibleFresh, now: now)
        // Drop estimators/derived values for rows no longer downloading (complete / failed / removed).
        rateEstimators = rateEstimators.filter { activeKeys.contains($0.key) }
        rateEstimatorForegroundGraceUntil = rateEstimatorForegroundGraceUntil.filter { activeKeys.contains($0.key) }
        rateEstimatorForegroundProgressPending = rateEstimatorForegroundProgressPending.filter { activeKeys.contains($0.key) }
        rateEstimatorForegroundSettledPending.formIntersection(activeKeys)
        downloadSpeed = downloadSpeed.filter { activeKeys.contains($0.key) }
        downloadETA = downloadETA.filter { activeKeys.contains($0.key) }
        updateDownloadWatchdog(for: recoveryEligibleFresh)
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
        let terminalKeys = DownloadTerminalReleasePolicy.terminalReleaseKeys(
            records: recoveryEligibleFresh,
            retryHandoffKeys: retryState.handoffKeys,
            retryingKeys: retryState.retryingKeys)
        let terminalRecordsByKey = Dictionary(uniqueKeysWithValues: fresh.map { ($0.ratingKey, $0) })
        for ratingKey in terminalKeys {
            if let record = terminalRecordsByKey[ratingKey], let key = attemptKey(for: record) {
                // A terminal status can be published by the finalizer immediately before its
                // `onChange`. Release transfer/server ownership, but do not self-cancel the exact
                // finalizer before its final callback/accounting defer runs.
                let mode: DownloadWorkRegistry.AttemptCancellationMode =
                    (record.status == .complete || record.status == .unverified)
                    ? .preservingFinalizerAndSideCache
                    : .preservingFinalizer
                releaseInFlight(for: key, cancellationMode: mode)
            }
        }

        records = fresh
        offlineLibrarySnapshot = makeOfflineLibrarySnapshot(from: fresh)
        for intent in deferredCleanupIntents.values where !cleanupIntentsInFlight.contains(intent.id) {
            switch intent.operation {
            case .activeEncoding: executeActiveEncodingCleanupIntent(intent)
            case .embyConvert: executeEmbyConvertCleanupIntent(intent)
            }
        }
        keepaliveCoordinator.reconcile(records: recoveryEligibleFresh)
        for restart in forwardOnlyRestarts {
            Task { @MainActor [weak self] in
                self?.restartStalledForwardOnlyStream(restart)
            }
        }
        if fresh.contains(where: { $0.metadata?.seasonPlannerPendingAdmission == true }) {
            scheduleSeasonPlannerAdmission()
        }
    }

    private func detectForwardOnlyStreamStalls(in records: [DownloadRecord],
                                               now: Date) -> [DownloadForwardOnlyStallRestart] {
        forwardOnlyStallTracker.detectRestarts(records: records, now: now) { [activeJobs, session] ratingKey in
            activeJobs.contains(ratingKey) || session.isTrackingTransfer(ratingKey: ratingKey)
        }
    }

    private func restartStalledForwardOnlyStream(_ restart: DownloadForwardOnlyStallRestart) {
        let ratingKey = restart.record.ratingKey
        guard let current = store.record(for: ratingKey),
              let key = attemptKey(for: current),
              !store.isDeletionPending(for: key),
              DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(current) else { return }
        let backend = DownloadJobSnapshot(record: current).backend
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
        retryState.removeRetrying(ratingKey)
        clearRetryHandoff(ratingKey: ratingKey)
        lastError[ratingKey] = .transferFailed(
            "Network stalled; restarting this forward-only stream from the beginning.")
        guard setAttemptStatus(.failed, for: key, context: "stream_stall") else { return }
        releaseInFlight(for: key)
        // `releaseInFlight` wipes the stall tracker entry, including the attempt count
        // `detectRestarts` just incremented — without re-seeding it the 2-restart cap never binds
        // and a persistent wedge restarts the encoder from byte 0 every stall timeout forever.
        forwardOnlyStallTracker.seedRestartAttempts(ratingKey, attempts: restart.attempt)
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
            retryingCount: retryState.retryingCount,
            retryHandoffCount: retryState.handoffCount,
            pendingStaticResumeCount: staticRangeRecovery.pendingResumeCount,
            finalizingStaticRecoveryCount: staticRangeRecovery.finalizingCount,
            serverPrepPollerCount: serverPrepPollerTasks.count,
            jellyfinKeepaliveCount: keepaliveCoordinator.activeCount(for: .jellyfin),
            forwardStallWatchCount: forwardOnlyStallTracker.trackedCount,
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
            pendingTempCleanupBytes: snapshot.pendingTempCleanupBytes)
    }

    /// Drop the in-flight protection (`activeJobs` slot + protected optimize-queue title) for a
    /// ratingKey once its download is no longer in flight (completed, failed, cancelled, or
    /// deleted). Idempotent. Keeping the queue title protected past this point would block the
    /// clean-slate cleanup from ever removing the now-abandoned completed optimize item.
    ///
    /// `rowSnapshot` is the caller's pre-removal copy of the row for the delete path, where the
    /// store row is already gone by the time this runs: without it the encoder-teardown
    /// server-match guards below would read nil metadata and skip the persisted-psid branch.
    func releaseInFlight(
        for attemptKey: DownloadAttemptKey,
        rowSnapshot: DownloadRecord? = nil,
        cancellationMode: DownloadWorkRegistry.AttemptCancellationMode = .allCancellable
    ) {
        let ratingKey = attemptKey.ratingKey
        let releasePlan = DownloadAttemptReleasePolicy.plan(
            releasing: attemptKey,
            currentOwner: inFlightAttempts.owner(forRatingKey: ratingKey))
        transcodeSourcedDownloads.remove(attemptKey)
        _ = downloadWorkRegistry.cancelCancellableWork(
            for: attemptKey, mode: cancellationMode)
        if cancellationMode == .allCancellable {
            cancelOptionalSideAssetHydration(for: attemptKey)
        }
        _ = serverPrepAttempts.releaseAll(for: attemptKey)
        serverPrepPollerTasks.removeValue(forKey: attemptKey)?.cancel()
        keepaliveCoordinator.cancel(attemptKey)

        if releasePlan.releaseCurrentState, inFlightAttempts.release(ifOwnedBy: attemptKey) {
            clearCurrentInFlightState(ratingKey: ratingKey)
        }

        // Exact resource teardown continues even when A is stale and B owns the current slot.
        releaseExactEncoderResources(for: attemptKey, rowSnapshot: rowSnapshot)
    }

    private func clearCurrentInFlightState(ratingKey: String) {
        retryState.removeRetrying(ratingKey)
        clearRetryHandoff(ratingKey: ratingKey)
        activeJobs.remove(ratingKey)
        // Lens 6 F1–F3: invalidate the entry-point start-attempt token with the slot, so a chain
        // still parked on a negotiation await wakes up stale and exits without re-seeding the row.
        startAttempts.clear(ratingKey)
        // Defense-in-depth: no terminal transition should leave optimize progress/ETA samples
        // behind for a key that is no longer in flight — a later re-download of the same item
        // would display and extrapolate from them.
        clearOptimizeProgress(ratingKey: ratingKey)
        forwardOnlyStallTracker.remove(ratingKey)
        keepaliveCoordinator.clearAuthQuarantine(forRatingKey: ratingKey)
    }

    /// Repairs manager bookkeeping only when start admission has already proven that no live
    /// transfer owns the slot. Prefer the exact attempt owner when one is still registered;
    /// otherwise clear the stale rating-key state without manufacturing download authority.
    private func recoverStaleInFlightSlot(ratingKey: String, reason: String) {
        if let owner = inFlightAttempts.owner(forRatingKey: ratingKey) {
            releaseInFlight(for: owner)
            return
        }
        clearCurrentInFlightState(ratingKey: ratingKey)
        recordDownloadDiagnostic("downloads.inflight_stale_recovered", fields: [
            "download_id": .identifier(ratingKey),
            "reason": .label(reason),
        ])
    }

    private func releaseExactEncoderResources(
        for attemptKey: DownloadAttemptKey,
        rowSnapshot: DownloadRecord?
    ) {
        let ratingKey = attemptKey.ratingKey
        // CLEANUP INVARIANT: a transcoded Emby download leaves a live FFmpeg encoder running on
        // the server until ActiveEncodings is deleted. Fire teardown for the minted PlaySessionId
        // on EVERY terminal transition (complete / failed / cancelled / deleted). Best-effort and
        // idempotent — the session map entry is removed so it never fires twice.
        // Resolve the job's OWN backend lane (never `appModel.activeBackend`): a Jellyfin/Emby
        // download can reach a terminal state while the user has switched to another backend, and
        // the DELETE must hit the server the encoder actually runs on. If that lane is no longer
        // configured (signed out), skip now — the persisted `playSessionID` stays put and the launch
        // sweep retries once the lane returns.
        let storeRow = store.record(for: attemptKey)
        let matchingSnapshot = rowSnapshot.flatMap { row in
            row.attemptID == attemptKey.attemptID ? row : nil
        }
        let releaseMetadata = storeRow?.metadata ?? matchingSnapshot?.metadata
        // JF-F5: the delete path (row already removed, snapshot in hand) is the last chance to
        // tear down a persisted-psid encoder — after this the handle is gone and no launch sweep
        // can retry. The policy fires the persisted-psid `.stop` only in this context.
        let rowRemoved = storeRow == nil && matchingSnapshot != nil
        let embySession = appModel.backendSession(for: .emby)
        let embySessionMatchesMetadata = releaseMetadata.map { metadata in
            embySession?.matchesPersistedServer(metadata) == true
        }
        let embyPlaySessionId = embyPlaySessionByAttempt[attemptKey]
        switch DownloadEncoderTeardownPolicy.decision(
            backend: .emby,
            transientPlaySessionID: embyPlaySessionId,
            metadata: releaseMetadata,
            sessionAvailable: embySession != nil,
            sessionMatchesPersistedServer: embySessionMatchesMetadata,
            rowRemoved: rowRemoved
        ) {
        case .none:
            embyPlaySessionByAttempt.removeValue(forKey: attemptKey)
            break
        case .stop(let playSessionId):
            guard let metadata = releaseMetadata,
                  let intent = persistActiveEncodingCleanupIntent(
                    attemptKey: attemptKey,
                    metadata: metadata,
                    playSessionID: playSessionId
                  ) else {
                recordDownloadDiagnostic("downloads.emby_encoder_teardown_skip", fields: [
                    "download_id": .identifier(ratingKey),
                    "reason": .label("cleanup_intent_not_durable"),
                ])
                break
            }
            embyPlaySessionByAttempt.removeValue(forKey: attemptKey)
            executeActiveEncodingCleanupIntent(intent)
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
        let jellyfinPlaySessionId = jellyfinPlaySessionByAttempt[attemptKey]
        switch DownloadEncoderTeardownPolicy.decision(
            backend: .jellyfin,
            transientPlaySessionID: jellyfinPlaySessionId,
            metadata: releaseMetadata,
            sessionAvailable: jellyfinSession != nil,
            sessionMatchesPersistedServer: jellyfinSessionMatchesMetadata,
            rowRemoved: rowRemoved
        ) {
        case .none:
            jellyfinPlaySessionByAttempt.removeValue(forKey: attemptKey)
            break
        case .stop(let playSessionId):
            guard let metadata = releaseMetadata,
                  let intent = persistActiveEncodingCleanupIntent(
                    attemptKey: attemptKey,
                    metadata: metadata,
                    playSessionID: playSessionId
                  ) else {
                recordDownloadDiagnostic("downloads.jellyfin_encoder_teardown_skip", fields: [
                    "download_id": .identifier(ratingKey),
                    "reason": .label("cleanup_intent_not_durable"),
                ])
                break
            }
            jellyfinPlaySessionByAttempt.removeValue(forKey: attemptKey)
            executeActiveEncodingCleanupIntent(intent)
        case .skip(let reason):
            recordDownloadDiagnostic("downloads.jellyfin_encoder_teardown_skip", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(reason),
            ])
        }
    }

    // MARK: - D5: offline metadata + poster caching

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
        DownloadProgressDisplay.fraction(
            for: record,
            displayBytes: displayBytes(for: record),
            staticExpectedBytes: liveRangeProgress[record.ratingKey]?.expectedBytes ?? staticRangeExpectedBytes(for: record),
            estimatedTotalBytes: DownloadPresetPolicy.estimatedTranscodeBytes(for: record))
    }

    private func expectedDownloadBytes(for record: DownloadRecord, liveBytes: Int? = nil) -> Int? {
        DownloadExpectedBytesPolicy.expectedDownloadBytes(
            record: record,
            liveExpectedBytes: liveRangeProgress[record.ratingKey]?.expectedBytes,
            liveBytes: liveBytes,
            staticExpectedBytes: staticRangeExpectedBytes(for: record),
            estimatedTranscodeBytes: DownloadPresetPolicy.estimatedTranscodeBytes(for: record))
    }

    private func liveDisplayBytes(for record: DownloadRecord) -> Int? {
        DownloadLiveRangeProgressPolicy.liveDisplayBytes(
            for: record,
            sample: liveRangeProgress[record.ratingKey])
    }

    private func displayBytes(for record: DownloadRecord, now: Date = Date()) -> Int? {
        let live = liveDisplayBytes(for: record)
        let resumeBytes = record.metadata?.resumeDisplayBytes
        let hasExactResumeData = attemptKey(for: record).map {
            store.hasResumeData(for: $0)
        } ?? false
        let resumableStatus = record.status == .paused
            || record.status == .downloading
            || record.status == .queued
        let resumableDisplay = resumableStatus
            && (record.status == .downloading
                || hasExactResumeData)
            ? resumeBytes
            : nil
        return [live, resumableDisplay]
            .compactMap { $0 }
            .filter { $0 > record.bytes }
            .max()
    }

    private func staticRangeExpectedBytes(for record: DownloadRecord) -> Int? {
        DownloadExpectedBytesPolicy.staticRangeExpectedBytes(for: record)
    }

    private func makeOfflineLibrarySnapshot(from records: [DownloadRecord]) -> OfflineLibrarySnapshot {
        OfflineLibrarySnapshotBuilder.make(
            records: records,
            isQueuePaused: isQueuePaused,
            downloadSpeed: downloadSpeed,
            displayBytes: { record in displayBytes(for: record) },
            trustworthyExpectedBytes: { record in
                liveRangeProgress[record.ratingKey]?.expectedBytes
                    ?? staticRangeExpectedBytes(for: record)
            },
            errorMessage: { record in
                guard record.status == .failed || record.status == .paused,
                      let error = lastError[record.ratingKey] else { return nil }
                // Ordinary paused rows keep the richer progress/byte caption. A blocked Resume,
                // however, must surface why the tap could not reattach to Plex instead of looking
                // like an inert control that remains "Paused — tap to resume" forever.
                if record.status == .paused {
                    if error == .interruptedResumable { return nil }
                    // lastError is attempt-scoped and nothing clears it on sign-in, so a
                    // blocked-resume auth reason goes stale the moment the session returns.
                    // Fall back to the normal paused caption instead of demanding sign-in
                    // from a signed-in user.
                    if error == .notAuthenticated, isBackendConfigured(for: record) { return nil }
                }
                return message(for: error)
            },
            displayProgress: { record in rowDisplayProgress(for: record) },
            statusCaption: { record, backend in statusCaption(for: record, backend: backend) },
            isRetrying: { ratingKey in retryState.isPresentingRetry(ratingKey) }
        )
    }


    private func rowDisplayProgress(for record: DownloadRecord) -> Double? {
        DownloadRowDisplayPolicy.displayProgress(for: record,
                                                 fraction: displayFraction(for: record),
                                                 serverPrepProgress: optimizeProgress[record.ratingKey])
    }

    private func statusCaption(for record: DownloadRecord, backend: DownloadBackendKind) -> String {
        let isActive = activeJobs.contains(record.ratingKey) || record.status == .downloading
        let failureCaption = record.status == .failed ? lastError[record.ratingKey].map(message(for:)) : nil
        return DownloadRowStatusCaptionPolicy.caption(.init(
            record: record,
            backend: backend,
            displayFraction: displayFraction(for: record),
            displayBytes: displayBytes(for: record),
            isActive: isActive,
            isBackendConfigured: isBackendConfigured(for: record),
            isTranscodeLimited: record.status == .downloading
                && DownloadDisplayClassifier.isLiveTranscoderSourced(record),
            serverPrepState: optimizeState[record.ratingKey],
            serverPrepProgress: optimizeProgress[record.ratingKey],
            serverPrepETA: optimizeETA[record.ratingKey],
            downloadETA: downloadETA[record.ratingKey],
            downloadSpeedBytesPerSecond: downloadSpeed[record.ratingKey],
            isRetrying: retryState.isPresentingRetry(record.ratingKey),
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
                                      startedAtEpochSeconds: TimeInterval,
                                      mediaTitle: String,
                                      server: URL,
                                      token: String,
                                      identity: ClientIdentity) async throws -> Part {
        var pollHealth = PlexOptimizePollHealthPolicy.State()
        var successfulCompletionObservedAt: TimeInterval?
        var resolvedBackgroundProcessingKey = backgroundProcessingKey
        var bgKeyRetriesRemaining = 3
        while !Task.isCancelled {
            if PlexOptimizeDeadlinePolicy.isExpired(
                startedAtEpochSeconds: startedAtEpochSeconds,
                nowEpochSeconds: Date().timeIntervalSince1970
            ) {
                recordDownloadDiagnostic("downloads.optimize_poll_timed_out", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(targetName),
                    "deadline_hours": .int(24),
                ])
                throw DownloadError.optimizeTimedOut
            }
            // Orphan guard (audit B.9): Task cancellation alone is not enough — a delete can
            // race this loop before/without a registered Task handle, and a concurrent reap can
            // remove the queue row entirely. Re-check LIVE app state every iteration and stop
            // polling the server the moment this download no longer exists or lost its slot.
            let rowExists = store.contains(ratingKey: ratingKey)
            guard ServerPrepRefreshPolicy.plexPrepPollerShouldContinue(
                rowExists: rowExists,
                slotActive: activeJobs.contains(ratingKey)
            ) else {
                recordDownloadDiagnostic("downloads.optimize_poll_orphan_exit", fields: [
                    "download_id": .identifier(ratingKey),
                    "row_exists": .bool(rowExists),
                ])
                throw CancellationError()
            }
            // A-1 (audit lens 8): this loop can outlive the enqueue-time server/token snapshot by
            // hours. Re-resolve the Plex lane every iteration — on sign-out or a server change,
            // park the row for deferred resume instead of polling the dead snapshot forever.
            guard let liveSession = appModel.backendSession(for: .plex),
                  store.metadata(for: ratingKey)
                      .map(liveSession.matchesPersistedServer) != false else {
                recordDownloadDiagnostic("downloads.optimize_poll_deferred", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(targetName),
                    "reason": .label("plex_session_mismatch_or_unavailable"),
                ])
                throw DownloadLifecycleCancellation.plexSessionUnavailable
            }
            // Shadow the enqueue-time snapshot with the live lane so token refresh / address
            // change keeps the poll (and the eventual Part download URL built by our caller from
            // the SAME lane on resume) authenticated.
            let server = liveSession.baseURL
            let token = liveSession.token
            let fetch = await fetchCurrentMediaItemForPoll(ratingKey: ratingKey, server: server,
                                                           token: token, identity: identity)
            switch PlexOptimizePollHealthPolicy.register(fetch.outcome, state: &pollHealth) {
            case .none:
                break
            case .emitUnreachable(let bucket, let consecutiveFailures):
                // Distinguishes an unreachable/auth-dead poll loop from a genuinely slow render.
                recordDownloadDiagnostic("downloads.optimize_poll_unreachable", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(targetName),
                    "consecutive_failures_bucket": .label(bucket),
                    "consecutive_failures": .int(consecutiveFailures),
                    "auth_rejected": .bool(fetch.outcome == .authRejected),
                ])
            case .failAuthDead:
                recordDownloadDiagnostic("downloads.optimize_poll_auth_dead", fields: [
                    "download_id": .identifier(ratingKey),
                    "target": .label(targetName),
                ])
                throw DownloadError.notAuthenticated
            }
            if let metadata = fetch.item {
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
            // so "one Labstream active job" is not enough to prove that lone activity belongs
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
            // The type-42 key lookup is best-effort at enqueue/resume time. Retry it here after a
            // transient miss so losing one early request cannot also lose successful-completion
            // detection and fall back to the legacy 24-hour metadata-only loop. Bounded: a server
            // that never exposes the type-42 playlist must not eat an extra failing request every
            // poll tick for the whole (up to 24h) window, and without a queueTitle the key could
            // never be used anyway.
            if resolvedBackgroundProcessingKey == nil, queueTitle != nil, bgKeyRetriesRemaining > 0 {
                bgKeyRetriesRemaining -= 1
                resolvedBackgroundProcessingKey = await bgKeyForPolling(
                    server: server, token: token, identity: identity)
            }
            if let backgroundProcessingKey = resolvedBackgroundProcessingKey,
               let queueTitle,
               let status = await optimizerQueueStatus(backgroundProcessingKey: backgroundProcessingKey,
                                                       queueTitle: queueTitle, server: server,
                                                       token: token, identity: identity) {
                // Pause/delete may have landed while this task was suspended in the await above
                // (releaseInFlight cancels the task, but an already-produced result still resumes
                // the continuation). Do not stamp finalizing display state or throw terminal
                // errors on behalf of a superseded attempt.
                guard !Task.isCancelled else { throw CancellationError() }
                switch status.outcome {
                case .failed:
                    downloadLog.error("optimizer-failed failed=\(status.itemsFailedCount ?? -1, privacy: .public) successful=\(status.itemsSuccessfulCount ?? -1, privacy: .public)")
                    recordDownloadDiagnostic("downloads.optimize_status_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "failed_count": .int(status.itemsFailedCount ?? -1),
                        "successful_count": .int(status.itemsSuccessfulCount ?? -1),
                    ])
                    throw DownloadError.optimizeFailed("Plex server could not create an optimized version; optimized-version storage may be read-only.")
                case .succeeded:
                    let now = Date().timeIntervalSince1970
                    if successfulCompletionObservedAt == nil {
                        successfulCompletionObservedAt = now
                        markServerPrepFinalizing(ratingKey: ratingKey)
                        refreshRecords()
                        recordDownloadDiagnostic("downloads.optimize_status_completed", fields: [
                            "download_id": .identifier(ratingKey),
                            "successful_count": .int(status.itemsSuccessfulCount ?? -1),
                            "metadata_grace_seconds": .int(
                                Int(PlexOptimizeCompletionPolicy.metadataIndexingGraceSeconds)),
                        ])
                    }
                    if PlexOptimizeCompletionPolicy.missingPartAction(
                        outcome: .succeeded,
                        firstSuccessObservedAt: successfulCompletionObservedAt,
                        now: now,
                        metadataInspected: fetch.item != nil
                    ) == .failMissingOutput {
                        recordDownloadDiagnostic("downloads.optimize_completed_part_missing", fields: [
                            "download_id": .identifier(ratingKey),
                            "target": .label(targetName),
                        ])
                        throw DownloadError.optimizeFailed(
                            "Plex finished optimizing, but Labstream could not locate the resulting version.")
                    }
                case .active:
                    // A success reading that flaps back to active was spurious (e.g. a stale
                    // same-title queue row matched by `.last(where:)`); disarm the deadline so
                    // only a stable succeeded status ages toward failMissingOutput.
                    successfulCompletionObservedAt = nil
                }
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
        let settings = DownloadPresetPolicy.customDownloadProfile(named: targetName)?.settings ?? DownloadPresetPolicy.mediaSettings(forTargetName: targetName)
        let targetDimensions = settings.videoResolution
            .flatMap(DownloadResolutionLabel.dimensions(forVideoResolution:))
        return OptimizedVersionMatch.candidate(
            from: media,
            baselinePartIDs: baselinePartIDs,
            targetDimensions: targetDimensions,
            targetVideoKbps: settings.maxVideoBitrateKbps,
            isOriginalQuality: DownloadPresetPolicy.isPlexOriginalQualityTarget(targetName),
            sourceHeight: sourceHeight)
    }

    func fetchCurrentMediaItem(ratingKey: String, server: URL, token: String,
                                       identity: ClientIdentity) async -> MediaItem? {
        // Use the full detail shape, not the lean optimize status shape, so any offline
        // snapshot refreshed from this item carries chapters and part/stream metadata.
        // Optimized downloads need that source metadata just as much as original downloads:
        // the optimized MP4 itself is downloaded later, but chapters and external text
        // subtitles come from the source item.
        let req = Self.currentMediaItemRequest(ratingKey: ratingKey, server: server,
                                               token: token, identity: identity)
        return (try? await appModel.client.send(req, as: MetadataResponse.self))?
            .mediaContainer.metadata.first
    }

    private static func currentMediaItemRequest(ratingKey: String, server: URL, token: String,
                                                identity: ClientIdentity) -> PlexRequest {
        PlexRequest(url: server.appendingPathComponent("/library/metadata/\(ratingKey)"),
                    method: "GET",
                    queryItems: [
                        .init(name: "includeChapters", value: "1"),
                        .init(name: "includeMarkers", value: "1"),
                        .init(name: "includeExtras", value: "1"),
                    ],
                    headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// A-1 (audit lens 8): the poll-loop variant of `fetchCurrentMediaItem` that surfaces WHY a
    /// fetch produced no item, so the poller can tell auth revocation and unreachable servers
    /// apart from a render still in progress instead of swallowing everything to nil.
    private func fetchCurrentMediaItemForPoll(
        ratingKey: String, server: URL, token: String, identity: ClientIdentity
    ) async -> (item: MediaItem?, outcome: PlexOptimizePollHealthPolicy.FetchOutcome) {
        let req = Self.currentMediaItemRequest(ratingKey: ratingKey, server: server,
                                               token: token, identity: identity)
        do {
            let response = try await appModel.client.send(req, as: MetadataResponse.self)
            return (response.mediaContainer.metadata.first, .success)
        } catch PlexError.unauthorized {
            return (nil, .authRejected)
        } catch {
            return (nil, .failure)
        }
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
            var outcome: PlexOptimizeCompletionPolicy.Outcome {
                PlexOptimizeCompletionPolicy.outcome(
                    state: state,
                    successfulCount: itemsSuccessfulCount,
                    failedCount: itemsFailedCount)
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

        // Lens 6 F6: the /activities fetch above is an await, so a delete/release can land inside
        // this poll cycle. Never re-plant server-prep progress/state for a job that no longer
        // holds its in-flight slot — a stale write here re-creates prep-progress UI state for a
        // removed row.
        guard activeJobs.contains(ratingKey) else { return }

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
              let durationMs = records.first(where: { $0.ratingKey == ratingKey })?
                    .metadata?.duration ?? store.duration(for: ratingKey),
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
                // also active in Labstream. This is the live Devil Wears Prada shape: the background
                // job has progress/speed but no per-job ratingKey.
                ?? ((jobs.jobs.count == 1 && thisIsActiveConversion) ? jobs.jobs.first : nil)
                // Legacy fallback for older PMS shapes without per-job ratingKey/title/queue active
                // attribution: if there is exactly one background job and exactly one active
                // Labstream download, it is unambiguous. Never use first-job fallback when PMS
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

            // Lens 6 F6: the queue/jobs fetches above are awaits — gate the progress-map writes
            // on the slot still being held so a delete inside this probe cycle cannot re-plant
            // stale prep progress.
            if isActiveConversion, activeJobs.contains(ratingKey) {
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
            } else if thisIsQueuedConversion, activeJobs.contains(ratingKey) {
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
