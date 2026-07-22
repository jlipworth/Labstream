import Foundation
import AVFoundation
import PMSKit

actor DownloadPlaybackValidationLimiter {
    private var busy = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []

    func wait() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = UUID()
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        guard admitted else { throw CancellationError() }
        if Task.isCancelled {
            signal()
            throw CancellationError()
        }
    }

    func signal() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    #if DEBUG
    var queuedWaiterCountForTesting: Int { waiters.count }
    #endif
}

struct BackgroundDownloadSessionDiagnosticSnapshot: Sendable {
    let opaqueInflightCount: Int
    let rangeInflightCount: Int
    let haltedRangeKeyCount: Int
    let pendingBackgroundCompletionOperationCount: Int
    let deferredBackgroundCompletionIdentifierCount: Int
    let backgroundCompletionHandlerCount: Int
    let finalizingRatingKeyCount: Int
    let pendingTempCleanupBytes: Int
}

/// Wraps a background `URLSession` so transfers survive app suspension and
/// relaunch. The OS may defer background transfers while the app is backgrounded
/// or the device sleeps — surface that reality in the UI (research/10): a
/// "download" is best-effort and may stall until the app/system daemon can run.
///
/// Delegate callbacks land off the main actor; we hop to `@MainActor` for record
/// updates via `onChange`. The store itself is internally locked.
final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    enum RevalidationAdmission: Sendable, Equatable {
        case started(requestID: UUID)
        case deferredForBackgroundWake
        case alreadyFinalizing
        case unavailable
    }

    enum RevalidationRequestOutcome: Sendable, Equatable {
        case finished
        case cancelled
    }

    private enum FinalizationAdmission: Sendable, Equatable {
        case started(requestID: UUID)
        case alreadyFinalizing
        case unavailable
    }

    struct FinalizerRequest: Sendable {
        fileprivate let id: UUID
        let attemptKey: DownloadAttemptKey
        fileprivate let destination: URL
        fileprivate let bytes: Int
        fileprivate let validationLabel: String
        fileprivate let expectedExactBytes: Int?
        fileprivate let publishesWorkingFile: Bool
        fileprivate let holdsBackgroundCompletion: Bool
        var isRevalidation: Bool { !publishesWorkingFile }
    }

    struct PlaybackValidation: Sendable {
        let played: Bool
        let reason: String
        let durationMs: Int?
        let detail: String?
    }

    enum StartupActivationResult: Sendable, Equatable {
        case activated(cancelledTaskCount: Int)
        case alreadyActive
        case alreadyPurging
        case failed(reason: String)
    }

    private enum StartupAdmissionState: Sendable, Equatable {
        case dormant
        case purging
        case active
    }

    private static let backgroundCompletionPersistenceTimeout: TimeInterval = 5

    /// The fixed background-session identifier. Shared with the app delegate so it can
    /// route `handleEventsForBackgroundURLSession` to THIS session's completion handler.
    #if os(macOS)
    /// macOS has no simulator/container-per-worktree isolation, so local host builds use
    /// per-worktree bundle ids. The background URLSession namespace must follow that effective
    /// app identity too; otherwise two Mac worktrees can accidentally reattach each other's
    /// in-flight transfers even though their sandbox containers are separate.
    static var identifier: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jlipworth.Labstream"
        return "\(bundleID).downloads.background"
    }
    #else
    /// Preserve the shipped iOS/visionOS background session identifier so existing background
    /// transfers can still reattach across app updates.
    static let identifier = "com.visionplay.downloads.background"
    #endif

    private let store: DownloadStore
    /// Production releases through the process-wide app-delegate registry. Keeping this edge
    /// injectable lets tests exercise one session's completion gate without sharing global
    /// handler state with every concurrently constructed DownloadManager.
    private let releaseBackgroundCompletion:
        @MainActor @Sendable (BackgroundDownloadCompletionReleaseBatch) -> Void
    /// Non-nil only in deterministic transport tests. Custom URL protocols are supported by an
    /// in-process foreground session, not by the device background-transfer daemon, so supplying
    /// this seam deliberately selects the same foreground path used by simulator downloads.
    private let injectedProtocolClasses: [AnyClass]?
    private let fileManager = FileManager.default
    private struct OpaqueTransfer {
        let attemptKey: DownloadAttemptKey
        let workingURL: URL
        var ratingKey: String { attemptKey.ratingKey }
        var attemptID: DownloadAttemptID { attemptKey.attemptID }

        init(attemptKey: DownloadAttemptKey, destination: URL) {
            self.attemptKey = attemptKey
            self.workingURL = destination
        }
    }
    /// taskIdentifier -> exact attempt-owned opaque transfer.
    private var inflight: [Int: OpaqueTransfer] = [:]
    /// taskIdentifier -> in-flight static byte-range task state. Current closed segments form the
    /// bounded train; an open-ended task is retained only as the current unknown-total fallback.
    private var rangeInflight: [Int: RangeTransfer] = [:]
    /// Finished segment bodies stashed on disk ahead of the durable checkpoint (out-of-order
    /// arrivals), keyed by exact attempt then segment offset. Kept until the checkpoint reaches them and
    /// `appendAssembledSegment` folds them in. Each entry is also manifested in `DownloadStore` and
    /// stored beside the media file so a process death does not waste already-completed bodies.
    /// The durable partial remains the source of truth. Each entry records the response's
    /// resource validator so the drain can re-verify version consistency at splice time (B.2).
    /// Guarded by `lock`.
    private var heldRangeSegments: [DownloadAttemptKey: [Int: (url: URL, length: Int, validator: String?)]] = [:]
    /// Previous held bodies retained because their replacement manifest write failed. The old
    /// on-disk manifest may still reference them, while the dirty writer may later commit the new
    /// body. Keep same-run ownership so drain/purge/delete can remove both generations.
    /// Guarded by `lock`.
    private var heldRangeRetainedPredecessorURLs: [DownloadAttemptKey: [Int: Set<URL>]] = [:]
    /// Train generation per exact attempt (B.2/B.3(b)): bumped whenever the whole segment train is torn
    /// down (changed-resource restart, adopted whole-file 200). A finished body carries the epoch
    /// captured at its delegate finish; the off-queue apply discards the body when the train moved
    /// on — a stale sibling must neither splice old-resource bytes nor trigger another destructive
    /// restart against the replacement file. Guarded by `lock`.
    private var rangeTrainEpochs: [DownloadAttemptKey: Int] = [:]
    /// RatingKeys whose static Range lane must not create replacement work — inserted by
    /// `cancel`/`pause`, checked before each continuation/retry, and cleared on fresh user start/resume.
    /// Without it, a delegate callback racing after `cancel`/`pause` could resurrect a deleted file.
    /// The value records WHY the lane halted: the finished-body disposition needs the halt KIND at
    /// the halt site itself (a pause-halt preserves a just-finished body, a cancel-halt discards
    /// it), because the persisted `.paused` status lands only at the END of the async pause chain —
    /// keying preservation on the store status silently discarded bodies finishing inside that
    /// window. A cancel never downgrades to a pause (the row may be mid-delete).
    private var rangeHaltKinds: [DownloadAttemptKey: StaticRangeHaltKind] = [:]
    /// Range-specific retry counters that must not be reset by URLSession progress callbacks. They
    /// bound validator-change restart loops and misaligned `Content-Range` retries until an actual
    /// durable append proves forward progress.
    private var staticRangeRetryBudget = StaticRangeRetryBudget()
    /// taskIdentifiers whose expected-size has already been logged once (diagnostics).
    private var loggedExpectation: Set<Int> = []
    /// Retry count by exact attempt for transient URLSession drops that provide resume data.
    private var retryCounts: [DownloadAttemptKey: Int] = [:]
    /// Exact `.unverified` rows whose local probe was withheld for an OS background wake. Guarded
    /// by `lock` so registration and gate-drain extraction are one atomic transition.
    private var backgroundDeferredRevalidationKeys: Set<DownloadAttemptKey> = []
    /// JF-F2 loop guard: consecutive `.truncated` finalize outcomes per attempt. Deliberately NOT
    /// reset by `start`/`clearRetryCount` (a retry that truncates again must keep counting toward
    /// the parking budget); reset only on a `.complete` finalize. Only touched inside
    /// `finalizeTransferredFile`, guarded by `finalizationStateQueue` (async context — no NSLock).
    /// Consecutive truncation failures belong to the visible download, not a disposable attempt.
    /// Retry intentionally mints a new attempt; keying this budget by attempt made parking
    /// unreachable for a repeatedly truncated server response.
    private var truncationFailureCounts: [String: Int] = [:]
    /// Bounded per-row backend/request rehydrations after auth/forbidden HTTP responses on static
    /// Range tasks. This is intentionally separate from transient retry counts: 403 should not blindly
    /// replay the same URL, but one fresh backend negotiation may mint a usable request.
    private var rangeHTTPRehydrateCounts: [DownloadAttemptKey: Int] = [:]
    /// Exact attempts currently inside post-transfer finalization. A duplicated URLSession/adoption
    /// callback must not launch a second AVPlayer validation for the same finished file, while a
    /// replacement attempt with the same rating key must not be suppressed by the older finalizer.
    private var finalizerRequestIDsByAttempt: [DownloadAttemptKey: UUID] = [:]
    private let finalizationStateQueue = DispatchQueue(label: "com.labstream.downloads.finalization-state")
    /// Last UI refresh across the whole downloads screen; progress callbacks can arrive many
    /// times per second per task, so per-row throttling still scales linearly with concurrent
    /// downloads and can overwhelm the Offline list. Coalesce globally instead.
    private var lastProgressNotify: Date?
    /// Progress milestones already mirrored to the diagnostics ring buffer per task.
    private var loggedProgressMilestones: [Int: Set<Int>] = [:]
    /// Rows whose blob-resumed live progress was rebased against the resume display watermark;
    /// the rebase diagnostic is recorded once per row per app run.
    private var loggedRangeBlobResumeDisplayRebaseKeys: Set<String> = []
    /// Last range-progress diagnostic per task. This is intentionally separate from UI throttling:
    /// the off-head headset probe needs durable breadcrumbs showing whether delegate progress kept
    /// arriving, without logging every `didWriteData` callback.
    private var lastRangeProgressDiagnostic: [Int: BackgroundRangeProgressDiagnosticSnapshot] = [:]
    /// Stale delegates can replay thousands of buffered progress callbacks after an attempt is
    /// replaced. Preserve the first diagnostic for each exact attempt/phase without flooding the
    /// rotating evidence log with identical events.
    private var loggedStaleAttemptCallbackPhases: Set<String> = []
    /// Cap UI progress publication to roughly 4 Hz total while preserving terminal updates.
    private let progressNotifyInterval: TimeInterval = 0.5
    private static let appBundleIdentifier = "com.jlipworth.Labstream"
    private let lock = NSLock()
    /// Background URLSession construction itself can trigger delegate delivery. Keep the session
    /// dormant until schema-v3 ownership has committed and every pre-current task has disappeared.
    private var startupAdmissionState: StartupAdmissionState = .dormant
    /// Destructive schema reset has no trustworthy row ownership. Unlike a current-schema purge,
    /// every callback is rejected until the daemon task list reaches an empty fixed point.
    private var startupRejectsAllCallbacks = false
    /// Cancellation completion can race a late body/progress callback. Once purge claims an ID it
    /// is rejected for the rest of this session object's life, even after admission opens.
    private var permanentlyRejectedTaskIdentifiers: Set<Int> = []

    /// #227/#231: the static byte-range lane follows the Apple-standard large-transfer shape: one
    /// background `URLSessionDownloadTask` for the remaining bytes, using an open-ended
    /// `Range: bytes=<durableOffset>-` request when a durable partial already exists (and at zero
    /// for uniform validation). URLSession resume data is the first-class pause/failure/sleep resume
    /// mechanism; if the blob is missing, stale, or loses its temp file, we fall back to the durable
    /// partial file size and create a fresh open-ended Range task from there.
    private static let playbackValidationLimiter = DownloadPlaybackValidationLimiter()
    private let injectedPlaybackValidator:
        (@Sendable (URL, Double?) async -> PlaybackValidation)?
    private static let rangeProgressDiagnosticByteInterval = 32 * 1_024 * 1_024
    private let rangeRemainderPolicy = StaticRangeRemainderRequestPolicy()
    /// #169: a finished Range response-body append must not run on the (serial) URLSession delegate
    /// queue, or it stalls every other download's progress/completion callbacks for the copy's
    /// duration. The delegate hop only does an O(1) rename of the OS temp into a stash; the heavy
    /// append + continuation decision run here.
    private let rangeIOQueue = DispatchQueue(label: "com.labstream.downloads.range-io")
    /// HTTP edge/origin failures often arrive as a burst during a network transition. Delay retry
    /// attempts slightly instead of immediately hammering the same unavailable edge.
    private let rangeRetryQueue = DispatchQueue(label: "com.labstream.downloads.range-retry")
    /// Number of finished background transfers whose durable-file/finalization work has not yet
    /// reached a safe state. `urlSessionDidFinishEvents` must not release the app delegate
    /// background completion handler until these reach zero, or visionOS can suspend us between a
    /// temp-stash move and the append/finalize/status write that makes the row durable.
    private var backgroundCompletionGate = BackgroundDownloadCompletionGate()
    /// Last scene phase recorded only for diagnostics; scene changes no longer alter the transfer
    /// shape because foreground and background both use one open-ended remainder task.
    /// Task identifiers intentionally abandoned while replacing a range task (duplicate supersede,
    /// blob adoption). If their delegate completions race in after
    /// cancellation, ignore their temp bytes.
    private var supersededRangeTaskIdentifiers: Set<Int> = []
    /// #227: bounded per-row budget for re-resuming a failed continuous remainder from the resume
    /// data the OS handed back. Cleared with the other retry counters once durable bytes append.
    private var rangeBlobResumeCounts: [DownloadAttemptKey: Int] = [:]
    /// #212: rows whose `.requestNeeded` rebuild is in flight. DownloadManager re-mints the
    /// authenticated request on the main actor (a network round-trip); the app-delegate background
    /// completion handler must be held until that finishes or times out, or the OS suspends us
    /// between the append and the next task's creation and the transfer stalls until the next
    /// (rate-limited) wake — the decisive half of the off-head multi-GB stall.
    /// Value = the CURRENT grace generation for the key. The 20s timeout closure captures its own
    /// generation and only ends a grace it still owns: without this, two begin/end cycles within
    /// the window let cycle 1's timer end cycle 2's grace early — releasing the background
    /// completion handler mid-rebuild (the device stall regression this grace exists to prevent),
    /// invisibly (diagnostics would show a normal-looking "timeout" end).
    private var rangeRequestRebuildGraceGenerations: [DownloadAttemptKey: UUID] = [:]
    private static let rangeRequestRebuildGraceSeconds: TimeInterval = 20

    /// One in-flight Range task of a static byte-range download. Unlike the opaque `downloadTask`
    /// lane, the bytes for the current task live in the OS temp file until `didFinishDownloadingTo`
    /// hands them over, at which point we append them into `destination` (the durable partial, which
    /// IS the final file). `request` is the base (un-ranged) request used for durable fallback/retry;
    /// it is `nil` for a task adopted on relaunch because auth headers cannot be reconstructed here.
    private struct RangeTransfer {
        let attemptKey: DownloadAttemptKey
        let request: URLRequest?
        let workingURL: URL
        let expectedBytes: Int?
        var baseOffset: Int
        /// Byte length of this closed-range segment, or nil for an open-ended remainder.
        var segmentLength: Int?
        var responseStatus: Int?
        var bodyBytesWritten: Int
        let remainderReason: String?

        var ratingKey: String { attemptKey.ratingKey }
        var attemptID: DownloadAttemptID { attemptKey.attemptID }

        var totalBytes: Int { baseOffset + bodyBytesWritten }

        func replacingExpectedBytes(_ expectedBytes: Int?) -> RangeTransfer {
            RangeTransfer(ratingKey: ratingKey,
                          attemptID: attemptID,
                          request: request,
                          destination: workingURL,
                          expectedBytes: expectedBytes,
                          baseOffset: baseOffset,
                          segmentLength: segmentLength,
                          responseStatus: responseStatus,
                          bodyBytesWritten: bodyBytesWritten,
                          remainderReason: remainderReason)
        }

        init(ratingKey: String, attemptID: DownloadAttemptID, request: URLRequest?,
             destination: URL, expectedBytes: Int?, baseOffset: Int,
             segmentLength: Int?, responseStatus: Int?, bodyBytesWritten: Int,
             remainderReason: String?) {
            self.attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
            self.request = request
            self.workingURL = destination
            self.expectedBytes = expectedBytes
            self.baseOffset = baseOffset
            self.segmentLength = segmentLength
            self.responseStatus = responseStatus
            self.bodyBytesWritten = bodyBytesWritten
            self.remainderReason = remainderReason
        }
    }

    private struct DuplicateRangeTaskDecision {
        let existingTaskIdentifier: Int
        let existingEntry: RangeTransfer
        let shouldReplaceExisting: Bool
    }

    private func rangeTaskSnapshot(taskIdentifier: Int,
                                   entry: RangeTransfer,
                                   bodyBytesWritten: Int? = nil) -> StaticRangeTaskSnapshot {
        StaticRangeTaskSnapshot(
            taskIdentifier: taskIdentifier,
            downloadID: entry.ratingKey,
            baseOffset: entry.baseOffset,
            bodyBytesWritten: bodyBytesWritten ?? entry.bodyBytesWritten
        )
    }

    /// Enforce the ownership invariant: a static byte-range row may have only one authoritative
    /// URLSession range task at a time. A stale/lower-offset task must never publish progress or
    /// append after a newer task has taken over.
    private func duplicateRangeTaskDecision(for candidate: RangeTransfer) -> DuplicateRangeTaskDecision? {
        let snapshots = rangeInflight.map { rangeTaskSnapshot(taskIdentifier: $0.key, entry: $0.value) }
        guard let decision = StaticRangeTaskSelectionPolicy.duplicateDecision(
            candidate: rangeTaskSnapshot(taskIdentifier: -1, entry: candidate),
            existingTasks: snapshots
        ),
              let existing = rangeInflight[decision.existingTaskIdentifier] else { return nil }
        return DuplicateRangeTaskDecision(existingTaskIdentifier: decision.existingTaskIdentifier,
                                          existingEntry: existing,
                                          shouldReplaceExisting: decision.shouldReplaceExisting)
    }

    /// Same as `duplicateRangeTaskDecision` but, for a closed-range SEGMENT (segmentLength != nil),
    /// only considers existing tasks at the SAME baseOffset — distinct segments of one download's
    /// pre-queued train must coexist. Open-ended remainders keep the original cross-offset scope.
    private func duplicateSegmentDecision(for candidate: RangeTransfer) -> DuplicateRangeTaskDecision? {
        guard candidate.segmentLength != nil else { return duplicateRangeTaskDecision(for: candidate) }
        let pool = rangeInflight.filter { $0.value.ratingKey == candidate.ratingKey
            && $0.value.baseOffset == candidate.baseOffset }
        guard let decision = StaticRangeTaskSelectionPolicy.duplicateDecision(
            candidate: rangeTaskSnapshot(taskIdentifier: -1, entry: candidate),
            existingTasks: pool.map { rangeTaskSnapshot(taskIdentifier: $0.key, entry: $0.value) }),
              let existing = rangeInflight[decision.existingTaskIdentifier] else { return nil }
        return DuplicateRangeTaskDecision(existingTaskIdentifier: decision.existingTaskIdentifier,
                                          existingEntry: existing, shouldReplaceExisting: decision.shouldReplaceExisting)
    }

    private func newerRangeTaskIdentifier(for entry: RangeTransfer,
                                          currentTaskIdentifier: Int,
                                          currentBodyBytes: Int,
                                          segmentScoped: Bool = false) -> Int? {
        let pool = rangeInflight.filter {
            !segmentScoped || $0.value.baseOffset == entry.baseOffset
        }
        return StaticRangeTaskSelectionPolicy.newerTaskIdentifier(
            than: rangeTaskSnapshot(
                taskIdentifier: currentTaskIdentifier,
                entry: entry,
                bodyBytesWritten: currentBodyBytes
            ),
            in: pool.map { rangeTaskSnapshot(taskIdentifier: $0.key, entry: $0.value) }
        )
    }

    private func supersedeRangeTasksLocked(ratingKey: String, keeping keptIdentifier: Int? = nil) -> [Int] {
        let identifiers = rangeInflight
            .filter { id, entry in
                entry.ratingKey == ratingKey && id != keptIdentifier
            }
            .map(\.key)
        for identifier in identifiers {
            rangeInflight.removeValue(forKey: identifier)
            supersededRangeTaskIdentifiers.insert(identifier)
        }
        return identifiers
    }

    /// Supersede only the tasks for `ratingKey` at exactly `offset` (except `keeping`), leaving
    /// sibling segments at other offsets untouched.
    private func supersedeRangeSegmentTasksLocked(ratingKey: String, offset: Int, keeping: Int? = nil) -> [Int] {
        let ids = rangeInflight.filter { id, e in e.ratingKey == ratingKey && e.baseOffset == offset && id != keeping }.map(\.key)
        for id in ids { rangeInflight.removeValue(forKey: id); supersededRangeTaskIdentifiers.insert(id) }
        return ids
    }

    private func cancelURLSessionTask(identifier: Int) {
        urlSession.getAllTasks { tasks in
            tasks.first { $0.taskIdentifier == identifier }?.cancel()
        }
    }

    /// Called on any progress/completion so the manager can refresh records.
    var onChange: (() -> Void)?

    /// D3: invoked from each delegate failure/validation path so the manager can
    /// surface a reason (`lastError`) instead of the row vanishing without cause.
    /// Lands off the main actor; the manager hops to `@MainActor` to apply it.
    var onError: ((_ ratingKey: String, _ error: DownloadManager.DownloadError) -> Void)?

    /// Requests that DownloadManager rebuild an authenticated static-byte-range request for a row.
    /// BackgroundDownloadSession intentionally does not know Plex/Jellyfin/Emby auth/session policy;
    /// this callback is the narrow bridge from URLSession delegate mechanics back to backend-owned
    /// request rehydration.
    var onRangeRequestNeeded: ((_ ratingKey: String, _ reason: BackgroundRangeRequestReason) -> Void)?

    /// Ephemeral live byte observations for static Range tasks. The store remains checkpoint-only
    /// for durable/resumable accounting; DownloadManager uses these samples for active speed/ETA.
    var onRangeLiveProgress: ((_ ratingKey: String, _ liveBytes: Int, _ expectedBytes: Int?) -> Void)?

    /// Finalization is owned by DownloadManager's exact-attempt work registry. This callback only
    /// brokers an already synchronously admitted request; it must either register the request or
    /// call `abandonFinalizerRequest` so the session's admission/background accounting balances.
    var onFinalizerRequest: ((_ request: FinalizerRequest) -> Void)?
    /// Revalidation is intentionally forbidden while an OS background wake handler is stored.
    /// These callbacks let the manager distinguish a real local probe from that deferral and
    /// retry as soon as the global gate drains instead of suppressing the row for a blind timeout.
    var onRevalidationProbeDeferred:
        ((_ attemptKey: DownloadAttemptKey, _ requestID: UUID) -> Void)?
    var onRevalidationRequestFinished:
        ((_ attemptKey: DownloadAttemptKey, _ requestID: UUID,
          _ outcome: RevalidationRequestOutcome) -> Void)?
    var onBackgroundCompletionGateDrained: ((_ deferredKeys: Set<DownloadAttemptKey>) -> Void)?

    /// Invoked when a static-Range remainder exhausts its retry/rehydration budget on an auth HTTP
    /// status (401/403). Logout revokes the JF/Emby token server-side, so an in-flight remainder can
    /// 401 purely because the user signed out — a post-hoc casualty, not a real error. The manager
    /// (on the main actor) confirms whether the backend session is actually gone and either parks the
    /// row in the deferred "waiting for a valid session" state or, if still signed in, fails it. Lands
    /// off the main actor; when unset the delegate falls back to its normal `.failed` path. Carries the
    /// failing `attemptKey` so the manager's terminal/quiesce disposition — which runs after a main-actor
    /// Task hop — can fence on the attempt that actually 401'd and no-op if a newer attempt has since
    /// taken the row, instead of resolving whatever attempt is current when the hop executes.
    var onRangeAuthHTTPFailure: ((_ ratingKey: String, _ httpStatus: Int, _ attemptKey: DownloadAttemptKey) -> Void)?

    /// True when this process currently owns an opaque or Range URLSession task for the row.
    /// `DownloadManager.activeJobs` is intentionally broader app-level bookkeeping and can survive
    /// a relaunch-adopted task; stale active slots must not make a queued static partial
    /// look live forever.
    func isTrackingTransfer(ratingKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inflight.values.contains { $0.ratingKey == ratingKey }
            || rangeInflight.values.contains { $0.ratingKey == ratingKey }
    }

    func cleanupOrphanedNetworkTemps() {
        guard isStartupAdmissionActive else { return }
        urlSession.getAllTasks { [weak self] tasks in
            self?.sweepOrphanedNetworkTemps(liveTaskCount: tasks.count, context: .manualScan)
        }
    }

    func diagnosticSnapshot() -> BackgroundDownloadSessionDiagnosticSnapshot {
        lock.lock()
        let opaqueInflightCount = inflight.count
        let rangeInflightCount = rangeInflight.count
        let haltedRangeKeyCount = rangeHaltKinds.count
        let pendingBackgroundCompletionOperationCount = backgroundCompletionGate.pendingOperationCount
        let deferredBackgroundCompletionIdentifierCount = backgroundCompletionGate.deferredIdentifierCount
        let backgroundCompletionHandlerCount = backgroundCompletionGate.pendingHandlerCount
        lock.unlock()
        let finalizingRatingKeyCount = finalizationStateQueue.sync {
            finalizerRequestIDsByAttempt.count
        }
        return BackgroundDownloadSessionDiagnosticSnapshot(
            opaqueInflightCount: opaqueInflightCount,
            rangeInflightCount: rangeInflightCount,
            haltedRangeKeyCount: haltedRangeKeyCount,
            pendingBackgroundCompletionOperationCount: pendingBackgroundCompletionOperationCount,
            deferredBackgroundCompletionIdentifierCount: deferredBackgroundCompletionIdentifierCount,
            backgroundCompletionHandlerCount: backgroundCompletionHandlerCount,
            finalizingRatingKeyCount: finalizingRatingKeyCount,
            pendingTempCleanupBytes: pendingCFNetworkTempBytes())
    }

    private lazy var urlSession: URLSession = makeURLSession()

    private func makeURLSession() -> URLSession {
        let config: URLSessionConfiguration
        if let injectedProtocolClasses {
            config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 3600
            config.protocolClasses = injectedProtocolClasses + (config.protocolClasses ?? [])
            downloadLog.info("using injected FOREGROUND URLSession for download transport tests")
        } else {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--vp-probe-background-download-session") {
            config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            downloadLog.info("using BACKGROUND URLSession (simulator probe override) for downloads")
        } else {
        // The background transfer daemon (`nsurlsessiond`) is unreliable in the visionOS
        // simulator: it intermittently refuses the XPC connection (NSCocoaError 4097), so
        // `downloadTask` creation fails and the task dies immediately with
        // NSURLErrorUnknown (-1) / 0 bytes received. A foreground (in-process) session
        // needs no daemon, so downloads work while developing in the sim. Real devices
        // always have the daemon, so they keep the background session below (which
        // survives app suspension/relaunch — the resume-after-kill path from D5/D8).
            config = URLSessionConfiguration.default
            // The segment train can enqueue multiple tasks (currently 2) per row, so the
            // starved tail tasks receive no data while queued. The foreground default config's 60s
            // request timeout then kills them with -1001 every minute (observed live: retry churn
            // resetting in-flight bodies). The device background session has no such idle timeout
            // (nsurlsessiond paces tasks); give the sim session headroom to match. NOTE: this
            // config value alone is NOT enough — URLRequest's own 60s default overrides it, so
            // `requestApplyingTaskPolicies` also stamps `timeoutInterval` on each request.
            config.timeoutIntervalForRequest = 3600
            downloadLog.info("using FOREGROUND URLSession (simulator) for downloads")
            #if DEBUG
            // #169: the byte-range lane now runs on THIS session, so the fault-injection harness
            // attaches here (a URLProtocol can only live on a foreground/default config — never on
            // the device background session). Sim-only dev tooling.
            if let fault = Self.debugDownloadFaultArgument() {
                DebugDownloadFaultURLProtocol.configure(fault)
                config.protocolClasses = [DebugDownloadFaultURLProtocol.self] + (config.protocolClasses ?? [])
                downloadLog.info("using DEBUG download fault URLProtocol scenario=\(fault.label, privacy: .public)")
            }
            #endif
        }
        #else
        config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        // The OS may relaunch us in the background to finish transfers; required so
        // `handleEventsForBackgroundURLSession` is delivered to the app delegate.
        config.sessionSendsLaunchEvents = true
        #endif
        }
        // Keep the background session itself permissive and stamp the cellular policy onto
        // each freshly-created URLRequest. That lets new tasks observe the Settings toggle
        // (defaulting off/Wi-Fi-only) without invalidating/recreating a background session
        // with the same identifier; resume-data tasks keep the OS-archived policy.
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Per-request stamps EVERY `downloadTask(with:)` creation site needs (opaque and range lanes
    /// alike): the cellular toggle, and — simulator only — the 3600s timeout headroom. The sim's
    /// foreground session starves queued tasks behind the per-host connection limit, and
    /// URLRequest's own 60s default overrides the session-level `timeoutIntervalForRequest`
    /// (observed live: -1001 churn survived the config fix), so the headroom must be stamped on
    /// each request itself. The opaque lane missing this stamp let a >60s encoder stall kill
    /// forward-only downloads terminally before the 90s stall watchdog could act.
    /// (`downloadTask(withResumeData:)` sites inherit the archived original request's stamps.)
    private func requestApplyingTaskPolicies(_ request: URLRequest) -> URLRequest {
        var policyRequest = request
        policyRequest.allowsCellularAccess = PlaybackPreferences.allowsCellularDownloads()
        #if targetEnvironment(simulator)
        policyRequest.timeoutInterval = 3600
        #endif
        return policyRequest
    }

    #if DEBUG
    private static func debugDownloadFaultArgument() -> DebugDownloadFaultURLProtocol.Fault? {
        let args = ProcessInfo.processInfo.arguments
        let configuredDropBytes: Int = {
            guard let idx = args.firstIndex(of: "--vp-probe-range-drop-after-bytes"),
                  args.indices.contains(idx + 1),
                  let bytes = Int(args[idx + 1]), bytes > 0 else { return 2 * 1_024 * 1_024 }
            return bytes
        }()
        if let idx = args.firstIndex(of: "--vp-probe-download-fault"),
           args.indices.contains(idx + 1) {
            switch args[idx + 1] {
            case "validator-flip": return .validatorFlip
            case "401-mid-train": return .unauthorizedMidTrain
            case "held-body-pause": return .heldBodyPause
            case "held-body-delete": return .heldBodyDelete
            case "write-failure": return .writeFailure
            case "416-restart": return .range416Restart
            case "200-replace": return .range200Replace
            case "held-body-relaunch": return .heldBodyRelaunch
            case "drain-pause": return .drainPause
            case "drain-delete": return .drainDelete
            case "double-connection-drop":
                return .repeatedConnectionDrop(afterBytes: configuredDropBytes, count: 2)
            default: break
            }
        }
        if let idx = args.firstIndex(of: "--vp-probe-range-drop-after-bytes"),
           args.indices.contains(idx + 1),
           let bytes = Int(args[idx + 1]), bytes > 0 {
            return .connectionDrop(afterBytes: bytes)
        }
        return nil
    }
    #endif

    init(
        store: DownloadStore,
        protocolClasses: [AnyClass]? = nil,
        playbackValidator: (@Sendable (URL, Double?) async -> PlaybackValidation)? = nil,
        releaseBackgroundCompletion: @escaping @MainActor @Sendable (
            BackgroundDownloadCompletionReleaseBatch
        ) -> Void = {
            BackgroundDownloadCompletionRegistry.shared.fireCompletions(in: $0)
        }
    ) {
        self.store = store
        self.injectedProtocolClasses = protocolClasses
        self.injectedPlaybackValidator = playbackValidator
        self.releaseBackgroundCompletion = releaseBackgroundCompletion
        super.init()
    }

    /// Break the foreground URLSession/delegate retain cycle used by deterministic transport
    /// tests. Production background-session lifetime remains OS-owned and is never invalidated.
    func invalidateInjectedSessionForTesting() {
        guard injectedProtocolClasses != nil else { return }
        urlSession.invalidateAndCancel()
    }

    #if DEBUG
    func finishBackgroundEventsForTesting(identifier: String) {
        fireBackgroundCompletionWhenFinalizationIsSafe(identifier: identifier)
    }

    func backgroundDeferredRevalidationKeysForTesting() -> Set<DownloadAttemptKey> {
        lock.lock()
        defer { lock.unlock() }
        return backgroundDeferredRevalidationKeys
    }

    /// D6 regression seam: the consecutive-truncation budget is only mutated inside
    /// `finalizeTransferredFile` (an AVPlayer-validated finalize that is impractical to drive from a
    /// unit test), so expose read/seed access — guarded by the same `finalizationStateQueue` — to
    /// prove `halt()` clears the count when the row is cancelled/deleted.
    func truncationFailureCountForTesting(ratingKey: String) -> Int {
        finalizationStateQueue.sync { truncationFailureCounts[ratingKey] ?? 0 }
    }

    func seedTruncationFailureCountForTesting(_ count: Int, ratingKey: String) {
        finalizationStateQueue.sync { truncationFailureCounts[ratingKey] = count }
    }

    /// #212 regression seam: run the production off-head finished-body flow — the caller's
    /// background-completion gate operation wrapping `applyFinishedRangeBody` on `rangeIOQueue`,
    /// exactly as `finishRangeRemainder`'s `.append` dispatch does — for a synthesized held
    /// segment (durable bytes < `baseOffset`, closed `segmentLength`). Tests use it to prove the
    /// gate cannot hit zero between this call returning and the held-lifecycle completion
    /// re-establishing the train slot / rebuild-grace hold.
    func applyFinishedHeldRangeBodyForTesting(
        attemptKey: DownloadAttemptKey,
        workingURL: URL,
        expectedBytes: Int?,
        baseOffset: Int,
        segmentLength: Int,
        stash: URL,
        contentRangeStart: Int?,
        onApplied: (@Sendable () -> Void)? = nil
    ) {
        let entry = RangeTransfer(
            ratingKey: attemptKey.ratingKey, attemptID: attemptKey.attemptID, request: nil,
            destination: workingURL, expectedBytes: expectedBytes, baseOffset: baseOffset,
            segmentLength: segmentLength, responseStatus: 206, bodyBytesWritten: 0,
            remainderReason: nil)
        beginPendingBackgroundCompletionOperation()
        rangeIOQueue.async { [self] in
            applyFinishedRangeBody(entry: entry, write: .append, stash: stash,
                                   validator: nil, contentRangeStart: contentRangeStart,
                                   contentRangeTotal: nil,
                                   responseContentLength: segmentLength,
                                   bodyTrainEpoch: 0)
            endPendingBackgroundCompletionOperation()
            onApplied?()
        }
    }
    #endif

    /// Open a current schema-4 store only after every unowned or obsolete daemon task has drained.
    /// Healthy current exact-attempt callbacks may continue during this purge window.
    func activateCurrentStore(
        completion: @escaping @Sendable (StartupActivationResult) -> Void
    ) {
        lock.lock()
        switch startupAdmissionState {
        case .active:
            lock.unlock(); completion(.alreadyActive); return
        case .purging:
            lock.unlock(); completion(.alreadyPurging); return
        case .dormant:
            startupAdmissionState = .purging
            lock.unlock()
        }
        purgeInvalidCurrentTasks(
            in: urlSession, cancelledTaskIdentifiers: [], pass: 0, completion: completion)
    }

    private func purgeInvalidCurrentTasks(
        in session: URLSession,
        cancelledTaskIdentifiers: Set<Int>,
        pass: Int,
        completion: @escaping @Sendable (StartupActivationResult) -> Void
    ) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { completion(.failed(reason: "session_deallocated")); return }
            let knownKeys = self.store.allRatingKeys
            let purgeTasks = tasks.filter { task in
                let mappedKey = Self.ratingKey(for: task, knownKeys: knownKeys)
                let attemptID = BackgroundDownloadTaskIdentity.attemptIdentity(
                    taskDescription: task.taskDescription)
                let key = mappedKey.flatMap { ratingKey in attemptID.map {
                    DownloadAttemptKey(ratingKey: ratingKey, attemptID: $0)
                } }
                return !BackgroundDownloadTaskIdentity.markerVersion(
                    taskDescription: task.taskDescription).isCurrent
                    || key.map(self.store.ownsAttempt) != true
            }
            if !purgeTasks.isEmpty {
                let ids = Set(purgeTasks.map(\.taskIdentifier))
                self.lock.withLock {
                    self.permanentlyRejectedTaskIdentifiers.formUnion(ids)
                }
                purgeTasks.forEach { $0.cancel() }
                guard pass < 100 else {
                    self.failStartupAdmission(
                        reason: "invalid_current_task_drain_timeout", completion: completion)
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
                    self.purgeInvalidCurrentTasks(
                        in: session,
                        cancelledTaskIdentifiers: cancelledTaskIdentifiers.union(ids),
                        pass: pass + 1,
                        completion: completion)
                }
                return
            }
            let opened = self.lock.withLock { () -> Bool in
                guard self.startupAdmissionState == .purging else { return false }
                self.startupAdmissionState = .active
                return true
            }
            guard opened else {
                completion(.failed(reason: "admission_state_changed")); return
            }
            completion(.activated(
                cancelledTaskCount: cancelledTaskIdentifiers.count))
        }
    }

    /// Destructive startup for an explicitly unsupported index schema. No legacy row/task is
    /// adopted or decoded. Cancel every OS task, prove two consecutive empty enumerations, replace
    /// the opaque root durably, and only then open current recovery.
    func activateAfterResettingUnsupportedStore(
        completion: @escaping @Sendable (StartupActivationResult) -> Void
    ) {
        lock.lock()
        switch startupAdmissionState {
        case .active:
            lock.unlock(); completion(.alreadyActive); return
        case .purging:
            lock.unlock(); completion(.alreadyPurging); return
        case .dormant:
            startupAdmissionState = .purging
            startupRejectsAllCallbacks = true
            lock.unlock()
        }
        drainAllTasksForUnsupportedReset(
            in: urlSession, cancelledTaskIdentifiers: [], emptyPasses: 0, pass: 0,
            completion: completion)
    }

    private func drainAllTasksForUnsupportedReset(
        in session: URLSession,
        cancelledTaskIdentifiers: Set<Int>,
        emptyPasses: Int,
        pass: Int,
        completion: @escaping @Sendable (StartupActivationResult) -> Void
    ) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { completion(.failed(reason: "session_deallocated")); return }
            guard pass < 100 else {
                self.failStartupAdmission(
                    reason: "unsupported_schema_task_drain_timeout", completion: completion)
                return
            }
            if !tasks.isEmpty {
                let ids = Set(tasks.map(\.taskIdentifier))
                self.lock.withLock {
                    self.permanentlyRejectedTaskIdentifiers.formUnion(ids)
                }
                tasks.forEach { $0.cancel() }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
                    self.drainAllTasksForUnsupportedReset(
                        in: session,
                        cancelledTaskIdentifiers: cancelledTaskIdentifiers.union(ids),
                        emptyPasses: 0,
                        pass: pass + 1,
                        completion: completion)
                }
                return
            }
            // One empty snapshot can race daemon bookkeeping. Require a stable empty observation.
            guard emptyPasses >= 1 else {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
                    self.drainAllTasksForUnsupportedReset(
                        in: session,
                        cancelledTaskIdentifiers: cancelledTaskIdentifiers,
                        emptyPasses: emptyPasses + 1,
                        pass: pass + 1,
                        completion: completion)
                }
                return
            }
            switch self.store.replaceUnsupportedRootWithCurrentEmptyStore() {
            case .reset, .notRequired:
                let opened = self.lock.withLock { () -> Bool in
                    guard self.startupAdmissionState == .purging else { return false }
                    self.startupRejectsAllCallbacks = false
                    self.startupAdmissionState = .active
                    return true
                }
                guard opened else {
                    completion(.failed(reason: "admission_state_changed")); return
                }
                completion(.activated(
                    cancelledTaskCount: cancelledTaskIdentifiers.count))
            case .failed(let stage, let errorType):
                self.failStartupAdmission(
                    reason: "unsupported_schema_reset_\(stage)_\(errorType)",
                    completion: completion)
            }
        }
    }

    private func failStartupAdmission(
        reason: String,
        completion: @escaping @Sendable (StartupActivationResult) -> Void
    ) {
        lock.lock()
        startupAdmissionState = .dormant
        startupRejectsAllCallbacks = false
        lock.unlock()
        AppDiagnostics.record(.downloads, "downloads.startup_admission_failed", fields: [
            "reason": .label(reason),
        ])
        completion(.failed(reason: reason))
    }

    private func admitsTaskCallback(_ task: URLSessionTask) -> Bool {
        lock.lock()
        let state = startupAdmissionState
        let rejected = permanentlyRejectedTaskIdentifiers.contains(task.taskIdentifier)
        let rejectsAll = startupRejectsAllCallbacks
        lock.unlock()
        guard !rejectsAll else { return false }
        let key = BackgroundDownloadTaskIdentity.attemptIdentity(
            taskDescription: task.taskDescription).flatMap { attemptID in
                Self.ratingKey(for: task, knownKeys: store.allRatingKeys).map {
                    DownloadAttemptKey(ratingKey: $0, attemptID: attemptID)
                }
            }
        return Self.shouldAdmitStartupCallback(
            isActive: state == .active,
            isPurging: state == .purging,
            isPermanentlyRejected: rejected,
            hasCurrentMarker: BackgroundDownloadTaskIdentity.markerVersion(
                taskDescription: task.taskDescription).isCurrent,
            taskKey: key,
            ownsAttempt: key.map(store.ownsAttempt) ?? false
        )
    }

    nonisolated static func shouldAdmitStartupCallback(
        isActive: Bool,
        isPurging: Bool,
        isPermanentlyRejected: Bool,
        hasCurrentMarker: Bool,
        taskKey: DownloadAttemptKey?,
        ownsAttempt: Bool
    ) -> Bool {
        guard !isPermanentlyRejected else { return false }
        guard isActive || isPurging else { return false }
        return hasCurrentMarker && taskKey != nil && ownsAttempt
    }

    private func rejectTaskCallback(_ task: URLSessionTask, temporaryBody: URL? = nil) -> Bool {
        guard !admitsTaskCallback(task) else { return false }
        lock.lock()
        permanentlyRejectedTaskIdentifiers.insert(task.taskIdentifier)
        inflight.removeValue(forKey: task.taskIdentifier)
        rangeInflight.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let temporaryBody { try? fileManager.removeItem(at: temporaryBody) }
        task.cancel()
        return true
    }

    private var isStartupAdmissionActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return startupAdmissionState == .active
    }

    /// Task creation never mints authority. The manager/store must have already committed the
    /// top-level schema-v3 owner before the session is allowed to create external work.
    private func currentAttemptIdentity(ratingKey: String) -> DownloadAttemptID? {
        store.downloadAttemptIdentity(ratingKey: ratingKey)
    }

    private func stillOwnsAttempt(_ key: DownloadAttemptKey, phase: String) -> Bool {
        guard store.ownsAttempt(key), !store.isDeletionPending(for: key) else {
            let diagnosticKey = "\(key.attemptID.rawValue)|\(phase)"
            lock.lock()
            let shouldLog = loggedStaleAttemptCallbackPhases.insert(diagnosticKey).inserted
            lock.unlock()
            if shouldLog {
                AppDiagnostics.record(.downloads, "downloads.stale_attempt_callback_dropped", fields: [
                    "download_id": .identifier(key.ratingKey),
                    "phase": .label(phase),
                ])
            }
            return false
        }
        return true
    }

    private func supportsPersistedResumeData(for key: DownloadAttemptKey) -> Bool {
        guard let record = store.record(for: key) else { return false }
        let backend = record.metadata?.resolvedBackendKind(ratingKey: key.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: key.ratingKey)
        let mode = record.metadata?.resolvedResumeMode(ratingKey: key.ratingKey)
            ?? DownloadResumeMode.resolved(backend: backend, lane: .original)
        return mode != .liveForwardOnly
    }

    private func acceptedAttemptMutation(
        _ result: DownloadStore.AttemptMutationResult,
        key: DownloadAttemptKey,
        phase: String
    ) -> Bool {
        switch result {
        case .applied, .noChange:
            return true
        case .staleOrMissing:
            AppDiagnostics.record(.downloads, "downloads.stale_attempt_mutation_dropped", fields: [
                "download_id": .identifier(key.ratingKey),
                "phase": .label(phase),
            ])
            return false
        case .persistenceFailed(let persistence):
            AppDiagnostics.record(.downloads, "downloads.attempt_mutation_persistence_failed", fields: [
                "download_id": .identifier(key.ratingKey),
                "phase": .label(phase),
                "persistence": .label(String(describing: persistence)),
            ])
            return false
        }
    }

    /// Admission-only twin used on URLSession/range-I/O lifecycle paths. Persistence is observed
    /// once, with a bound, when the completion gate drains. Treating acceptance as success keeps
    /// exact-attempt control flow intact without letting a wedged writer block delegate delivery.
    private func acceptedAttemptSubmission(
        _ result: DownloadStore.AttemptMutationSubmission,
        key: DownloadAttemptKey,
        phase: String
    ) -> Bool {
        // Preserve the existing foreground contract: dependent task/file work starts only after
        // the submitted snapshot commits. A stored OS handler switches this exact call to
        // admission-only; the completion gate then owns the bounded outcome.
        if !hasPendingBackgroundCompletionHandler() {
            return acceptedAttemptMutation(
                store.resolveSynchronously(result), key: key, phase: phase)
        }
        switch result {
        case .accepted:
            return true
        case .staleOrMissing:
            AppDiagnostics.record(.downloads, "downloads.stale_attempt_mutation_dropped", fields: [
                "download_id": .identifier(key.ratingKey),
                "phase": .label(phase),
            ])
            return false
        }
    }

    /// Every submission call goes through this context fence. Foreground callers retain the old
    /// commit-before-return contract; only a stored OS background completion handler may defer the
    /// outcome to the gate's bounded flush.
    @discardableResult
    private func resolveLifecycleSubmission(
        _ submission: DownloadStore.AttemptMutationSubmission
    ) -> DownloadStore.AttemptMutationSubmission {
        if !hasPendingBackgroundCompletionHandler() {
            _ = store.resolveSynchronously(submission)
        }
        return submission
    }

    @discardableResult
    private func resolveLifecycleSubmission(
        _ submission: DownloadStore.AttemptResumeDataSubmission
    ) -> DownloadStore.AttemptResumeDataSubmission {
        if !hasPendingBackgroundCompletionHandler() {
            _ = store.resolveSynchronously(submission)
        }
        return submission
    }

    @discardableResult
    private func resolveLifecycleSubmission(
        _ submission: DownloadStore.AttemptArtifactMutationSubmission
    ) -> DownloadStore.AttemptArtifactMutationSubmission {
        if !hasPendingBackgroundCompletionHandler() {
            switch submission {
            case .staleOrMissing:
                break
            case .accepted(_, let ticket):
                _ = store.resolveArtifactSynchronously(ticket)
            }
        }
        return submission
    }

    /// Held-body submissions must return to the URLSession/range queue before any index wait or
    /// delete. The Store worker owns filesystem progress; this detached waiter only delivers the
    /// terminal lifecycle result back onto the serialized range-processing queue.
    private func resolveHeldLifecycle(
        _ ticket: DownloadArtifactLifecycleCoordinator.Ticket,
        completion: @escaping @Sendable (DownloadArtifactLifecycleCoordinator.FlushResult) -> Void
    ) {
        let store = self.store
        let queue = rangeIOQueue
        DispatchQueue.global(qos: .utility).async {
            let outcome = store.resolveArtifactSynchronously(ticket)
            queue.async { completion(outcome) }
        }
    }

    private func fileSize(at url: URL) -> Int? {
        DownloadFileStat.logicalSize(at: url, attributesOfItem: fileManager.attributesOfItem(atPath:))
    }

    private func availableStorageBytes() -> Int64? {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: store.directory.path),
              let number = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return number.int64Value
    }

    /// Sync accessor for async contexts (`finalizeTransferredFile`): NSLock is unavailable in
    /// async functions, and a pending handler means the app is background-launched right now.
    private func hasPendingBackgroundCompletionHandler() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return backgroundCompletionGate.hasPendingHandler
    }

    /// Atomically observes the global wake gate and, for a revalidation request, registers the
    /// exact retry before that gate can drain. This closes the check-then-register lost-wakeup race.
    private func deferPlaybackProbeIfBackgroundWakePending(
        revalidationKey: DownloadAttemptKey?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard backgroundCompletionGate.hasPendingHandler else { return false }
        if let revalidationKey { backgroundDeferredRevalidationKeys.insert(revalidationKey) }
        return true
    }

    private func beginPendingBackgroundCompletionOperation() {
        lock.lock()
        backgroundCompletionGate.beginOperation()
        lock.unlock()
    }

    private func endPendingBackgroundCompletionOperation() {
        lock.lock()
        let wasPending = backgroundCompletionGate.hasPendingHandler
        let batches = backgroundCompletionGate.endOperation()
        let didDrain = wasPending && !backgroundCompletionGate.hasPendingHandler
        let deferredKeys = didDrain ? backgroundDeferredRevalidationKeys : []
        if didDrain { backgroundDeferredRevalidationKeys.removeAll() }
        lock.unlock()
        if !deferredKeys.isEmpty { onBackgroundCompletionGateDrained?(deferredKeys) }
        flushPersistenceThenFireBackgroundCompletions(batches)
    }

    func noteBackgroundCompletionHandlerStored(
        identifier: String,
        token: BackgroundDownloadCompletionHandlerToken = .init()
    ) {
        lock.lock()
        backgroundCompletionGate.storeHandler(identifier: identifier, token: token)
        lock.unlock()
    }

    /// Startup persistence failed/timed out before URLSession could be safely activated, so its
    /// finish-events callback cannot be awaited. The failure has already been observed by the
    /// manager; release the OS wake explicitly and leave admission dormant.
    func releaseBackgroundCompletionAfterStartupFailure() {
        lock.lock()
        let wasPending = backgroundCompletionGate.hasPendingHandler
        let batches = backgroundCompletionGate.abortAwaitingHandlers()
        let didDrain = wasPending && !backgroundCompletionGate.hasPendingHandler
        let deferredKeys = didDrain ? backgroundDeferredRevalidationKeys : []
        if didDrain { backgroundDeferredRevalidationKeys.removeAll() }
        lock.unlock()
        if !deferredKeys.isEmpty { onBackgroundCompletionGateDrained?(deferredKeys) }
        guard !batches.isEmpty else { return }
        let releaseBackgroundCompletion = self.releaseBackgroundCompletion
        Task { @MainActor in
            for batch in batches {
                releaseBackgroundCompletion(batch)
            }
        }
    }

    private func fireBackgroundCompletionWhenFinalizationIsSafe(identifier: String) {
        lock.lock()
        let wasPending = backgroundCompletionGate.hasPendingHandler
        let batches = backgroundCompletionGate.finishEvents(identifier: identifier)
        let didDrain = wasPending && !backgroundCompletionGate.hasPendingHandler
        let deferredKeys = didDrain ? backgroundDeferredRevalidationKeys : []
        if didDrain { backgroundDeferredRevalidationKeys.removeAll() }
        lock.unlock()
        if !deferredKeys.isEmpty { onBackgroundCompletionGateDrained?(deferredKeys) }
        flushPersistenceThenFireBackgroundCompletions(batches)
    }

    private func flushPersistenceThenFireBackgroundCompletions(
        _ batches: [BackgroundDownloadCompletionReleaseBatch]
    ) {
        guard !batches.isEmpty else { return }
        let ticket = store.currentPersistenceTicket()
        let artifactWatermark = store.currentArtifactLifecycleWatermark()
        let store = self.store
        let releaseBackgroundCompletion = self.releaseBackgroundCompletion
        Task {
            await BackgroundCompletionPersistenceBarrier.flushThenRelease(
                releases: batches,
                flush: {
                    await store.flushLifecycleAndPersistence(
                        through: ticket,
                        artifactWatermark: artifactWatermark,
                        timeout: Self.backgroundCompletionPersistenceTimeout
                    )
                },
                observe: { result in
                    let outcome: String
                    let revision: UInt64
                    switch result {
                    case .committed(let committedRevision):
                        outcome = "committed"
                        revision = committedRevision
                    case .failed(let failedRevision, _, _):
                        outcome = "failed"
                        revision = failedRevision
                    case .timedOut(let targetRevision, _):
                        outcome = "timed_out"
                        revision = targetRevision
                    }
                    AppDiagnostics.record(.downloads, "downloads.background_completion_persistence", fields: [
                        "outcome": .label(outcome),
                        "revision": .int(Int(clamping: revision)),
                        "handler_count": .int(batches.reduce(into: 0) {
                            $0 += $1.tokens.count
                        }),
                    ])
                },
                release: { batch in
                    releaseBackgroundCompletion(batch)
                }
            )
        }
    }

    /// #212: hold the app-delegate background completion handler while DownloadManager rebuilds an
    /// authenticated request for a `.requestNeeded` row. Ended when a replacement range task
    /// registers for the key, or by timeout when the rebuild fails/defers.
    private func beginRangeRequestRebuildGrace(for key: DownloadAttemptKey) {
        let ratingKey = key.ratingKey
        let generation = UUID()
        lock.lock()
        let alreadyHeld = rangeRequestRebuildGraceGenerations[key] != nil
        // Re-arming while held advances the generation (extending the grace): the prior cycle's
        // timer becomes a no-op instead of ending this cycle's grace early. The completion-gate
        // operation stays balanced at one per held key.
        rangeRequestRebuildGraceGenerations[key] = generation
        lock.unlock()
        if !alreadyHeld {
            beginPendingBackgroundCompletionOperation()
            AppDiagnostics.record(.downloads, "downloads.range_request_rebuild_grace_start", fields: [
                "download_id": .identifier(ratingKey),
                "grace_seconds": .int(Int(Self.rangeRequestRebuildGraceSeconds)),
            ])
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.rangeRequestRebuildGraceSeconds
        ) { [weak self] in
            self?.endRangeRequestRebuildGrace(for: key, reason: "timeout", generation: generation)
        }
    }

    /// `generation` is non-nil only for the timeout closure, which may end ONLY the grace cycle it
    /// armed. Every other end site clears unconditionally.
    private func endRangeRequestRebuildGrace(for key: DownloadAttemptKey, reason: String,
                                             generation: UUID? = nil) {
        let ratingKey = key.ratingKey
        lock.lock()
        if let generation, rangeRequestRebuildGraceGenerations[key] != generation {
            lock.unlock()
            return
        }
        let wasHeld = rangeRequestRebuildGraceGenerations.removeValue(forKey: key) != nil
        lock.unlock()
        guard wasHeld else { return }
        AppDiagnostics.record(.downloads, "downloads.range_request_rebuild_grace_end", fields: [
            "download_id": .identifier(ratingKey),
            "reason": .label(reason),
        ])
        endPendingBackgroundCompletionOperation()
        if reason == "timeout",
           !isTrackingTransfer(ratingKey: ratingKey),
           let record = store.record(for: key),
           record.status == .queued {
            // A queued static row without a URLSession owner is not active work. Park it at the
            // durable checkpoint instead of leaving a spinner that only Pause -> Resume can kick.
            let reset = store.resetStaticRangeProgressToDurableCheckpoint(
                for: key,
                expectedBytes: record.metadata?.sourcePartSize)
            let checkpointBytes: Int
            switch reset {
            case .applied(let bytes), .unchanged(let bytes), .notStatic(let bytes):
                checkpointBytes = bytes
            case .staleOrMissing, .persistenceFailed:
                return
            }
            _ = resolveLifecycleSubmission(store.submitStatus(for: key, .paused))
            AppDiagnostics.record(.downloads, "downloads.range_request_rebuild_parked", fields: [
                "download_id": .identifier(ratingKey),
                "checkpoint_bytes": .int(checkpointBytes),
                "reason": .label("no_replacement_task"),
            ])
            onError?(ratingKey, .interruptedResumable)
            onChange?()
        }
    }

    /// Rebind delegate to any tasks the background session resumed after relaunch.
    ///
    /// Touching `urlSession` lazily recreates the background session object bound to
    /// the persisted identifier; the OS then redelivers progress/completion callbacks
    /// for any tasks that survived suspension/relaunch, and our delegate methods
    /// restore each record's progress from `didWriteData`/`didFinishDownloadingTo`.
    /// We also re-seed `inflight` so a relaunched task maps back to its record's
    /// destination (the index.json still holds the ratingKey + relative path).
    /// - Parameter onReattached: called (off the main actor) with the set of
    ///   ratingKeys that mapped back to a still-running task. The manager uses it to
    ///   reconcile the rest of the store to `.failed` (D2) — anything NOT in this set
    ///   has no live task and so can't be distinguished from a stall.
    func reattach(onReattached: (@Sendable (Set<String>) -> Void)? = nil) {
        guard isStartupAdmissionActive else {
            onReattached?([])
            return
        }
        // D5: the pending-promotion recovery below can F_FULLFSYNC a potentially multi-GB working
        // file, rename it, sync the directory, and wait synchronously for persistence. Running that
        // on the URLSession delegate queue (where the getAllTasks completion lands) would block the
        // queue through the background-wake window — the commit that reworked activation dropped the
        // comment that warned against exactly this. The recovery only reads store rows (never the
        // task list), so run it on a utility queue BEFORE re-enumerating tasks. Ordering is
        // preserved: recovery still finishes terminal rows before classification sees them (so a
        // straggler task is cancelled, not re-adopted) and before onReattached drives reconcile.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { onReattached?([]); return }
            self.finalizePendingValidatedPromotions()
            self.reattachToResumedTasks(onReattached: onReattached)
        }
    }

    /// Finish any exact-attempt promotion whose validated intent committed before a hard kill.
    /// Split out of `reattach` and run OFF the URLSession delegate queue (see the D5 note there)
    /// because it can F_FULLFSYNC a multi-GB working file; it only reads store rows, so it is safe
    /// to run ahead of the task re-enumeration that depends on the restored terminal rows.
    private func finalizePendingValidatedPromotions() {
        for record in self.store.records {
            guard let attemptID = record.attemptID else { continue }
            let key = DownloadAttemptKey(ratingKey: record.ratingKey, attemptID: attemptID)
            guard !self.store.isDeletionPending(for: key) else { continue }
            if case .promoted(_, let bytes, let status) =
                self.store.recoverPendingValidatedPromotion(for: key) {
                AppDiagnostics.record(.downloads, "downloads.pending_promotion_recovered", fields: [
                    "download_id": .identifier(key.ratingKey),
                    "bytes": .bytes(bytes),
                    "status": .label(status.rawValue),
                ])
            }
        }
    }

    /// Rebind the delegate to tasks the OS resumed after relaunch. Kept on the delegate queue (the
    /// getAllTasks completion) so classification stays serialized with redelivered progress/finish
    /// callbacks; the FS-heavy promotion recovery already ran off-queue (see `reattach`).
    private func reattachToResumedTasks(onReattached: (@Sendable (Set<String>) -> Void)? = nil) {
        urlSession.getAllTasks { [weak self] tasks in
            guard let self else { onReattached?([]); return }
            // Rebuild the taskIdentifier -> (ratingKey, destination) map for any
            // tasks the OS resumed. We match a task to a record by its source URL's
            // `path` query param (the metadataKey), which is stable per item; if we
            // can't match we still leave the task running and rely on the store row.
            var liveKeys: Set<String> = []
            let stagingSweep = self.store.sweepUnreferencedAttemptStaging()
            if !stagingSweep.removedRelativePaths.isEmpty
                || !stagingSweep.failedRelativePaths.isEmpty {
                AppDiagnostics.record(.downloads, "downloads.attempt_staging_swept", fields: [
                    "removed_count": .int(stagingSweep.removedRelativePaths.count),
                    "failed_count": .int(stagingSweep.failedRelativePaths.count),
                ])
            }
            // Build the indexed-key set ONCE (FS-free) before the task loop, instead of
            // stat'ing every store row per task under the held lock (was O(tasks×rows)).
            let knownKeys = self.store.allRatingKeys
            let recordsByKey = Dictionary(self.store.records.map { ($0.ratingKey, $0) },
                                          uniquingKeysWith: { first, _ in first })
            self.restoreHeldRangeSegments(recordsByKey: recordsByKey)
            var rangeTaskIdentifiersToCancel: [Int] = []
            var adoptedRangeKeys: Set<String> = []
            var adoptedSegmentCounts: [String: Int] = [:]
            var rangeRequestRebuildReasons: [String: BackgroundRangeRequestReason] = [:]
            self.lock.lock()
            for task in tasks {
                guard self.inflight[task.taskIdentifier] == nil,
                      self.rangeInflight[task.taskIdentifier] == nil else { continue }
                guard let ratingKey = Self.ratingKey(for: task, knownKeys: knownKeys) else {
                    // A non-empty taskDescription is one WE stamped at creation; a stamp that no
                    // longer resolves to a row means the download was deleted — without this the
                    // orphan keeps transferring in nsurlsessiond forever.
                    if task.taskDescription?.isEmpty == false {
                        self.supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
                        rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                        AppDiagnostics.record(.downloads, "downloads.orphan_task_cancelled", fields: [
                            "task_id": .int(task.taskIdentifier),
                            "marked_segment": .bool(
                                StaticRangeSegmentMarker.parse(task.taskDescription) != nil),
                        ])
                    }
                    continue
                }
                let record = recordsByKey[ratingKey]
                if let record, let attemptID = record.attemptID,
                   self.store.isDeletionPending(for: DownloadAttemptKey(
                    ratingKey: ratingKey, attemptID: attemptID)) {
                    self.supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
                    rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                    continue
                }
                // A terminal row must not readopt straggler tasks: adoption below force-writes
                // `.downloading`, flipping a completed/failed/unverified row live again, and a later
                // finish could replace the published file. Cancel instead; the row stays terminal.
                if let record, record.status == .complete || record.status == .failed
                    || record.status == .unverified {
                    self.supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
                    rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                    AppDiagnostics.record(.downloads, "downloads.terminal_row_task_cancelled", fields: [
                        "download_id": .identifier(ratingKey),
                        "task_id": .int(task.taskIdentifier),
                        "status": .label(record.status.rawValue),
                    ])
                    continue
                }
                guard let record, let rowAttemptID = record.attemptID,
                      let workingLayout = self.store.attemptWorkingFileLayout(
                        for: DownloadAttemptKey(ratingKey: ratingKey, attemptID: rowAttemptID)) else {
                    self.supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
                    rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                    continue
                }
                let destination = workingLayout.workingURL
                if StaticRangeRecoveryPolicy.isStaticRangeRecord(record) {
                    // Only current exact-attempt segment or open-ended markers are adoptable.
                    // Unmarked, malformed, or mismatched tasks are cancelled and rebuilt from the
                    // durable checkpoint so no unknown body can append after relaunch.
                    let partialSize = self.fileSize(at: destination) ?? 0
                    let requestedOffset = RangeTransferHTTPPolicy.rangeRequestStart(from: task.originalRequest)
                        ?? RangeTransferHTTPPolicy.rangeRequestStart(from: task.currentRequest)
                    let reattachedRequest = task.originalRequest ?? task.currentRequest
                    let rangeHeader = reattachedRequest?.value(forHTTPHeaderField: "Range")
                    let rangeRequestShape = RangeTransferHTTPPolicy.rangeRequestShape(rangeHeader)
                    let reattachPlan = StaticRangeReattachPolicy.plan(
                        taskIdentifier: task.taskIdentifier,
                        downloadID: ratingKey,
                        durableBytes: partialSize,
                        requestedOffset: requestedOffset,
                        rangeRequestShape: rangeRequestShape,
                        bodyBytesWritten: Int(task.countOfBytesReceived),
                        existingTasks: self.rangeInflight.map {
                            self.rangeTaskSnapshot(taskIdentifier: $0.key, entry: $0.value)
                        },
                        taskMarker: task.taskDescription,
                        rowAttemptID: rowAttemptID
                    )
                    switch reattachPlan.disposition {
                    case .rejectAttemptMismatch:
                        // The task belongs to a PRIOR attempt/life of this key (re-enqueued at a
                        // different quality, or restarted after cancel/fail). Its bytes are for
                        // another rendition — cancel it and rebuild from the durable checkpoint.
                        self.supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
                        rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                        rangeRequestRebuildReasons[ratingKey] = .requestRebuildNeeded
                        liveKeys.insert(ratingKey)
                        AppDiagnostics.record(.downloads, "downloads.range_reattach_attempt_dropped", fields: [
                            "download_id": .identifier(ratingKey),
                            "task_id": .int(task.taskIdentifier),
                            "row_attempt_present": .bool(true),
                            "range_request_shape": .label(rangeRequestShape.rawValue),
                        ])
                        continue
                    case .rejectUnownedRange(let requestedOffset, let durableBytes, let rangeRequestShape):
                        self.supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
                        rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                        rangeRequestRebuildReasons[ratingKey] = .unownedRangeRejected
                        liveKeys.insert(ratingKey)
                        AppDiagnostics.record(.downloads, "downloads.range_unowned_range_rejected", fields: [
                            "download_id": .identifier(ratingKey),
                            "task_id": .int(task.taskIdentifier),
                            "requested_offset": .int(requestedOffset ?? -1),
                            "durable_bytes": .int(durableBytes),
                            "received_body_bytes": .int(max(0, Int(task.countOfBytesReceived))),
                            "range_request_shape": .label(rangeRequestShape.rawValue),
                            "range_header_present": .bool(rangeHeader != nil),
                        ])
                        continue
                    case .rejectOffsetMismatch(let requestedOffset, let durableBytes):
                        // The durable partial is the only checkpoint we trust. A reappearing
                        // open-ended task whose Range begins before/after that checkpoint is stale
                        // (or gapped) and must not become authoritative, publish backwards progress,
                        // or append later.
                        self.supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
                        rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                        rangeRequestRebuildReasons[ratingKey] = .requestRebuildNeeded
                        liveKeys.insert(ratingKey)
                        AppDiagnostics.record(.downloads, "downloads.range_reattach_offset_dropped", fields: [
                            "download_id": .identifier(ratingKey),
                            "task_id": .int(task.taskIdentifier),
                            "requested_offset": .int(requestedOffset),
                            "durable_bytes": .int(durableBytes),
                            "range_request_shape": .label(rangeRequestShape.rawValue),
                        ])
                        continue
                    case .replaceExisting, .suppressForExisting, .adopt:
                        break
                    }
                    // `plan` can admit only a current marker whose typed owner equals the
                    // row, so these dispositions imply a non-nil row owner. Keep that invariant
                    // explicit rather than force-unwrapping migration authority.
                    // C3: a reattached MARKED closed-range segment must recover its segmentLength, or
                    // the hold branch (keyed on `segmentLength != nil`) discards out-of-order finishes
                    // after every relaunch — re-downloading up to a full segment and burning the
                    // offset-mismatch retry budget. Open-ended remainders stay `nil` (unchanged).
                    let recoveredSegmentLength: Int? = {
                        guard rangeRequestShape == .closed,
                              StaticRangeSegmentMarker.parse(task.taskDescription) == reattachPlan.candidateBaseOffset
                        else { return nil }
                        // Prefer the exact end bound off the closed Range header.
                        let start = requestedOffset ?? reattachPlan.candidateBaseOffset
                        if let end = RangeTransferHTTPPolicy.rangeRequestEnd(rangeHeader), end >= start {
                            return end - start + 1
                        }
                        // Header lost (only the marker survived): derive from the segment grid with
                        // tail truncation against the expected total.
                        guard StaticRangeTransferRegime.current == .segmentTrain else { return nil }
                        let base = reattachPlan.candidateBaseOffset
                        let segBytes = StaticRangeTransferRegime.segmentBytes
                        if let expected = BackgroundDownloadProgressPolicy.derivedExpectedBytes(record),
                           expected > base {
                            return min(segBytes, expected - base)
                        }
                        return segBytes
                    }()
                    let reattached = RangeTransfer(
                        ratingKey: ratingKey,
                        attemptID: rowAttemptID,
                        request: nil,
                        destination: destination,
                        expectedBytes: BackgroundDownloadProgressPolicy.derivedExpectedBytes(record),
                        baseOffset: reattachPlan.candidateBaseOffset,
                        segmentLength: recoveredSegmentLength,
                        responseStatus: nil,
                        bodyBytesWritten: DownloadLiveRangeProgressPolicy.accountedTaskBodyBytes(
                            reportedBytes: Int(task.countOfBytesReceived),
                            segmentLength: recoveredSegmentLength),
                        remainderReason: "reattached")
                    switch reattachPlan.disposition {
                    case .rejectUnownedRange, .rejectOffsetMismatch, .rejectAttemptMismatch:
                        // Handled above.
                        continue
                    case .replaceExisting(let existingTaskIdentifier, let existingBaseOffset):
                        let isSegment = rangeRequestShape == .closed
                            && StaticRangeSegmentMarker.parse(task.taskDescription) == reattachPlan.candidateBaseOffset
                        let superseded = isSegment
                            ? self.supersedeRangeSegmentTasksLocked(
                                ratingKey: ratingKey,
                                offset: reattachPlan.candidateBaseOffset
                            )
                            : self.supersedeRangeTasksLocked(ratingKey: ratingKey)
                        self.rangeInflight[task.taskIdentifier] = reattached
                        self.supersededRangeTaskIdentifiers.remove(task.taskIdentifier)
                        rangeTaskIdentifiersToCancel.append(contentsOf: superseded)
                        adoptedSegmentCounts[ratingKey, default: 0] += 1
                        AppDiagnostics.record(.downloads, "downloads.range_duplicate_remainder_replaced", fields: [
                            "download_id": .identifier(ratingKey),
                            "task_id": .int(task.taskIdentifier),
                            "existing_task_id": .int(existingTaskIdentifier),
                            "superseded_task_count": .int(superseded.count),
                            "base_offset": .int(reattached.baseOffset),
                            "existing_base_offset": .int(existingBaseOffset),
                        ])
                    case .suppressForExisting(let existingTaskIdentifier, let existingBaseOffset):
                        let isSegment = rangeRequestShape == .closed
                            && StaticRangeSegmentMarker.parse(task.taskDescription) == reattachPlan.candidateBaseOffset
                        let superseded = isSegment
                            ? self.supersedeRangeSegmentTasksLocked(
                                ratingKey: ratingKey,
                                offset: reattachPlan.candidateBaseOffset,
                                keeping: existingTaskIdentifier
                            )
                            : self.supersedeRangeTasksLocked(
                                ratingKey: ratingKey,
                                keeping: existingTaskIdentifier
                            )
                        self.supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
                        rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                        rangeTaskIdentifiersToCancel.append(contentsOf: superseded)
                        AppDiagnostics.record(.downloads, "downloads.range_duplicate_remainder_suppressed", fields: [
                            "download_id": .identifier(ratingKey),
                            "task_id": .int(task.taskIdentifier),
                            "existing_task_id": .int(existingTaskIdentifier),
                            "superseded_task_count": .int(superseded.count + 1),
                            "base_offset": .int(reattached.baseOffset),
                            "existing_base_offset": .int(existingBaseOffset),
                        ])
                        liveKeys.insert(ratingKey)
                        continue
                    case .adopt:
                        self.rangeInflight[task.taskIdentifier] = reattached
                        adoptedSegmentCounts[ratingKey, default: 0] += 1
                    }
                    adoptedRangeKeys.insert(ratingKey)
                } else {
                    // Opaque lane: a stamped task from a PRIOR attempt (the row was re-enqueued,
                    // possibly at a different quality) must not be re-adopted — its finish takes
                    // the plain move path and would replace the new attempt's file wholesale.
                    // Unstamped or malformed tasks have no ownership and are cancelled.
                    let taskAttemptID = BackgroundDownloadTaskIdentity.attemptIdentity(
                        taskDescription: task.taskDescription)
                    guard let taskAttemptID, taskAttemptID == rowAttemptID else {
                        rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                        AppDiagnostics.record(.downloads, "downloads.opaque_reattach_attempt_dropped", fields: [
                            "download_id": .identifier(ratingKey),
                            "task_id": .int(task.taskIdentifier),
                            "row_attempt_present": .bool(true),
                        ])
                        continue
                    }
                    self.inflight[task.taskIdentifier] = OpaqueTransfer(
                        attemptKey: DownloadAttemptKey(ratingKey: ratingKey, attemptID: taskAttemptID),
                        destination: destination
                    )
                }
                liveKeys.insert(ratingKey)
            }
            // Also count tasks already tracked (e.g. started this launch) as live.
            for entry in self.inflight.values { liveKeys.insert(entry.ratingKey) }
            for entry in self.rangeInflight.values { liveKeys.insert(entry.ratingKey) }
            self.lock.unlock()
            for taskIdentifier in rangeTaskIdentifiersToCancel {
                self.removeRangeBodyStashes(taskIdentifier: taskIdentifier)
                self.cancelURLSessionTask(identifier: taskIdentifier)
            }
            for (ratingKey, reason) in rangeRequestRebuildReasons {
                guard let attemptID = recordsByKey[ratingKey]?.attemptID else { continue }
                let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
                let expectedBytes = recordsByKey[ratingKey].flatMap {
                    BackgroundDownloadProgressPolicy.derivedExpectedBytes($0)
                }
                _ = self.store.resetStaticRangeProgressToDurableCheckpoint(
                    for: attemptKey,
                    expectedBytes: expectedBytes
                )
                self.beginRangeRequestRebuildGrace(for: attemptKey)
                _ = self.resolveLifecycleSubmission(self.store.submitStatus(for: attemptKey, .queued))
                self.onRangeRequestNeeded?(ratingKey, reason)
            }
            for ratingKey in adoptedRangeKeys {
                guard let attemptID = recordsByKey[ratingKey]?.attemptID else { continue }
                _ = self.store.setStatus(
                    for: DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID),
                    .downloading)
            }
            for (ratingKey, count) in adoptedSegmentCounts {
                AppDiagnostics.record(.downloads, "downloads.range_segment_train_adopted", fields: [
                    "download_id": .identifier(ratingKey),
                    "adopted_segment_count": .int(count),
                ])
            }
            // Sweep range-body stashes orphaned by a hard kill between the synchronous stash-rename and
            // `applyFinishedRangeBody` running. Any stash not owned by a still-live task is dead — its
            // body was never appended, so the durable partial re-fetches it on resume. visionOS only
            // clears `tmp/` under pressure, so reclaim them here (cheap, alongside reattach).
            self.sweepOrphanedRangeBodyStashes(liveTaskIdentifiers: Set(tasks.map(\.taskIdentifier)))
            self.sweepOrphanedDurableHeldRangeSegments()
            self.sweepOrphanedNetworkTemps(liveTaskCount: tasks.count, context: .reattach)
            onReattached?(liveKeys)
            self.onChange?()
        }
    }

    /// Delete stashed Range response bodies in `tmp/` whose owning task is no longer live.
    private func sweepOrphanedRangeBodyStashes(liveTaskIdentifiers: Set<Int>) {
        lock.lock()
        let heldStashPaths = Set(heldRangeSegments.values.flatMap { $0.values.map { $0.url.lastPathComponent } })
        lock.unlock()
        let tmp = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        var sweptCount = 0
        var sweptBytes = 0
        for url in entries where !heldStashPaths.contains(url.lastPathComponent)
            && BackgroundTempFileCleanupPolicy.shouldDeleteRangeBodyStash(
            fileName: url.lastPathComponent,
            liveTaskIdentifiers: liveTaskIdentifiers
        ) {
            let bytes = fileSize(at: url) ?? 0
            do {
                try fileManager.removeItem(at: url)
                sweptCount += 1
                sweptBytes += bytes
            } catch {
                // Best-effort cleanup: a later reattach can retry files that remain.
            }
        }
        if sweptCount > 0 {
            AppDiagnostics.record(.downloads, "downloads.range_stash_swept", fields: [
                "swept_count": .int(sweptCount),
                "swept_bytes": .bytes(sweptBytes),
                "live_task_count": .int(liveTaskIdentifiers.count),
                "held_stash_count": .int(heldStashPaths.count),
            ])
        }
    }

    /// Rehydrate durable out-of-order bodies before reattached tasks or the launch reconciler plan
    /// any replacement ranges. Invalid manifests fail closed: the media checkpoint is authoritative,
    /// so a stale/missing/mismatched held body is simply deleted and fetched again.
    private func restoreHeldRangeSegments(recordsByKey: [String: DownloadRecord]) {
        var restoredCount = 0
        var restoredBytes = 0
        for (ratingKey, record) in recordsByKey {
            guard let attemptID = record.attemptID else { continue }
            let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
            guard !store.isDeletionPending(for: attemptKey) else { continue }
            guard let manifests = record.metadata?.heldRangeSegments, !manifests.isEmpty else { continue }
            let isActiveStatic = StaticRangeRecoveryPolicy.isStaticRangeRecord(record)
                && (record.status == .queued || record.status == .downloading || record.status == .paused)
            guard let workingURL = store.attemptWorkingFileURL(for: attemptKey) else { continue }
            let durableBytes = fileSize(at: workingURL) ?? 0
            let rowAttemptID = record.attemptID?.rawValue
            let storedValidator = record.metadata?.rangeValidator
            var seenOffsets = Set<Int>()
            // Collect invalid manifests per row and remove them with ONE index persist below; a
            // per-manifest store removal paid a full index.json rewrite each, on the launch
            // reattach path that gates download recovery.
            var invalidManifests: [(offset: Int, length: Int, url: URL?, actualLength: Int?)] = []
            for manifest in manifests {
                let url = store.heldRangeSegmentURL(relativePath: manifest.relativePath)
                let actualLength = url.flatMap(fileSize(at:))
                let valid = isActiveStatic
                    && manifest.offset >= durableBytes
                    && manifest.length > 0
                    && actualLength == manifest.length
                    && rowAttemptID != nil
                    && manifest.attemptID == rowAttemptID
                    && seenOffsets.insert(manifest.offset).inserted
                    && StaticRangeTrainIntegrityPolicy.heldSpliceDecision(
                        storedValidator: storedValidator,
                        heldValidator: manifest.validator
                    ) != .discardChangedResource
                guard valid, let url else {
                    invalidManifests.append((manifest.offset, manifest.length, url, actualLength))
                    continue
                }
                lock.lock()
                let alreadyRestored = heldRangeSegments[attemptKey]?[manifest.offset]?.url == url
                heldRangeSegments[attemptKey, default: [:]][manifest.offset] =
                    (url: url, length: manifest.length, validator: manifest.validator)
                lock.unlock()
                if !alreadyRestored {
                    restoredCount += 1
                    restoredBytes += manifest.length
                }
            }
            if !invalidManifests.isEmpty {
                guard case .accepted(let removal) = store.submitHeldRangeSegmentsRemoval(
                    for: attemptKey,
                    offsets: invalidManifests.map(\.offset),
                    deletingRelativePaths: invalidManifests.compactMap { $0.url?.lastPathComponent }
                ) else { continue }
                let invalidSnapshot = invalidManifests
                resolveHeldLifecycle(removal.ticket) { outcome in
                    for invalid in invalidSnapshot {
                        AppDiagnostics.record(.downloads, "downloads.range_held_manifest_discarded", fields: [
                            "download_id": .identifier(ratingKey),
                            "base_offset": .int(invalid.offset),
                            "manifest_length": .int(invalid.length),
                            "actual_length": .int(invalid.actualLength ?? -1),
                            "body_delete_deferred": .bool(outcome != .completed),
                        ])
                    }
                }
            }
        }
        if restoredCount > 0 {
            AppDiagnostics.record(.downloads, "downloads.range_held_segments_restored", fields: [
                "restored_count": .int(restoredCount),
                "restored_bytes": .bytes(restoredBytes),
            ])
        }
    }

    /// Crash window backstop: a durable body may have been renamed into Downloads just before its
    /// index manifest was committed. Only Labstream's private held-body filename class is swept.
    private func sweepOrphanedDurableHeldRangeSegments() {
        var referenced = store.referencedHeldRangeSegmentRelativePaths
        lock.lock()
        referenced.formUnion(heldRangeSegments.values.flatMap {
            $0.values.map { $0.url.lastPathComponent }
        })
        referenced.formUnion(heldRangeRetainedPredecessorURLs.values.flatMap {
            $0.values.flatMap { $0.map(\.lastPathComponent) }
        })
        lock.unlock()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: store.directory, includingPropertiesForKeys: nil) else { return }
        var sweptCount = 0
        var sweptBytes = 0
        for url in entries where url.lastPathComponent.contains(".range-held-")
            && !referenced.contains(url.lastPathComponent) {
            let bytes = fileSize(at: url) ?? 0
            do {
                try fileManager.removeItem(at: url)
                sweptCount += 1
                sweptBytes += bytes
            } catch {}
        }
        if sweptCount > 0 {
            AppDiagnostics.record(.downloads, "downloads.range_held_orphan_swept", fields: [
                "swept_count": .int(sweptCount),
                "swept_bytes": .bytes(sweptBytes),
            ])
        }
    }

    private func sweepOrphanedNetworkTemps(liveTaskCount: Int,
                                           context: BackgroundNetworkTempCleanupContext) {
        let candidates = cfNetworkTempDirectories()
            .flatMap { directory in cfNetworkTempFiles(in: directory).map { (directory, $0) } }
        let candidateBytes = candidates.reduce(0) { $0 + (fileSize(at: $1.1) ?? 0) }
        switch BackgroundTempFileCleanupPolicy.cleanupDisposition(
            context: context,
            liveTaskCount: liveTaskCount,
            candidateCount: candidates.count
        ) {
        case .none:
            return
        case .skipReattach:
            // #220: a finished-but-undelivered task's payload lives in one of these temps and
            // the task is absent from `getAllTasks` — deleting here is what lost completed bodies.
            AppDiagnostics.record(.downloads, "downloads.cfnetwork_temp_cleanup_skipped", fields: [
                "reason": .label(context.rawValue),
                "live_task_count": .int(liveTaskCount),
                "candidate_count": .int(candidates.count),
                "candidate_bytes": .int(candidateBytes),
            ])
            return
        case .skipLiveTasks:
            AppDiagnostics.record(.downloads, "downloads.cfnetwork_temp_cleanup_skipped", fields: [
                "reason": .label(context.rawValue),
                "live_task_count": .int(liveTaskCount),
                "candidate_count": .int(candidates.count),
                "candidate_bytes": .int(candidateBytes),
            ])
            return
        case .deleteCandidates:
            break
        }

        var deletedCount = 0
        var deletedBytes = 0
        var failedCount = 0
        var skippedYoungCount = 0
        for (_, url) in candidates {
            guard BackgroundTempFileCleanupPolicy.shouldDeleteCFNetworkTemp(
                modificationAge: modificationAge(at: url)
            ) else {
                skippedYoungCount += 1
                continue
            }
            let bytes = fileSize(at: url) ?? 0
            do {
                try fileManager.removeItem(at: url)
                deletedCount += 1
                deletedBytes += bytes
            } catch {
                failedCount += 1
            }
        }
        AppDiagnostics.record(.downloads, "downloads.cfnetwork_temp_cleanup", fields: [
            "reason": .label(context.rawValue),
            "candidate_count": .int(candidates.count),
            "deleted_count": .int(deletedCount),
            "failed_count": .int(failedCount),
            "skipped_young_count": .int(skippedYoungCount),
            "deleted_bytes": .int(deletedBytes),
        ])
    }

    private func modificationAge(at url: URL) -> TimeInterval? {
        guard let modified = try? fileManager.attributesOfItem(
            atPath: url.path)[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    private func pendingCFNetworkTempBytes() -> Int {
        cfNetworkTempDirectories()
            .flatMap(cfNetworkTempFiles(in:))
            .reduce(0) { $0 + (fileSize(at: $1) ?? 0) }
    }

    private func cfNetworkTempDirectories() -> [URL] {
        var directories = [fileManager.temporaryDirectory]
        if let appSupport = try? fileManager.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: false) {
            directories = BackgroundTempFileCleanupPolicy.networkTempDirectories(
                tempDirectory: fileManager.temporaryDirectory,
                appSupportDirectory: appSupport,
                bundleID: Self.appBundleIdentifier
            )
        }
        return directories
    }

    private func cfNetworkTempFiles(in directory: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            BackgroundTempFileCleanupPolicy.isCFNetworkDownloadTempFile(
                fileName: url.lastPathComponent,
                isRegularFile: (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            )
        }
    }

    /// Match a current background task to a row exclusively through its exact task description.
    /// Request URLs are mutable transport detail and never ownership authority.
    private static func ratingKey(for task: URLSessionTask, knownKeys: Set<String>) -> String? {
        BackgroundDownloadTaskIdentity.ratingKey(
            taskDescription: task.taskDescription,
            knownKeys: knownKeys
        )
    }

    /// Force the lazy background session to be created (and thus its delegate bound),
    /// so the OS can deliver `urlSessionDidFinishEvents` after a relaunch.
    func ensureSessionReady() {
        guard isStartupAdmissionActive else { return }
        _ = urlSession
    }

    /// Begin (or resume) a background download.
    ///
    /// `expectedBytes` is the known/estimated final file size, when the caller has
    /// one (the optimized part's reported size, or the quality×runtime estimate).
    /// `nil` falls back to the bare 500 MB floor.
    func start(ratingKey: String, from url: URL, to destination: URL,
               expectedBytes: Int? = nil, byteRangeCheckpoint: Bool = false,
               resetRangeRestartCounters: Bool = true) throws {
        try start(ratingKey: ratingKey,
                  with: URLRequest(url: url),
                  to: destination,
                  expectedBytes: expectedBytes,
                  byteRangeCheckpoint: byteRangeCheckpoint,
                  resetRangeRestartCounters: resetRangeRestartCounters)
    }

    /// Begin (or resume) a background download with an explicit request.
    ///
    /// Jellyfin downloads need auth headers; keep this overload so callers do not
    /// smuggle tokens into query strings just to satisfy `downloadTask(with: URL)`.
    func start(ratingKey: String, with request: URLRequest, to destination: URL,
               expectedBytes: Int? = nil, byteRangeCheckpoint: Bool = false,
               resetRangeRestartCounters: Bool = true) throws {
        guard isStartupAdmissionActive else { throw CancellationError() }
        guard let attemptID = currentAttemptIdentity(ratingKey: ratingKey) else {
            throw CancellationError()
        }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard store.ownsAttempt(attemptKey),
              let workingLayout = store.attemptWorkingFileLayout(for: attemptKey) else {
            throw CancellationError()
        }
        let workingDestination = workingLayout.workingURL
        let policyRequest = requestApplyingTaskPolicies(request)
        // Pre-flight storage check: refuse if free space can't plausibly hold the
        // file. Sized against the expected bytes (plus headroom for the OS and the
        // temp-then-move copy) when known, so a 5 GB download with 600 MB free fails
        // here rather than mid-transfer.
        let headroom: Int64 = 500_000_000
        let required = max(headroom, Int64(expectedBytes ?? 0) + headroom)
        if let free = try? fileManager
            .attributesOfFileSystem(forPath: store.directory.path)[.systemFreeSize] as? Int64,
           free < required {
            AppDiagnostics.record(.downloads, "downloads.transfer_start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label("storage_full"),
                "required_bytes": .bytes(Int(required)),
                "required_bytes_exact": .int(Int(required)),
                "free_bytes": .bytes(Int(free)),
                "free_bytes_exact": .int(Int(free)),
            ])
            throw DownloadManager.DownloadError.storageFull
        }
        if byteRangeCheckpoint {
            _ = resolveLifecycleSubmission(store.submitSourcePartSizeIfMissing(for: attemptKey, expectedBytes))
        }
        // A fresh user-initiated start/resume clears any prior cancel/pause halt for this row (a
        // internal range continuation calls `startRangeRemainder` directly and deliberately does not),
        // and resets the validator-change restart bound so a user-driven retry starts with a clean count.
        lock.lock()
        rangeHaltKinds.removeValue(forKey: attemptKey)
        if resetRangeRestartCounters {
            staticRangeRetryBudget.reset(key: staticRangeRetryKey(for: attemptKey))
            rangeHTTPRehydrateCounts.removeValue(forKey: attemptKey)
            // An exhausted blob-resume budget must not survive a user Retry: the fresh start
            // re-plans from the durable checkpoint, so the prior attempt's blob failures are
            // irrelevant and would only force the next transient drop to discard its temp.
            rangeBlobResumeCounts.removeValue(forKey: attemptKey)
        }
        lock.unlock()
        if byteRangeCheckpoint {
            try startRangeRemainder(ratingKey: ratingKey, with: policyRequest, to: workingDestination,
                                expectedBytes: expectedBytes,
                                resetsRetryCount: true,
                                attemptID: attemptID)
            return
        }
        let task = urlSession.downloadTask(with: policyRequest)
        task.taskDescription = DownloadAttemptMarker.taskDescription(
            ratingKey: ratingKey, attemptID: attemptID)
        lock.lock()
        retryCounts[attemptKey] = 0
        lastProgressNotify = nil
        loggedProgressMilestones[task.taskIdentifier] = []
        lastRangeProgressDiagnostic.removeValue(forKey: task.taskIdentifier)
        inflight[task.taskIdentifier] = OpaqueTransfer(
            attemptKey: DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID),
            destination: workingDestination
        )
        lock.unlock()
        let urlShape = DiagnosticRedactor.urlShape(policyRequest.url)
        downloadLog.info("start ratingKey=\(ratingKey, privacy: .public) url_shape=\(urlShape, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.transfer_start", fields: [
            "download_id": .identifier(ratingKey),
            "url_shape": .urlShape(policyRequest.url),
            "allows_cellular": .bool(policyRequest.allowsCellularAccess),
            "expected_bytes": .bytes(expectedBytes),
            "has_expected_bytes": .bool(expectedBytes != nil),
        ])
        task.resume()
    }

    /// Start one static byte-range background `downloadTask` (#169/#227).
    ///
    /// The destination IS the durable partial file. Its current size is the only app-owned
    /// checkpoint, used when URLSession resume data is unavailable or rejected. New starts always
    /// issue one open-ended `Range` request from that durable offset; retry/diagnostic reasons are
    /// metadata only and never alter the single-remainder lifecycle.
    @discardableResult
    private func startRangeRemainder(ratingKey: String, with request: URLRequest, to destination: URL,
                                 expectedBytes: Int?,
                                 resetsRetryCount: Bool,
                                 remainderReasonOverride: String? = nil,
                                 attemptID expectedAttemptID: DownloadAttemptID? = nil) throws -> Int {
        guard let attemptID = expectedAttemptID ?? currentAttemptIdentity(ratingKey: ratingKey) else {
            throw CancellationError()
        }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard store.ownsAttempt(attemptKey),
              let workingLayout = store.attemptWorkingFileLayout(for: attemptKey) else {
            throw CancellationError()
        }
        let destination = workingLayout.workingURL
        guard !isRangeHalted(for: attemptKey) else {
            AppDiagnostics.record(.downloads, "downloads.range_start_suppressed", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("preflight_halted"),
            ])
            throw CancellationError()
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        var offset = 0
        if fileManager.fileExists(atPath: destination.path) {
            offset = fileSize(at: destination) ?? 0
            if let expectedBytes, offset > expectedBytes {
                try? fileManager.removeItem(at: destination)
                fileManager.createFile(atPath: destination.path, contents: nil)
                offset = 0
                _ = resolveLifecycleSubmission(store.submitProgress(for: attemptKey, bytes: 0, progress: 0))
                // The truncate is a train teardown: a body mid-hop against the old (oversized)
                // file must be discarded, not appended at offset 0 of the recreated one — and
                // its held siblings belong to the discarded bytes.
                lock.lock()
                rangeTrainEpochs[attemptKey] = (rangeTrainEpochs[attemptKey] ?? 0) + 1
                lock.unlock()
                purgeHeldRangeSegments(for: attemptKey)
            }
        } else {
            fileManager.createFile(atPath: destination.path, contents: nil)
        }
        lock.lock()
        let hasHeldSegments = !(heldRangeSegments[attemptKey]?.isEmpty ?? true)
        lock.unlock()
        if hasHeldSegments {
            offset = drainHeldRangeSegments(for: attemptKey, destination: destination,
                                            expectedBytes: expectedBytes)
        }
        _ = resolveLifecycleSubmission(store.submitSourcePartSizeIfMissing(for: attemptKey, expectedBytes))
        // Lens 2 F5: an `expectedBytes == 0` source used to satisfy neither the finalize gate
        // below (`> 0`) nor the planner (`durable < expected` fails), stranding the row `.queued`
        // forever. Funnel it through the shared finalize instead: the empty-file outcome fails it
        // terminally with a real reason (and a non-empty durable partial against an expected 0 is
        // bogus metadata — the finalize byte checks own that verdict too).
        if let expectedBytes, offset >= expectedBytes, expectedBytes == 0 {
            AppDiagnostics.record(.downloads, "downloads.range_zero_expected_bytes", fields: [
                "download_id": .identifier(ratingKey),
                "durable_bytes": .int(offset),
            ])
        }
        if let expectedBytes, offset >= expectedBytes {
            finalizeRangeWhole(entry: RangeTransfer(
                ratingKey: ratingKey,
                attemptID: attemptID,
                request: request,
                destination: destination,
                expectedBytes: expectedBytes,
                baseOffset: offset,
                segmentLength: nil,
                responseStatus: nil,
                bodyBytesWritten: 0,
                remainderReason: remainderReasonOverride))
            return -1
        }

        // Continuation-path storage gate (mirrors `start()`'s preflight, which internal
        // continuations/retries bypass): never plan fetches the volume cannot hold — an
        // ENOSPC-failed row otherwise re-plans, purges and refetches held bodies, and loops.
        let storageHeadroom: Int64 = 500_000_000
        let remainingBytes = Int64(max(0, (expectedBytes ?? 0) - offset))
        let requiredFreeBytes = max(storageHeadroom, remainingBytes + storageHeadroom)
        if let free = try? fileManager
            .attributesOfFileSystem(forPath: store.directory.path)[.systemFreeSize] as? Int64,
           free < requiredFreeBytes {
            AppDiagnostics.record(.downloads, "downloads.range_start_failed", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label("storage_full"),
                "required_bytes": .bytes(Int(requiredFreeBytes)),
                "required_bytes_exact": .int(Int(requiredFreeBytes)),
                "free_bytes": .bytes(Int(free)),
                "free_bytes_exact": .int(Int(free)),
            ])
            throw DownloadManager.DownloadError.storageFull
        }

        // #169 HIGH 1: starting the file over (offset 0, fresh or truncated) invalidates any prior
        // resource validator; the first completed range body captures a new one. Subsequent remainder
        // requests (offset > 0) send `If-Range` so a cooperating server (Emby/Jellyfin, probed)
        // downgrades a changed resource to a whole-file 200 (`replaceWhole`). Plex IGNORES `If-Range`
        // (probed), so the load-bearing defense is the per-body validator-equality check in
        // `applyFinishedRangeBody`, which restarts from 0 on a mismatch; `If-Range` is the cheap
        // belt-and-suspenders that short-circuits the cooperating ones.
        let remainderReason = remainderReasonOverride ?? "single_remainder"
        lock.lock()
        // I3: only CLOSED segments (segmentLength != nil) are real train members. An adopted
        // open-ended remainder (segmentLength == nil) must NOT count as a live segment, or the
        // planner treats its range as covered and never fills it. Coverage is passed as
        // [offset, offset+length) INTERVALS: after a misaligned-checkpoint relaunch the adopted
        // segments sit on the prior grid, and offset-equality skipping would refetch every one.
        var liveSegments = rangeInflight.values
            .filter { $0.ratingKey == ratingKey && $0.segmentLength != nil }
            .map { StaticRangeSegmentPlan(offset: $0.baseOffset, length: $0.segmentLength) }
        for (heldOffset, held) in heldRangeSegments[attemptKey] ?? [:] {
            liveSegments.append(StaticRangeSegmentPlan(offset: heldOffset, length: held.length))
        }
        lock.unlock()

        let plans: [StaticRangeSegmentPlan]
        switch StaticRangeTransferRegime.current {
        case .segmentTrain:
            plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
                durableBytes: offset,
                expectedBytes: expectedBytes,
                liveSegments: liveSegments,
                segmentBytes: StaticRangeTransferRegime.segmentBytes,
                maxQueuedSegments: StaticRangeTransferRegime.maxQueuedSegments)
        case .openEndedRemainder:
            plans = [StaticRangeSegmentPlan(offset: offset, length: nil)]
        }
        // I3: when we are about to enqueue a CLOSED-range train, supersede any live open-ended task
        // for this key first — an adopted `bytes=N-` remainder would otherwise double-fetch the same
        // bytes the train covers. Its buffered bytes are non-durable and checkpoint-recoverable, so a
        // clean train replaces it. Scoped to closed trains so the open-ended regime is untouched and
        // the expectedBytes==nil open-ended fallback plan does not cancel itself.
        if plans.contains(where: { $0.length != nil }) {
            lock.lock()
            let openEndedIdentifiers = rangeInflight
                .filter { $0.value.ratingKey == ratingKey && $0.value.segmentLength == nil }
                .map(\.key)
            for identifier in openEndedIdentifiers {
                rangeInflight.removeValue(forKey: identifier)
                supersededRangeTaskIdentifiers.insert(identifier)
            }
            lock.unlock()
            for identifier in openEndedIdentifiers {
                cancelURLSessionTask(identifier: identifier)
                AppDiagnostics.record(.downloads, "downloads.range_open_ended_superseded_by_train", fields: [
                    "download_id": .identifier(ratingKey),
                    "task_id": .int(identifier),
                ])
            }
        }
        if plans.isEmpty {
            endRangeRequestRebuildGrace(for: attemptKey, reason: "request_rebuilt")
            return -1
        }
        if offset == 0 {
            _ = resolveLifecycleSubmission(store.submitRangeValidator(for: attemptKey, nil))
        }
        var firstTaskIdentifier: Int?
        for (index, plan) in plans.enumerated() {
            let taskIdentifier = try enqueueRangeSegment(
                ratingKey: ratingKey,
                attemptID: attemptID,
                baseRequest: request,
                destination: destination,
                expectedBytes: expectedBytes,
                plan: plan,
                resetsRetryCount: resetsRetryCount && index == 0,
                remainderReason: remainderReason)
            if firstTaskIdentifier == nil { firstTaskIdentifier = taskIdentifier }
        }
        if offset > 0, let expectedBytes, expectedBytes > 0 {
            _ = resolveLifecycleSubmission(store.submitProgress(for: attemptKey,
                                     bytes: offset,
                                     progress: min(1, Double(offset) / Double(expectedBytes))))
        }
        // #212: replacement tasks now exist — release any completion-handler hold that was
        // protecting the main-actor request rebuild for this row.
        endRangeRequestRebuildGrace(for: attemptKey, reason: "request_rebuilt")
        return firstTaskIdentifier ?? -1
    }

    @discardableResult
    private func enqueueRangeSegment(ratingKey: String, attemptID: DownloadAttemptID,
                                     baseRequest: URLRequest, destination: URL,
                                     expectedBytes: Int?, plan: StaticRangeSegmentPlan,
                                     resetsRetryCount: Bool, remainderReason: String) throws -> Int {
        let candidate = RangeTransfer(
            ratingKey: ratingKey,
            attemptID: attemptID,
            request: baseRequest,
            destination: destination,
            expectedBytes: expectedBytes,
            baseOffset: plan.offset,
            segmentLength: plan.length,
            responseStatus: nil,
            bodyBytesWritten: 0,
            remainderReason: remainderReason)
        lock.lock()
        if let duplicate = duplicateSegmentDecision(for: candidate), !duplicate.shouldReplaceExisting {
            let superseded = candidate.segmentLength != nil
                ? supersedeRangeSegmentTasksLocked(
                    ratingKey: ratingKey,
                    offset: candidate.baseOffset,
                    keeping: duplicate.existingTaskIdentifier
                )
                : supersedeRangeTasksLocked(
                    ratingKey: ratingKey,
                    keeping: duplicate.existingTaskIdentifier
                )
            lock.unlock()
            for identifier in superseded {
                cancelURLSessionTask(identifier: identifier)
            }
            _ = resolveLifecycleSubmission(store.submitStatus(for: candidate.attemptKey, .downloading))
            onChange?()
            AppDiagnostics.record(.downloads, "downloads.range_duplicate_start_suppressed", fields: [
                "download_id": .identifier(ratingKey),
                "existing_task_id": .int(duplicate.existingTaskIdentifier),
                "superseded_task_count": .int(superseded.count),
                "base_offset": .int(candidate.baseOffset),
                "existing_base_offset": .int(duplicate.existingEntry.baseOffset),
                "phase": .label("preflight"),
            ])
            return duplicate.existingTaskIdentifier
        }
        lock.unlock()

        let expectedBodyBytes = plan.length
            ?? rangeRemainderPolicy.expectedBodyBytes(offset: plan.offset, expectedBytes: expectedBytes)
        // Cellular + sim-timeout stamps are centralized so no task-creation site can miss them.
        var ranged = requestApplyingTaskPolicies(baseRequest)
        ranged.setValue(plan.rangeHeaderValue, forHTTPHeaderField: "Range")
        if let validator = store.rangeValidator(for: candidate.attemptKey) {
            ranged.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        let task = urlSession.downloadTask(with: ranged)
        task.taskDescription = plan.length != nil
            ? StaticRangeSegmentMarker.taskDescription(ratingKey: ratingKey,
                                                       offset: plan.offset,
                                                       attemptID: attemptID)
            : DownloadAttemptMarker.taskDescription(ratingKey: ratingKey, attemptID: attemptID)
        var existingRangeTasksToCancel: [Int] = []
        lock.lock()
        if rangeHaltKinds[candidate.attemptKey] != nil {
            lock.unlock()
            task.cancel()
            AppDiagnostics.record(.downloads, "downloads.range_start_suppressed", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("register_halted"),
                "task_id": .int(task.taskIdentifier),
            ])
            throw CancellationError()
        }
        if let duplicate = duplicateSegmentDecision(for: candidate) {
            if duplicate.shouldReplaceExisting {
                existingRangeTasksToCancel = candidate.segmentLength != nil
                    ? supersedeRangeSegmentTasksLocked(
                        ratingKey: ratingKey,
                        offset: candidate.baseOffset
                    )
                    : supersedeRangeTasksLocked(ratingKey: ratingKey)
            } else {
                let superseded = candidate.segmentLength != nil
                    ? supersedeRangeSegmentTasksLocked(
                        ratingKey: ratingKey,
                        offset: candidate.baseOffset,
                        keeping: duplicate.existingTaskIdentifier
                    )
                    : supersedeRangeTasksLocked(
                        ratingKey: ratingKey,
                        keeping: duplicate.existingTaskIdentifier
                    )
                lock.unlock()
                task.cancel()
                for identifier in superseded {
                    cancelURLSessionTask(identifier: identifier)
                }
                _ = resolveLifecycleSubmission(store.submitStatus(for: candidate.attemptKey, .downloading))
                onChange?()
                AppDiagnostics.record(.downloads, "downloads.range_duplicate_start_suppressed", fields: [
                    "download_id": .identifier(ratingKey),
                    "task_id": .int(task.taskIdentifier),
                    "existing_task_id": .int(duplicate.existingTaskIdentifier),
                    "superseded_task_count": .int(superseded.count + 1),
                    "base_offset": .int(candidate.baseOffset),
                    "existing_base_offset": .int(duplicate.existingEntry.baseOffset),
                    "phase": .label("register"),
                ])
                return duplicate.existingTaskIdentifier
            }
        }
        if resetsRetryCount {
            retryCounts[candidate.attemptKey] = 0
        }
        lastProgressNotify = nil
        loggedProgressMilestones[task.taskIdentifier] = []
        lastRangeProgressDiagnostic.removeValue(forKey: task.taskIdentifier)
        rangeInflight[task.taskIdentifier] = candidate
        lock.unlock()
        if !existingRangeTasksToCancel.isEmpty {
            for identifier in existingRangeTasksToCancel {
                cancelURLSessionTask(identifier: identifier)
            }
            AppDiagnostics.record(.downloads, "downloads.range_duplicate_start_replaced", fields: [
                "download_id": .identifier(ratingKey),
                "task_id": .int(task.taskIdentifier),
                "existing_task_id": .int(existingRangeTasksToCancel.first ?? -1),
                "superseded_task_count": .int(existingRangeTasksToCancel.count),
                "base_offset": .int(candidate.baseOffset),
            ])
        }
        let urlShape = DiagnosticRedactor.urlShape(ranged.url)
        downloadLog.info("range-remainder-start ratingKey=\(ratingKey, privacy: .public) offset=\(plan.offset, privacy: .public) url_shape=\(urlShape, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.range_start", fields: [
            "download_id": .identifier(ratingKey),
            "task_id": .int(task.taskIdentifier),
            "remainder_reason": .label(remainderReason),
            "offset_bytes": .bytes(plan.offset),
            "offset_exact": .int(plan.offset),
            "has_offset": .bool(plan.offset > 0),
            "expected_bytes": .bytes(expectedBytes),
            "expected_exact": .int(expectedBytes ?? -1),
            "range_request_shape": .label(plan.length != nil ? "closed" : "open_ended"),
            "segment_length": .int(plan.length ?? -1),
            "planned_body_bytes": .bytes(expectedBodyBytes),
            "url_shape": .urlShape(ranged.url),
            "allows_cellular": .bool(ranged.allowsCellularAccess),
        ])
        AppDiagnostics.record(.downloads, "downloads.range_remainder_start", fields: [
            "download_id": .identifier(ratingKey),
            "task_id": .int(task.taskIdentifier),
            "remainder_reason": .label(remainderReason),
            "offset_bytes": .bytes(plan.offset),
            "offset_exact": .int(plan.offset),
            "expected_exact": .int(expectedBytes ?? -1),
            "segment_length": .int(plan.length ?? -1),
            "planned_body_bytes": .bytes(expectedBodyBytes),
        ])
        task.resume()
        return task.taskIdentifier
    }

    private func isRangeHalted(for attemptKey: DownloadAttemptKey) -> Bool {
        lock.lock()
        let halted = rangeHaltKinds[attemptKey] != nil
        lock.unlock()
        return halted
    }

    private func staticRangeRetryKey(for key: DownloadAttemptKey) -> StaticRangeRetryKey {
        StaticRangeRetryKey(downloadID: key.ratingKey, attemptID: key.attemptID.rawValue)
    }

    /// Reset the visible range watermark only while the callback still owns the row. A stale
    /// attempt shares the stable media path with its replacement, so treating `.staleOrMissing`
    /// as a zero-byte checkpoint would let late A work drive B's retry/failure state.
    private func resetStaticRangeProgressToDurableCheckpoint(
        for key: DownloadAttemptKey,
        expectedBytes: Int?,
        context: String
    ) -> Int? {
        switch store.resetStaticRangeProgressToDurableCheckpoint(
            for: key,
            expectedBytes: expectedBytes
        ) {
        case .applied(let bytes), .unchanged(let bytes), .notStatic(let bytes):
            return bytes
        case .staleOrMissing:
            AppDiagnostics.record(.downloads, "downloads.stale_callback_ignored", fields: [
                "download_id": .identifier(key.ratingKey),
                "phase": .label(context),
            ])
            return nil
        case .persistenceFailed(let bytes, let result):
            AppDiagnostics.record(.downloads, "downloads.range_checkpoint_reset_failed", fields: [
                "download_id": .identifier(key.ratingKey),
                "phase": .label(context),
                "bytes": .bytes(bytes),
                "persistence": .label(String(describing: result)),
            ])
            return nil
        }
    }

    /// `startRangeRemainder` deliberately throws `CancellationError` when a user pause/delete races an
    /// internal continuation/retry. That is not a transfer failure: pause/delete owns the visible row
    /// transition, and the internal path must not overwrite it with `.failed` or a new red error.
    private func shouldSuppressRangeStartFailure(for attemptKey: DownloadAttemptKey,
                                                 error: Error,
                                                 context: String) -> Bool {
        let ratingKey = attemptKey.ratingKey
        let halted = isRangeHalted(for: attemptKey)
        guard BackgroundDownloadPauseCancellationPolicy.shouldSuppressRangeStartFailure(
            isHalted: halted,
            isCancellation: error is CancellationError
        ) else { return false }
        AppDiagnostics.record(.downloads, "downloads.range_start_cancelled", fields: [
            "download_id": .identifier(ratingKey),
            "context": .label(context),
            "halted": .bool(halted),
            "error": .error(error),
        ])
        return true
    }

    /// Terminal storage-full handling for internal continuation/retry paths. The row cannot make
    /// forward progress until the user frees space, so surface the real reason (and tear the
    /// train down) instead of a generic pause/failure. The durable partial is preserved as the
    /// retry checkpoint.
    private func handleRangeStartStorageFull(for key: DownloadAttemptKey, error: Error, context: String) -> Bool {
        let ratingKey = key.ratingKey
        guard case DownloadManager.DownloadError.storageFull = error else { return false }
        var fields: [String: DiagnosticFieldValue] = [
            "download_id": .identifier(ratingKey),
            "context": .label(context),
        ]
        if let free = availableStorageBytes() {
            fields["free_bytes"] = .bytes(Int(free))
            fields["free_bytes_exact"] = .int(Int(free))
        }
        AppDiagnostics.record(.downloads, "downloads.range_storage_full", fields: fields)
        setFailedPurgingHeldSegments(for: key)
        onError?(ratingKey, .storageFull)
        onChange?()
        return true
    }

    /// #95: resume a `.paused` download from persisted URLSession resume data, continuing from
    /// the byte offset instead of restarting at 0. Mirrors `start(...)`'s bookkeeping but creates
    /// the task with `downloadTask(withResumeData:)`. Returns `false` if the resume data was
    /// rejected (the caller then falls back to a clean restart). The OS validates the blob lazily;
    /// a stale/invalid blob surfaces later via `didCompleteWithError` (200 full-restart / 416),
    /// which the caller's normal failure path handles.
    @discardableResult
    func resume(ratingKey: String, resumeData: Data, to destination: URL) -> Bool {
        guard isStartupAdmissionActive else { return false }
        guard !resumeData.isEmpty else { return false }
        guard let attemptID = currentAttemptIdentity(ratingKey: ratingKey) else { return false }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard store.ownsAttempt(attemptKey),
              let workingDestination = store.attemptWorkingFileURL(for: attemptKey) else { return false }
        let task = urlSession.downloadTask(withResumeData: resumeData)
        task.taskDescription = DownloadAttemptMarker.taskDescription(
            ratingKey: ratingKey, attemptID: attemptID)
        lock.lock()
        retryCounts[attemptKey] = 0
        lastProgressNotify = nil
        loggedProgressMilestones[task.taskIdentifier] = []
        lastRangeProgressDiagnostic.removeValue(forKey: task.taskIdentifier)
        inflight[task.taskIdentifier] = OpaqueTransfer(
            attemptKey: attemptKey,
            destination: workingDestination
        )
        lock.unlock()
        downloadLog.info("resume ratingKey=\(ratingKey, privacy: .public) bytes=\(resumeData.count, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.transfer_resume", fields: [
            "download_id": .identifier(ratingKey),
            "resume_blob_bytes": .bytes(resumeData.count),
        ])
        task.resume()
        return true
    }

    private func pauseStillApplies(for key: DownloadAttemptKey) -> Bool {
        let ratingKey = key.ratingKey
        let status = store.record(for: key)?.status
        lock.lock()
        let hasReplacement = inflight.values.contains { $0.ratingKey == ratingKey }
            || rangeInflight.values.contains { $0.ratingKey == ratingKey }
        let rangePauseIsActive = rangeHaltKinds[key] == .pause
        lock.unlock()
        // Static Range pause is persisted before asynchronous task cancellation. Its callbacks may
        // still save open-ended resume data, but only while the same pause halt remains installed;
        // Resume clears the halt, so a late callback cannot pause the replacement generation.
        if status == .paused, rangePauseIsActive {
            return !hasReplacement
        }
        // If the user already resumed/retried and a replacement task is tracked, a delayed cancel
        // callback from the old task must not flip the new active row back to Paused.
        return BackgroundDownloadPauseCancellationPolicy.pauseStillApplies(
            status: status,
            hasReplacementTask: hasReplacement
        )
    }

    /// Pause any in-flight transfer for a ratingKey. Prefer URLSession resume data for static
    /// byte-range-safe lanes; for forward-only transcode/remux streams, this still becomes a safe
    /// user pause (no auto-retry until Resume), but Resume restarts cleanly.
    func pause(ratingKey: String) {
        guard let attemptID = currentAttemptIdentity(ratingKey: ratingKey) else { return }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard store.ownsAttempt(attemptKey) else { return }
        AppDiagnostics.record(.downloads, "downloads.pause_requested", fields: [
            "download_id": .identifier(ratingKey),
        ])

        lock.lock()
        let ids = Set(inflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
        let rangeIds = Set(rangeInflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
        let rangeEntriesForKey = rangeInflight.values.filter { $0.ratingKey == ratingKey }
        inflight = inflight.filter { $0.value.ratingKey != ratingKey }
        // Halt the lane unconditionally at snapshot time. Waiting for the per-task insert in
        // `pauseRangeTask` left a window: if the row's only Range task finished between this
        // snapshot and the `getAllTasks` callback, no halt was ever set, the finished-body path
        // continued the train, and `pauseStillApplies` then silently dropped the pause. A finish
        // racing this insert is preserved by the writeThenPause path, so no bytes are lost.
        // A pause never downgrades an existing cancel halt: the cancel's caller may already be
        // deleting the partial, and preserving a body onto it would resurrect deleted bytes.
        if rangeHaltKinds[attemptKey] != .cancel { rangeHaltKinds[attemptKey] = .pause }
        lock.unlock()
        // B1/B2: compute the row-level pause context ONCE (durable checkpoint + the aggregate display
        // total across the whole segment train), so every per-task cancel below shares one honest
        // watermark instead of each racing the single per-key blob slot with its own file position.
        let pauseContext = makeRangePauseContext(for: attemptKey,
                                                 entries: Array(rangeEntriesForKey))
        if !rangeIds.isEmpty {
            // User intent wins synchronously over task-completion/refill races. Bounded train
            // resume blobs and their optimistic watermark are unsafe and no longer authoritative.
            if pauseContext.isTrain {
                _ = resolveLifecycleSubmission(store.submitClearResumeData(for: attemptKey))
            }
            _ = resolveLifecycleSubmission(store.submitStatus(for: attemptKey, .paused))
            onError?(ratingKey, .interruptedResumable)
            onChange?()
        }
        endRangeRequestRebuildGrace(for: attemptKey, reason: "paused")
        // M-6: held ahead-of-checkpoint stashes are deliberately KEPT across a user pause. The
        // resume planner counts held offsets as covered (no re-fetch) and the post-append drain
        // splices them validator-checked, so purging here destroyed up to a full train of
        // completed bodies that Resume would have reused. They are still purged on cancel/delete,
        // terminal failure, changed-resource restart, adopted-200, and completion — and a relaunch
        // sweeps them regardless (the held map is in-memory).

        // #169: opaque and range tasks share one session now — enumerate it once and dispatch each
        // matched task by lane (range entries are removed as `pauseRangeTask` matches them).
        guard isStartupAdmissionActive else { return }
        urlSession.getAllTasks { tasks in
            var matched = false
            for task in tasks {
                if rangeIds.contains(task.taskIdentifier) {
                    matched = true
                    self.pauseRangeTask(task, key: attemptKey, context: pauseContext)
                } else if ids.contains(task.taskIdentifier) {
                    matched = true
                    if let downloadTask = task as? URLSessionDownloadTask {
                        let displayBytes = Int(max(downloadTask.countOfBytesReceived, 0))
                        downloadTask.cancel { resumeData in
                            let resumeBytes = resumeData?.count ?? 0
                            let supportsResume = self.supportsPersistedResumeData(for: attemptKey)
                            AppDiagnostics.record(.downloads, "downloads.pause_resume_data", fields: [
                                "download_id": .identifier(ratingKey),
                                "resume_data_present": .bool(resumeBytes > 0),
                                "resume_blob_bytes": .bytes(resumeBytes),
                                "supports_resume": .bool(supportsResume),
                                "task_type": .label("backgroundDownloadTask"),
                            ])
                            guard self.pauseStillApplies(for: attemptKey) else { return }
                            if let resumeData, !resumeData.isEmpty, supportsResume {
                                self.resolveLifecycleSubmission(self.store.submitResumeData(for: attemptKey, resumeData, displayBytes: displayBytes))
                            }
                            self.markPausedAfterUserPause(for: attemptKey)
                        }
                    } else {
                        task.cancel()
                        self.markPausedAfterUserPause(for: attemptKey)
                    }
                }
            }

            if !matched {
                // No live task owned this row (paused between continuations, or a relaunch race).
                // Drop any stale range tracking; the durable partial keeps the row resumable.
                let removedRangeEntries = self.removeRangeTransfers(taskIdentifiers: rangeIds)
                let expectedBytes = removedRangeEntries.first?.expectedBytes
                self.store.resetStaticRangeProgressToDurableCheckpoint(
                    for: attemptKey,
                    expectedBytes: expectedBytes
                )
                AppDiagnostics.record(.downloads, "downloads.pause_no_matching_task", fields: [
                    "download_id": .identifier(ratingKey),
                    "background_task_ids": .int(ids.count),
                    "range_task_ids": .int(rangeIds.count),
                ])
                if self.pauseStillApplies(for: attemptKey) {
                    self.resolveLifecycleSubmission(self.store.submitStatus(for: attemptKey, .paused))
                    self.onChange?()
                }
            }
        }
    }

    /// Row-level facts captured ONCE at the start of a pause, before any per-task cancel mutates the
    /// live set. `isTrain` distinguishes the pre-queued segment train (B1/B2 semantics) from the
    /// single open-ended remainder (unchanged pre-segment behavior).
    private struct RangePauseContext {
        let isTrain: Bool
        let durableBytes: Int
        /// durable checkpoint + Σ(live segment bodies) — the bytes actually downloaded across the
        /// whole train, matching what `didWriteData` publishes live (A5). Used as the paused-row
        /// watermark for the train instead of the highest segment's file POSITION (the B1 bug).
        let aggregateDisplayBytes: Int
    }

    private func makeRangePauseContext(for key: DownloadAttemptKey, entries: [RangeTransfer]) -> RangePauseContext {
        let isTrain = entries.contains { $0.segmentLength != nil }
        let durableBytes = entries.first.flatMap { fileSize(at: $0.workingURL) }
            ?? store.durableStaticRangeCheckpointSize(for: key) ?? 0
        lock.lock()
        let heldBodyBytes = heldRangeSegments[key]?.values.map(\.length) ?? []
        lock.unlock()
        let aggregate = DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: durableBytes,
            liveSegmentBodyBytes: entries.map(\.bodyBytesWritten) + heldBodyBytes)
        return RangePauseContext(isTrain: isTrain,
                                 durableBytes: durableBytes,
                                 aggregateDisplayBytes: aggregate)
    }

    private func pauseRangeTask(_ task: URLSessionTask, key: DownloadAttemptKey, context: RangePauseContext) {
        let ratingKey = key.ratingKey
        lock.lock()
        let entry = rangeInflight.removeValue(forKey: task.taskIdentifier)
        if entry != nil {
            supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
        }
        if rangeHaltKinds[key] != .cancel { rangeHaltKinds[key] = .pause }
        lock.unlock()

        // B2: under a segment train only ONE live segment — the one whose offset equals the durable
        // partial — can ever survive `adoptionDecision` on Resume; the other 7 offsets are guaranteed
        // stale, so producing/persisting their blobs only thrashes the single per-key blob slot (last
        // writer wins) and leaks a false watermark. Persist the head segment's blob; plain-cancel the
        // rest. Open-ended remainders (single task at baseOffset == durable) satisfy this trivially, so
        // the pre-segment lane keeps persisting its one blob unchanged.
        let isSegment = entry?.segmentLength != nil
        let shouldPersistBlob: Bool
        // #227/#231: a continuous remainder can hold many GB of non-durable temp; pause it by
        // producing resume data so a later Resume continues that temp instead of re-fetching it.
        let rangeResumeDisplayBytes: Int?
        if context.isTrain, isSegment, let entry {
            shouldPersistBlob = StaticRangeResumeDataPolicy.shouldPersistSegmentBlobOnPause(
                segmentBaseOffset: entry.baseOffset,
                durableBytes: context.durableBytes)
            // B1: the paused-row watermark is the WHOLE train's downloaded total, not this one
            // segment's file position — computed once in `makeRangePauseContext`.
            rangeResumeDisplayBytes = context.aggregateDisplayBytes
        } else {
            shouldPersistBlob = true
            rangeResumeDisplayBytes = entry.map { rangeEntry in
                let taskBytes = rangeEntry.baseOffset
                    + max(rangeEntry.bodyBytesWritten, Int(max(task.countOfBytesReceived, 0)))
                return DownloadLiveRangeProgressPolicy.displayBytesForResumedTask(
                    taskBytes: taskBytes,
                    baseOffset: rangeEntry.baseOffset,
                    resumeDisplayBytes: store.resumeDisplayBytes(for: key)
                )
            }
        }

        if shouldPersistBlob,
           StaticRangeResumeDataPolicy.pauseDisposition()
            == .cancelProducingResumeData,
           let downloadTask = task as? URLSessionDownloadTask {
            downloadTask.cancel { [weak self] resumeData in
                guard let self else { return }
                let hasBlob = resumeData?.isEmpty == false
                if StaticRangeResumeDataPolicy.shouldPersistBlobOnPark(hasResumeData: hasBlob),
                   let resumeData {
                    self.resolveLifecycleSubmission(self.store.submitResumeData(for: key, resumeData, displayBytes: rangeResumeDisplayBytes))
                }
                AppDiagnostics.record(.downloads, "downloads.range_pause_resume_data", fields: [
                    "download_id": .identifier(ratingKey),
                    "resume_data_present": .bool(hasBlob),
                    "resume_blob_bytes": .bytes(resumeData?.count ?? 0),
                    "base_offset": .int(entry?.baseOffset ?? -1),
                    "task_type": .label(isSegment ? "rangeSegmentHead" : "rangeDownloadTask"),
                ])
                self.finishRangePause(for: key, entry: entry)
            }
            return
        }
        // Plain cancel: either the open-ended lane's non-resume-data disposition, or (B2) an off-head
        // train segment whose blob would be guaranteed stale. No resume data produced/persisted — its
        // temp body is unrecoverable once the process dies anyway.
        if context.isTrain, isSegment {
            AppDiagnostics.record(.downloads, "downloads.range_segment_pause_dropped", fields: [
                "download_id": .identifier(ratingKey),
                "base_offset": .int(entry?.baseOffset ?? -1),
                "durable_bytes": .int(context.durableBytes),
                "body_bytes": .int(entry?.bodyBytesWritten ?? -1),
            ])
        }
        task.cancel()
        finishRangePause(for: key, entry: entry)
    }

    private func finishRangePause(for key: DownloadAttemptKey, entry: RangeTransfer?) {
        let ratingKey = key.ratingKey
        let partialFilePresent = entry.map { fileManager.fileExists(atPath: $0.workingURL.path) } ?? false
        let reset = store.resetStaticRangeProgressToDurableCheckpoint(
            for: key,
            expectedBytes: entry?.expectedBytes
        )
        let bytes: Int
        switch reset {
        case .applied(let value), .unchanged(let value), .notStatic(let value):
            bytes = value
        case .staleOrMissing, .persistenceFailed:
            AppDiagnostics.record(.downloads, "downloads.range_checkpoint_reset_rejected", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("pause"),
            ])
            return
        }
        AppDiagnostics.record(.downloads, "downloads.range_paused", fields: [
            "download_id": .identifier(ratingKey),
            "bytes": .bytes(bytes),
            "expected_bytes": .bytes(entry?.expectedBytes),
            "partial_file_present": .bool(partialFilePresent),
            "task_type": .label("rangeDownloadTask"),
        ])
        markPausedAfterUserPause(for: key)
    }


    @discardableResult
    private func removeRangeTransfers(taskIdentifiers: Set<Int>) -> [RangeTransfer] {
        lock.lock()
        var removed: [RangeTransfer] = []
        for id in taskIdentifiers {
            if let entry = rangeInflight.removeValue(forKey: id) {
                removed.append(entry)
            }
        }
        lock.unlock()
        return removed
    }

    private func markPausedAfterUserPause(for key: DownloadAttemptKey) {
        let ratingKey = key.ratingKey
        guard pauseStillApplies(for: key) else { return }
        _ = resolveLifecycleSubmission(store.submitStatus(for: key, .paused))
        onError?(ratingKey, .interruptedResumable)
        onChange?()
    }

    /// Cancel any in-flight transfer for a ratingKey.
    func cancel(ratingKey: String) {
        halt(ratingKey: ratingKey, preserveHeldRangeSegments: false)
    }

    /// Stop attempt A after destructive deletion was durably deferred. The row and every local
    /// artifact remain recovery authority until its cleanup operations reach the journal, so this
    /// halt differs from ordinary Cancel only by retaining persisted held manifests and bodies.
    func haltForPendingDeletion(ratingKey: String) {
        halt(ratingKey: ratingKey, preserveHeldRangeSegments: true)
    }

    private func halt(ratingKey: String, preserveHeldRangeSegments: Bool) {
        guard let attemptID = currentAttemptIdentity(ratingKey: ratingKey) else { return }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard store.ownsAttempt(attemptKey) else { return }
        AppDiagnostics.record(.downloads, "downloads.cancel_requested", fields: [
            "download_id": .identifier(ratingKey),
        ])
        lock.lock()
        let ids = Set(inflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
        let rangeIds = Set(rangeInflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
        inflight = inflight.filter { $0.value.ratingKey != ratingKey }
        rangeInflight = rangeInflight.filter { $0.value.ratingKey != ratingKey }
        // Halt the static Range lane so a delegate callback racing after this snapshot cannot
        // append/resurrect the file the caller is about to delete or start replacement work.
        rangeHaltKinds[attemptKey] = .cancel
        // Advance the train generation: a finished body already in the delegate→IO hop must be
        // discarded, not appended at offset 0 of a re-download's file — and without the bump a
        // legitimate delete race trips the pre-append drift assertion (a DEBUG crash).
        rangeTrainEpochs[attemptKey] = (rangeTrainEpochs[attemptKey] ?? 0) + 1
        // M-7: the row is being cancelled/deleted — its restart budgets die with it, so a
        // re-download of the same key starts clean even if it skips `start()`'s reset.
        retryCounts.removeValue(forKey: attemptKey)
        staticRangeRetryBudget.reset(key: staticRangeRetryKey(for: attemptKey))
        rangeHTTPRehydrateCounts.removeValue(forKey: attemptKey)
        rangeBlobResumeCounts.removeValue(forKey: attemptKey)
        lock.unlock()
        // D6: the consecutive-truncation parking budget is keyed by ratingKey and guarded by
        // `finalizationStateQueue` (not `lock`), so it can't be cleared inside the block above.
        // Clear it here for the same M-7 reason: the row is being cancelled/deleted, so a
        // re-download of the same item must start clean instead of inheriting a stale truncation
        // count that would park it immediately. `.complete` is the only other clear site.
        finalizationStateQueue.sync { _ = truncationFailureCounts.removeValue(forKey: ratingKey) }
        endRangeRequestRebuildGrace(for: attemptKey, reason: "cancelled")
        // Keep the durable owner on the row. Delete removes the whole row immediately; restart
        // paths need the old owner so the replacement can perform an exact A → B compare/swap.
        // Clearing only the token would leave a schema-v3 row malformed across relaunch and would
        // make a legitimate Retry look like an unsafe attempt to adopt an unowned row.
        // Ordinary Cancel is destructive and abandons the row. A deletion-pending halt cannot
        // purge these files yet: their manifests remain part of the exact recoverable row until
        // journal-first deletion resumes successfully.
        if !preserveHeldRangeSegments {
            purgeHeldRangeSegments(for: attemptKey)
        }

        // A dormant session must remain inert: touching the lazy URLSession here would construct
        // it outside the startup migration/admission boundary. There cannot be admitted task IDs
        // while dormant, and activation owns cancellation of every pre-admission OS task.
        guard isStartupAdmissionActive else { return }

        // #169: opaque and range tasks both live on `urlSession` now — cancel by id on one session.
        let all = ids.union(rangeIds)
        urlSession.getAllTasks { tasks in
            for task in tasks where all.contains(task.taskIdentifier) {
                task.cancel()
            }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard !rejectTaskCallback(downloadTask) else { return }
        lock.lock()
        let rangeEntry = rangeInflight[downloadTask.taskIdentifier]
        let entry = rangeEntry == nil ? inflight[downloadTask.taskIdentifier] : nil
        let firstCallback = (rangeEntry != nil || entry != nil)
            && loggedExpectation.insert(downloadTask.taskIdentifier).inserted
        lock.unlock()

        if let rangeEntry {
            guard stillOwnsAttempt(rangeEntry.attemptKey, phase: "range_progress") else { return }
            // Range response bytes accumulate in the OS temp; live progress is the durable partial
            // already on disk (`baseOffset`) plus this response body so far, against the FILE's
            // expected size. The task's own `totalBytesExpectedToWrite` is just this remainder.
            let bodyBytesWritten = Int(totalBytesWritten)
            let accountedBodyBytes = DownloadLiveRangeProgressPolicy.accountedTaskBodyBytes(
                reportedBytes: bodyBytesWritten,
                segmentLength: rangeEntry.segmentLength)
            lock.lock()
            let halted = rangeHaltKinds[rangeEntry.attemptKey] != nil
            if halted {
                rangeInflight.removeValue(forKey: downloadTask.taskIdentifier)
                supersededRangeTaskIdentifiers.insert(downloadTask.taskIdentifier)
                loggedProgressMilestones.removeValue(forKey: downloadTask.taskIdentifier)
                lastRangeProgressDiagnostic.removeValue(forKey: downloadTask.taskIdentifier)
            }
            lock.unlock()
            if halted {
                downloadTask.cancel()
                AppDiagnostics.record(.downloads, "downloads.range_halted_progress_ignored", fields: [
                    "download_id": .identifier(rangeEntry.ratingKey),
                    "task_id": .int(downloadTask.taskIdentifier),
                    "base_offset": .int(rangeEntry.baseOffset),
                    "body_bytes": .int(bodyBytesWritten),
                ])
                return
            }
            if let segmentLength = rangeEntry.segmentLength,
               bodyBytesWritten > segmentLength {
                // A closed Range owns exactly `segmentLength` response bytes. URLSession resume
                // data has been observed replaying a closed request as an effectively open-ended
                // HTTP/3 transfer; do not merely cap its UI contribution while it downloads the
                // rest of the file. Cancel at the first invariant breach and rebuild from the
                // app-owned durable checkpoint.
                lock.lock()
                rangeInflight.removeValue(forKey: downloadTask.taskIdentifier)
                supersededRangeTaskIdentifiers.insert(downloadTask.taskIdentifier)
                loggedProgressMilestones.removeValue(forKey: downloadTask.taskIdentifier)
                lastRangeProgressDiagnostic.removeValue(forKey: downloadTask.taskIdentifier)
                lock.unlock()
                downloadTask.cancel()
                _ = resolveLifecycleSubmission(store.submitClearResumeData(for: rangeEntry.attemptKey))
                guard resetStaticRangeProgressToDurableCheckpoint(
                    for: rangeEntry.attemptKey,
                    expectedBytes: rangeEntry.expectedBytes,
                    context: "closed_range_oversized"
                ) != nil else { return }
                beginRangeRequestRebuildGrace(for: rangeEntry.attemptKey)
                _ = resolveLifecycleSubmission(store.submitStatus(for: rangeEntry.attemptKey, .queued))
                AppDiagnostics.record(.downloads, "downloads.range_closed_body_oversized", fields: [
                    "download_id": .identifier(rangeEntry.ratingKey),
                    "task_id": .int(downloadTask.taskIdentifier),
                    "base_offset": .int(rangeEntry.baseOffset),
                    "segment_length": .int(segmentLength),
                    "reported_body_bytes": .int(bodyBytesWritten),
                ])
                onRangeRequestNeeded?(rangeEntry.ratingKey, .requestRebuildNeeded)
                return
            }
            let durableBytes = fileSize(at: rangeEntry.workingURL) ?? 0
            if durableBytes > rangeEntry.baseOffset + (rangeEntry.segmentLength ?? 0) {
                lock.lock()
                rangeInflight.removeValue(forKey: downloadTask.taskIdentifier)
                supersededRangeTaskIdentifiers.insert(downloadTask.taskIdentifier)
                loggedProgressMilestones.removeValue(forKey: downloadTask.taskIdentifier)
                lastRangeProgressDiagnostic.removeValue(forKey: downloadTask.taskIdentifier)
                lock.unlock()
                downloadTask.cancel()
                AppDiagnostics.record(.downloads, "downloads.range_stale_progress_ignored", fields: [
                    "download_id": .identifier(rangeEntry.ratingKey),
                    "task_id": .int(downloadTask.taskIdentifier),
                    "base_offset": .int(rangeEntry.baseOffset),
                    "durable_bytes": .int(durableBytes),
                    "body_bytes": .int(bodyBytesWritten),
                    "total_bytes": .int(rangeEntry.baseOffset + bodyBytesWritten),
                    "reason": .label("durable_checkpoint_ahead"),
                ])
                return
            }
            // A network-path switch can make URLSession restart the response body counter for
            // the SAME task identifier. Keeping the old optimistic count in that case freezes
            // the live watermark (and its rate) until the replacement counter catches up. The
            // temp body is no longer trustworthy, so cancel it and rebuild from the durable
            // checkpoint — the same safe recovery users previously triggered with Pause All →
            // Resume All.
            let counterResetThreshold = 1_024 * 1_024
            // Judge a reset by the task's LIVE counter, not just this callback's snapshot: after a
            // background relaunch the reattach seeds the watermark from `countOfBytesReceived`
            // (ahead) while URLSession replays buffered didWriteData events (behind), and treating
            // that replay as a reset cancelled healthy off-head transfers — rolling gigabytes of
            // temp body back to the durable checkpoint. A real counter reset drops BOTH values.
            let liveBodyBytes = max(bodyBytesWritten, Int(max(0, downloadTask.countOfBytesReceived)))
            let didResetCounter = rangeEntry.bodyBytesWritten >= counterResetThreshold
                && liveBodyBytes + 64 * 1_024 < rangeEntry.bodyBytesWritten
            if didResetCounter {
                lock.lock()
                rangeInflight.removeValue(forKey: downloadTask.taskIdentifier)
                supersededRangeTaskIdentifiers.insert(downloadTask.taskIdentifier)
                loggedProgressMilestones.removeValue(forKey: downloadTask.taskIdentifier)
                lastRangeProgressDiagnostic.removeValue(forKey: downloadTask.taskIdentifier)
                lock.unlock()
                downloadTask.cancel()
                guard resetStaticRangeProgressToDurableCheckpoint(
                    for: rangeEntry.attemptKey, expectedBytes: rangeEntry.expectedBytes,
                    context: "counter_reset_rebuild") != nil else { return }
                // Hold the background completion handler across the main-actor request rebuild
                // (#212): releasing it here lets the OS suspend us before the next task exists.
                beginRangeRequestRebuildGrace(for: rangeEntry.attemptKey)
                _ = resolveLifecycleSubmission(store.submitStatus(for: rangeEntry.attemptKey, .queued))
                AppDiagnostics.record(.downloads, "downloads.range_counter_reset_rebuild", fields: [
                    "download_id": .identifier(rangeEntry.ratingKey),
                    "task_id": .int(downloadTask.taskIdentifier),
                    "base_offset": .int(rangeEntry.baseOffset),
                    "previous_body_bytes": .int(rangeEntry.bodyBytesWritten),
                    "reset_body_bytes": .int(bodyBytesWritten),
                ])
                onRangeRequestNeeded?(rangeEntry.ratingKey, .requestRebuildNeeded)
                return
            }
            lock.lock()
            if let newerTaskIdentifier = newerRangeTaskIdentifier(for: rangeEntry,
                                                                   currentTaskIdentifier: downloadTask.taskIdentifier,
                                                                   currentBodyBytes: bodyBytesWritten,
                                                                   segmentScoped: rangeEntry.segmentLength != nil
                                                                    || StaticRangeSegmentMarker.parse(
                                                                        downloadTask.taskDescription) != nil) {
                rangeInflight.removeValue(forKey: downloadTask.taskIdentifier)
                supersededRangeTaskIdentifiers.insert(downloadTask.taskIdentifier)
                loggedProgressMilestones.removeValue(forKey: downloadTask.taskIdentifier)
                lastRangeProgressDiagnostic.removeValue(forKey: downloadTask.taskIdentifier)
                lock.unlock()
                downloadTask.cancel()
                AppDiagnostics.record(.downloads, "downloads.range_stale_progress_ignored", fields: [
                    "download_id": .identifier(rangeEntry.ratingKey),
                    "task_id": .int(downloadTask.taskIdentifier),
                    "newer_task_id": .int(newerTaskIdentifier),
                    "base_offset": .int(rangeEntry.baseOffset),
                    "body_bytes": .int(bodyBytesWritten),
                    "total_bytes": .int(rangeEntry.baseOffset + bodyBytesWritten),
                ])
                return
            }
            lock.unlock()

            let total = rangeEntry.baseOffset + bodyBytesWritten
            // Live display bytes must reflect the WHOLE segment train, not just this callback's own
            // task: durable checkpoint plus every still-in-flight segment's optimistic body (#A5).
            // Update this task's own live body count first so the sum below includes THIS callback's
            // fresh bytes, then read the full set for the row under the same lock discipline the rest
            // of this delegate uses for cross-queue `rangeInflight` reads.
            lock.lock()
            if var live = rangeInflight[downloadTask.taskIdentifier] {
                live.bodyBytesWritten = accountedBodyBytes
                rangeInflight[downloadTask.taskIdentifier] = live
            }
            let liveSegmentBodyBytes = rangeInflight.values
                .filter { $0.ratingKey == rangeEntry.ratingKey }
                .map(\.bodyBytesWritten)
            let heldSegmentBodyBytes = heldRangeSegments[rangeEntry.attemptKey]?.values.map(\.length) ?? []
            retryCounts[rangeEntry.attemptKey] = 0
            lock.unlock()
            let aggregatedLiveBytes = DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
                durableBytes: durableBytes,
                liveSegmentBodyBytes: liveSegmentBodyBytes + heldSegmentBodyBytes)
            // Normalize against the resume display watermark HERE, where the durable base offset
            // is known — a blob-resumed task can report bytes from a fresh per-task baseline, and
            // rebasing without the base offset used to double-count it into the display total. For
            // the single-segment case `durableBytes == rangeEntry.baseOffset` for the task's whole
            // life, so this is byte-for-byte the same rebase as before; for a segment train it
            // generalizes the same way — the base is whatever is already durable across the row.
            let resumeWatermark = store.resumeDisplayBytes(for: rangeEntry.attemptKey)
            var displayTotal = DownloadLiveRangeProgressPolicy.displayBytesForResumedTask(
                taskBytes: aggregatedLiveBytes,
                baseOffset: durableBytes,
                resumeDisplayBytes: resumeWatermark)
            if let resumeWatermark, displayTotal != aggregatedLiveBytes {
                lock.lock()
                let firstRebase = loggedRangeBlobResumeDisplayRebaseKeys
                    .insert(rangeEntry.ratingKey).inserted
                lock.unlock()
                if firstRebase {
                    AppDiagnostics.record(.downloads, "downloads.range_blob_resume_display_rebased", fields: [
                        "download_id": .identifier(rangeEntry.ratingKey),
                        "task_bytes": .bytes(aggregatedLiveBytes),
                        "resume_display_bytes": .bytes(resumeWatermark),
                        "display_bytes": .bytes(displayTotal),
                    ])
                }
            }
            let responseExpectedBytes = RangeTransferHTTPPolicy.contentRangeTotal(from: downloadTask.response as? HTTPURLResponse)
            let effectiveExpectedBytes = responseExpectedBytes ?? rangeEntry.expectedBytes
            // An UNOWNED (dead-finish-adopted) task's response must never overwrite the stored
            // source size — a prior attempt's Content-Range total belongs to the OLD part.
            if responseExpectedBytes != nil,
               StaticRangeTrainIntegrityPolicy.adoptedFinishRestriction(
                   remainderReason: rangeEntry.remainderReason) == .unrestricted {
                resolveLifecycleSubmission(store.submitSourcePartSize(for: rangeEntry.attemptKey, effectiveExpectedBytes))
            } else {
                resolveLifecycleSubmission(store.submitSourcePartSizeIfMissing(for: rangeEntry.attemptKey, effectiveExpectedBytes))
            }
            // Never publish a live sample past the known total — a transient overlap between a
            // just-superseded segment and its replacement must not flash the row past 100%.
            displayTotal = DownloadLiveRangeProgressPolicy.activeDisplayBytes(
                optimisticBytes: displayTotal,
                expectedBytes: effectiveExpectedBytes,
                durableBytes: durableBytes)
            // A Range task's in-flight bytes live in an OS temp file until
            // `didFinishDownloadingTo` lets us append them to the durable partial. Keep the visible
            // row/aggregate "downloaded" total pinned to the last real checkpoint; detailed
            // diagnostics still report optimistic `total_bytes`. This prevents Pause/Pause All from
            // appearing to lose bytes that were never actually resumable.
            let checkpointBytes = durableBytes
            let progress = (effectiveExpectedBytes ?? 0) > 0
                ? min(1, Double(checkpointBytes) / Double(effectiveExpectedBytes!))
                : 0
            _ = resolveLifecycleSubmission(store.submitProgress(for: rangeEntry.attemptKey,
                                     bytes: checkpointBytes, progress: progress))
            onRangeLiveProgress?(rangeEntry.ratingKey, displayTotal, effectiveExpectedBytes)
            recordRangeProgressIfNeeded(taskIdentifier: downloadTask.taskIdentifier,
                                        entry: rangeEntry,
                                        bodyBytes: Int(totalBytesWritten),
                                        totalBytes: total,
                                        aggregateBytes: displayTotal,
                                        expectedBytes: effectiveExpectedBytes,
                                        progress: progress,
                                        firstCallback: firstCallback)
            notifyProgressChangeIfNeeded(ratingKey: rangeEntry.ratingKey, progress: progress)
            return
        }

        guard let entry else { return }
        guard stillOwnsAttempt(entry.attemptKey, phase: "opaque_progress") else { return }
        // Log the server-declared expected size ONCE per task: -1 confirms the transcode
        // streamed without a Content-Length (so we estimate progress in the UI instead).
        if firstCallback {
            downloadLog.info("first-progress ratingKey=\(entry.ratingKey, privacy: .public) expectedBytes=\(totalBytesExpectedToWrite, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.progress_first", fields: [
                "download_id": .identifier(entry.ratingKey),
                "expected_bytes": .bytes(totalBytesExpectedToWrite > 0 ? Int(totalBytesExpectedToWrite) : nil),
                "has_expected_bytes": .bool(totalBytesExpectedToWrite > 0),
            ])
        }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        if totalBytesExpectedToWrite > 0 {
            let percent = Int((progress * 100).rounded(.down))
            var reached: [Int] = []
            lock.lock()
            var logged = loggedProgressMilestones[downloadTask.taskIdentifier, default: []]
            for milestone in [25, 50, 75, 100] where percent >= milestone && !logged.contains(milestone) {
                logged.insert(milestone)
                reached.append(milestone)
            }
            loggedProgressMilestones[downloadTask.taskIdentifier] = logged
            lock.unlock()
            for milestone in reached {
                AppDiagnostics.record(.downloads, "downloads.progress_milestone", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "percent": .int(milestone),
                    "bytes_written": .bytes(Int(totalBytesWritten)),
                ])
            }
        }
        _ = resolveLifecycleSubmission(store.submitProgress(for: entry.attemptKey,
                                 bytes: Int(totalBytesWritten),
                                 progress: progress))
        notifyProgressChangeIfNeeded(ratingKey: entry.ratingKey, progress: progress)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !rejectTaskCallback(downloadTask, temporaryBody: location) else { return }
        lock.lock()
        let superseded = supersededRangeTaskIdentifiers.remove(downloadTask.taskIdentifier) != nil
        let rangeEntry = superseded ? nil : rangeInflight[downloadTask.taskIdentifier]
        let entry = (rangeEntry == nil && !superseded) ? inflight[downloadTask.taskIdentifier] : nil
        let newerTaskIdentifier = rangeEntry.flatMap {
            newerRangeTaskIdentifier(for: $0,
                                     currentTaskIdentifier: downloadTask.taskIdentifier,
                                     currentBodyBytes: max(0, Int(downloadTask.countOfBytesReceived)),
                                     segmentScoped: $0.segmentLength != nil
                                        || StaticRangeSegmentMarker.parse(downloadTask.taskDescription) != nil)
        }
        if newerTaskIdentifier != nil {
            rangeInflight.removeValue(forKey: downloadTask.taskIdentifier)
            supersededRangeTaskIdentifiers.insert(downloadTask.taskIdentifier)
            loggedProgressMilestones.removeValue(forKey: downloadTask.taskIdentifier)
            lastRangeProgressDiagnostic.removeValue(forKey: downloadTask.taskIdentifier)
        }
        lock.unlock()
        if let rangeEntry, let newerTaskIdentifier {
            try? fileManager.removeItem(at: location)
            AppDiagnostics.record(.downloads, "downloads.range_stale_finish_ignored", fields: [
                "download_id": .identifier(rangeEntry.ratingKey),
                "task_id": .int(downloadTask.taskIdentifier),
                "newer_task_id": .int(newerTaskIdentifier),
                "base_offset": .int(rangeEntry.baseOffset),
                "body_bytes": .int(max(0, Int(downloadTask.countOfBytesReceived))),
            ])
            return
        }
        if superseded {
            AppDiagnostics.record(.downloads, "downloads.range_superseded_finish_ignored", fields: [
                "task_id": .int(downloadTask.taskIdentifier),
            ])
            return
        }
        // A finished Range response body folds into the durable partial and either starts a fresh
        // open-ended remainder or finalizes the whole file — never a straight temp→destination move.
        if let rangeEntry {
            guard stillOwnsAttempt(rangeEntry.attemptKey, phase: "range_finish") else {
                try? fileManager.removeItem(at: location)
                return
            }
            finishRangeRemainder(rangeEntry, taskIdentifier: downloadTask.taskIdentifier,
                             response: downloadTask.response, location: location)
            return
        }
        var adoptedOpaque: OpaqueTransfer?
        if entry == nil {
            // JF-F4: an unmarked opaque task (taskDescription == ratingKey) that finished while
            // tracked in neither lane is a forward-only transfer that completed while the app was
            // terminated — adopt it below through the normal opaque finalize instead of dropping
            // the multi-GB temp body and forcing a from-zero re-transcode.
            adoptedOpaque = adoptFinishedForwardOnlyTransfer(task: downloadTask)
            // I1: a background task that finished while tracked in NEITHER lane is usually an OS
            // redelivery after relaunch (URLSession may replay a completed background task before, or
            // instead of, reattach re-adopting it). If its taskDescription marks it as one of OUR
            // static-range segments and maps to a live static-range row, synthesize the entry and
            // route it through the SAME finished-body path (C1 validator/alignment checks included)
            // rather than silently dropping an irreplaceable body.
            if adoptedOpaque == nil, let adopted = adoptFinishedRangeSegment(task: downloadTask) {
                finishRangeRemainder(adopted, taskIdentifier: downloadTask.taskIdentifier,
                                 response: downloadTask.response, location: location)
                return
            }
        }
        guard let entry = entry ?? adoptedOpaque else { return }
        guard stillOwnsAttempt(entry.attemptKey, phase: "opaque_finish") else {
            try? fileManager.removeItem(at: location)
            return
        }

        // Helper: a finished transfer that isn't actually a usable video must NOT be
        // left in place as "complete" (D1). Record a `.failed` row + surface why, and
        // delete the bad file so a retry starts clean.
        func fail(_ reason: String) {
            downloadLog.error("invalid-download ratingKey=\(entry.ratingKey, privacy: .public) reason=\(reason, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "reason": .text(reason),
            ])
            try? fileManager.removeItem(at: entry.workingURL)
            clearRetryCount(for: entry.attemptKey)
            setFailedPurgingHeldSegments(for: entry.attemptKey)
            onError?(entry.ratingKey, .invalidDownload(reason))
            onChange?()
        }

        let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        let mime = (downloadTask.response as? HTTPURLResponse)?.mimeType ?? "nil"
        downloadLog.info("finished-transfer ratingKey=\(entry.ratingKey, privacy: .public) http=\(httpStatus, privacy: .public) mime=\(mime, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.transfer_finished", fields: [
            "download_id": .identifier(entry.ratingKey),
            "http_status": .int(httpStatus),
            "http_status_class": .label(httpStatus > 0 ? "\(httpStatus / 100)xx" : "unknown"),
            "mime": .label(mime),
        ])

        // 1. HTTP status — Plex returns 200 for a real file body.
        if let http = downloadTask.response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                // A download task writes the response body to `location` even on a 4xx. Keep only
                // the URL shape and body-size bucket at .error level — raw server bodies can carry
                // paths, item names, or private server text that later gets pasted into issues.
                let bodyBytes = fileSize(at: location)
                let reqShape = DiagnosticRedactor.urlShape(downloadTask.originalRequest?.url)
                let bodyBucket = bodyBytes.map(DiagnosticRedactor.byteBucket) ?? "unknown"
                downloadLog.error("download-http-error ratingKey=\(entry.ratingKey, privacy: .public) http=\(http.statusCode, privacy: .public) req_shape=\(reqShape, privacy: .public) body_bytes=\(bodyBucket, privacy: .public)")
                fail("Server returned HTTP \(http.statusCode).")
                return
            }
            // 2. MIME type — an HTML/JSON body is a Plex error page, not a container.
            // (Truncated transcodes still pass here but are caught by 3/4 below.)
            if let mime = http.mimeType?.lowercased(),
               mime.hasPrefix("text/") || mime.contains("application/json")
                || mime.contains("application/xml") {
                fail("Server returned a \(mime) page, not a video.")
                return
            }
        }

        // Move the temp file into place atomically before validating its contents
        // (the system deletes `location` once this delegate returns).
        do {
            try? fileManager.removeItem(at: entry.workingURL)
            try fileManager.moveItem(at: location, to: entry.workingURL)
        } catch {
            AppDiagnostics.record(.downloads, "downloads.move_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "error": .error(error),
            ])
            setFailedPurgingHeldSegments(for: entry.attemptKey)
            onError?(entry.ratingKey, .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer")))
            onChange?()
            return
        }

        // 3. Size observation — tiny bodies used to be rejected categorically here. That caught
        // error pages, but it also made valid short clips/trailers impossible to download. HTTP
        // status + MIME catches obvious server errors above; let the AVFoundation probe below be
        // the source of truth for small-but-valid media.
        let bytes = (try? fileManager.attributesOfItem(atPath: entry.workingURL.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        if bytes < 1_000_000 {
            AppDiagnostics.record(.downloads, "downloads.small_file_validation", fields: [
                "download_id": .identifier(entry.ratingKey),
                "bytes": .bytes(bytes),
            ])
        }

        // 4. Playability probe — confirm AVFoundation can actually open the file,
        // catching bodies that are the right size/type but not a decodable container.
        // Uses the async `load(.isPlayable)` (the sync `isPlayable` is deprecated and
        // unreliable before properties load); the delegate can't await, so we finalize
        // status in a detached Task. Bytes/progress are recorded now so the in-flight
        // count is correct even while the probe runs.
        guard publishTransferFinalizing(for: entry.attemptKey, bytes: bytes) else { return }
        let destination = entry.workingURL

        // GH #135: the fixup + #98 retrying probe + truncation guard + complete/unverified decision
        // are shared with the byte-range pipeline via `finalizeTransferredFile` so a static download
        // is validated identically no matter how its bytes arrived (this opaque path historically
        // ran them; the range path skipped them — #127 black-screen / H1–H3).
        _ = requestFinalization(
            attemptKey: entry.attemptKey, destination: destination, bytes: bytes,
            validationLabel: "local_playback", holdsBackgroundCompletion: true)
    }

    /// JF-F4: adopt a finished OPAQUE (forward-only) background task that this session is tracking
    /// in neither lane. On a device, a forward-only encoder stream can finish while the app is
    /// terminated; on relaunch the background session redelivers `didFinishDownloadingTo` before —
    /// or instead of — reattach re-adopting the task, so the finished multi-GB temp used to be
    /// dropped and reconcile parked the row `.failed` (full restart from zero). The opaque `start`
    /// paths stamp `taskDescription` with the exact row attempt, so a matching current task
    /// resolving to a live forward-only, non-terminal row is ours: hand back a synthesized entry
    /// and let the normal opaque finish path run (HTTP/MIME checks, atomic move, then
    /// `finalizeTransferredFile` — whose tightened forward-only truncation validation is the
    /// integrity gate for the adopted body). Simulator/foreground sessions never redeliver a
    /// finish for a dead process (their transfers die with it), so this path simply never fires
    /// there.
    private func adoptFinishedForwardOnlyTransfer(
        task: URLSessionDownloadTask
    ) -> OpaqueTransfer? {
        guard StaticRangeSegmentMarker.parse(task.taskDescription) == nil else { return nil }
        guard let ratingKey = Self.ratingKey(for: task, knownKeys: store.allRatingKeys),
              let record = store.record(for: ratingKey),
              record.metadata?.resolvedResumeMode(ratingKey: ratingKey) == .liveForwardOnly,
              record.status != .complete, record.status != .failed, record.status != .unverified
        else { return nil }
        // Attempt-token gate: the finished body is adopted wholesale (plain move path), so it
        // must provably belong to the row's CURRENT attempt. Unstamped tasks are not adoptable —
        // a prior life's stream would replace the new attempt's file.
        let taskAttemptID = DownloadAttemptMarker.attemptIdentity(fromTaskDescription: task.taskDescription)
        guard let taskAttemptID,
              taskAttemptID == record.attemptID else {
            AppDiagnostics.record(.downloads, "downloads.opaque_dead_finish_rejected", fields: [
                "download_id": .identifier(ratingKey),
                "task_id": .int(task.taskIdentifier),
                "reason": .label(taskAttemptID == nil ? "unstamped_task" : "attempt_mismatch"),
            ])
            return nil
        }
        AppDiagnostics.record(.downloads, "downloads.opaque_dead_finish_adopted", fields: [
            "download_id": .identifier(ratingKey),
            "task_id": .int(task.taskIdentifier),
            "status": .label(record.status.rawValue),
        ])
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: taskAttemptID)
        guard let workingURL = store.attemptWorkingFileURL(for: attemptKey) else { return nil }
        return OpaqueTransfer(attemptKey: attemptKey, destination: workingURL)
    }

    /// `remainderReason` marking an UNOWNED body: a dead-finished segment task lazily adopted in
    /// `adoptFinishedRangeSegment` rather than tracked from start/reattach. Such bodies are
    /// restricted to discard/reset outcomes everywhere (see
    /// `StaticRangeTrainIntegrityPolicy.adoptedFinishRestriction`).
    private static let deadFinishAdoptedReason = StaticRangeTrainIntegrityPolicy.deadFinishAdoptedReason

    /// I1: build a `RangeTransfer` for a finished background segment task that this session is
    /// tracking in NEITHER lane, so a relaunch/redelivery finish can be lazily adopted through the
    /// normal finished-body path instead of being dropped. Returns `nil` (recording a
    /// `downloads.range_unknown_task_finish` diagnostic) when the task cannot be resolved to a live
    /// static-range row or is not one of our marked segments.
    private func adoptFinishedRangeSegment(task: URLSessionDownloadTask) -> RangeTransfer? {
        let markedOffset = StaticRangeSegmentMarker.parse(task.taskDescription)
        let knownKeys = store.allRatingKeys
        let resolvedKey = Self.ratingKey(for: task, knownKeys: knownKeys)
        func reject(_ reason: String) {
            AppDiagnostics.record(.downloads, "downloads.range_unknown_task_finish", fields: [
                "download_id": .identifier(resolvedKey ?? "unknown"),
                "task_id": .int(task.taskIdentifier),
                "offset": .int(markedOffset ?? -1),
                "reason": .label(reason),
            ])
        }
        guard let markedOffset else { reject("unmarked_task"); return nil }
        guard let ratingKey = resolvedKey else { reject("unknown_row"); return nil }
        guard let record = store.record(for: ratingKey) else {
            reject("no_record"); return nil
        }
        guard StaticRangeRecoveryPolicy.isStaticRangeRecord(record) else {
            reject("not_static_range"); return nil
        }
        guard record.status != .complete, record.status != .failed else {
            reject("terminal_status"); return nil
        }
        // Attempt-token gate: only a current segment stamped with the row's exact attempt
        // may be adopted. An unowned marker or a prior attempt's token means the
        // body is from another rendition/attempt — appending it at offset 0 of a fresh attempt
        // (or pinning its validator) is the F1 silent-corruption path.
        let taskAttemptID = StaticRangeSegmentMarker.attemptIdentity(task.taskDescription)
        guard let taskAttemptID,
              taskAttemptID == record.attemptID else {
            reject(taskAttemptID == nil ? "unowned_marker" : "attempt_mismatch"); return nil
        }
        let http = task.response as? HTTPURLResponse
        // baseOffset: what WE asked for — the REQUEST's Range start (falling back to the marker
        // offset), never the response's Content-Range start. Deriving it from the response made
        // the downstream Content-Range alignment check tautological (the response always "matched"
        // itself), and mislabeled internally-resumed bodies (URLSession re-requests mid-segment,
        // so the response start sits past the segment's true base). The response start stays an
        // INPUT to the alignment/internal-resume checks in the finish path.
        let rangeHeader = (task.originalRequest ?? task.currentRequest)?.value(forHTTPHeaderField: "Range")
        let baseOffset = RangeTransferHTTPPolicy.rangeRequestStart(rangeHeader) ?? markedOffset
        // segmentLength: recover from the closed Range header end bound; fall back to the segment grid.
        let segmentLength: Int? = {
            let start = RangeTransferHTTPPolicy.rangeRequestStart(rangeHeader) ?? baseOffset
            if let end = RangeTransferHTTPPolicy.rangeRequestEnd(rangeHeader), end >= start {
                return end - start + 1
            }
            guard StaticRangeTransferRegime.current == .segmentTrain else { return nil }
            let segBytes = StaticRangeTransferRegime.segmentBytes
            if let expected = BackgroundDownloadProgressPolicy.derivedExpectedBytes(record),
               expected > baseOffset {
                return min(segBytes, expected - baseOffset)
            }
            return segBytes
        }()
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: taskAttemptID)
        guard let destination = store.attemptWorkingFileURL(for: attemptKey) else {
            reject("missing_working_layout"); return nil
        }
        AppDiagnostics.record(.downloads, "downloads.range_dead_finish_adopted", fields: [
            "download_id": .identifier(ratingKey),
            "task_id": .int(task.taskIdentifier),
            "base_offset": .int(baseOffset),
            "segment_length": .int(segmentLength ?? -1),
        ])
        return RangeTransfer(
            ratingKey: ratingKey,
            attemptID: taskAttemptID,
            request: nil,
            destination: destination,
            expectedBytes: BackgroundDownloadProgressPolicy.derivedExpectedBytes(record),
            baseOffset: baseOffset,
            segmentLength: segmentLength,
            responseStatus: http?.statusCode,
            bodyBytesWritten: DownloadLiveRangeProgressPolicy.accountedTaskBodyBytes(
                reportedBytes: Int(task.countOfBytesReceived),
                segmentLength: segmentLength),
            remainderReason: Self.deadFinishAdoptedReason)
    }

    /// Fold a finished Range response body into the durable partial and either finish or request
    /// the next remainder (#169). Runs in the download delegate, off the main actor. The task's
    /// tracking is removed here so the trailing `didCompleteWithError(nil)` is a no-op.
    private func finishRangeRemainder(_ entry: RangeTransfer,
                                  taskIdentifier: Int,
                                  response: URLResponse?,
                                  location: URL) {
        guard stillOwnsAttempt(entry.attemptKey, phase: "range_finish_before_stash") else {
            try? fileManager.removeItem(at: location)
            return
        }
        lock.lock()
        rangeInflight.removeValue(forKey: taskIdentifier)
        loggedProgressMilestones.removeValue(forKey: taskIdentifier)
        lastRangeProgressDiagnostic.removeValue(forKey: taskIdentifier)
        let haltKind = rangeHaltKinds[entry.attemptKey]
        let bodyTrainEpoch = rangeTrainEpochs[entry.attemptKey] ?? 0
        lock.unlock()

        // The row was cancelled or paused while this remainder was finishing. A hard cancel/delete must
        // still discard the temp (the caller may be deleting the partial), but a user/system PAUSE
        // should preserve a just-finished body: otherwise the delegate can finish, then the async
        // append sees the pause halt and silently throws away tens of MB/GB of completed work.
        // The halt KIND recorded at the halt site drives this — the persisted `.paused` status only
        // lands at the end of the async pause chain, far too late for a body finishing mid-pause.
        if StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: haltKind) {
            AppDiagnostics.record(.downloads, "downloads.range_remainder_halted", fields: [
                "download_id": .identifier(entry.ratingKey),
                "offset_bytes": .bytes(entry.baseOffset),
            ])
            markPausedIfHaltStrandedRow(ratingKey: entry.ratingKey)
            return
        }

        // #220: stash the OS temp FIRST — `location` is only guaranteed valid until this delegate
        // returns, and the payload is irreplaceable. Classification, diagnostics, and the write
        // decision all run off the stash; branches that don't want the body delete the stash.
        let stash = rangeBodyStashURL(taskIdentifier: taskIdentifier, offset: entry.baseOffset)
        do {
            try? fileManager.removeItem(at: stash)
            try fileManager.moveItem(at: location, to: stash)
        } catch {
            let statusForDiagnostics = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppDiagnostics.record(.downloads, "downloads.range_stash_move_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "task_id": .int(taskIdentifier),
                "http_status": .int(statusForDiagnostics),
                "base_offset": .int(entry.baseOffset),
                "temp_exists": .bool(fileManager.fileExists(atPath: location.path)),
                "temp_bytes": .int(fileSize(at: location) ?? -1),
                "durable_bytes": .int(fileSize(at: entry.workingURL) ?? -1),
                "error": .error(error),
            ])
            failRangeMove(entry: entry, error: error, stage: "stash_move")
            return
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        AppDiagnostics.record(.downloads, "downloads.range_remainder_finished", fields: [
            "download_id": .identifier(entry.ratingKey),
            "http_status": .int(status),
            "offset_bytes": .bytes(entry.baseOffset),
            "remainder_reason": .label(entry.remainderReason ?? "unknown"),
        ])

        let write = rangeRemainderPolicy.writeDecision(httpStatus: status)
        let adoptedRestriction = StaticRangeTrainIntegrityPolicy.adoptedFinishRestriction(
            remainderReason: entry.remainderReason)
        switch write {
        case .failServer(let code):
            // The response body (for example, an error page) stays in the stash, NEVER appended into
            // the durable partial, so the partial's completed bytes stay intact and resumable.
            try? fileManager.removeItem(at: stash)
            // An UNOWNED (dead-finish-adopted) zombie's 4xx/5xx — e.g. a prior attempt's 404 —
            // must not terminally fail or retry-churn the healthy owned train: discard and
            // reset to the durable checkpoint, nothing else.
            if adoptedRestriction == .discardAndResetOnly {
                guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "unowned_http_failure"
            ) else { return }
                AppDiagnostics.record(.downloads, "downloads.range_unowned_finish_discarded", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "http_status": .int(code),
                    "base_offset": .int(entry.baseOffset),
                    "durable_bytes": .int(durableBytes),
                ])
                onChange?()
                return
            }
            guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "http_failure"
            ) else { return }
            if retryTransientRangeHTTPFailure(statusCode: code,
                                              entry: entry,
                                              durableBytes: durableBytes) {
                return
            }
            if requestRangeRehydrationAfterHTTPFailure(statusCode: code,
                                                       entry: entry,
                                                       durableBytes: durableBytes) {
                return
            }
            // Post-logout casualty: once transient retry + rehydration are exhausted on a 401/403, the
            // remainder may simply be holding a token the user just revoked by signing out. Hand the
            // terminal decision to the manager, which (on the main actor) parks the row in the deferred
            // "waiting for a valid session" state when the backend session is actually gone, or fails
            // it when still signed in (a genuine auth error). The manager owns both terminal paths:
            // `quiesceStaticRangeForDeferredResume` (which resets the exhausted retry/rehydrate budget
            // for a clean rehydration once signed back in) on deferral, or `failStaticRangeAuthTerminal`
            // (which runs the normal purge+supersede+`.failed` teardown, budget intact) on real failure.
            // Do NOT clear the budget here: that reset is intentional only for the deferral path.
            if PostLogoutDownloadFailurePolicy.isDeferrableAuthStatus(code), let onRangeAuthHTTPFailure {
                AppDiagnostics.record(.downloads, "downloads.range_auth_failure_handoff", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "status_code": .int(code),
                    "bytes": .bytes(durableBytes),
                ])
                onRangeAuthHTTPFailure(entry.ratingKey, code, entry.attemptKey)
                onChange?()
                return
            }
            AppDiagnostics.record(.downloads, "downloads.range_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "status_code": .int(code),
                "bytes": .bytes(durableBytes),
            ])
            setFailedPurgingHeldSegments(for: entry.attemptKey)
            onError?(entry.ratingKey, .transferFailed("Server returned HTTP \(code)."))
            onChange?()

        case .alreadyComplete:
            // HTTP 416: the body is a zero-length/error payload — the stash is not needed.
            try? fileManager.removeItem(at: stash)
            // An UNOWNED zombie's 416 must not overwrite sourcePartSize from the OLD part's
            // total, trigger a destructive changed-resource restart, terminally fail the row, or
            // even finalize — reset to the durable checkpoint and let the OWNED train decide.
            if adoptedRestriction == .discardAndResetOnly {
                guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "unowned_already_complete"
            ) else { return }
                AppDiagnostics.record(.downloads, "downloads.range_unowned_finish_discarded", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "http_status": .int(status),
                    "base_offset": .int(entry.baseOffset),
                    "durable_bytes": .int(durableBytes),
                ])
                onChange?()
                return
            }
            // Only "already complete" if the durable partial matches a total we know.
            // Prefer the response's `Content-Range: bytes */TOTAL`; when the server omits it
            // (headset evidence: reattached Plex tasks 416'd with no total and a small legacy
            // bounded body of a 5.9 GB part was finalized straight to `.complete`), fall back to the expected size
            // the transfer was started with. If more bytes exist, keep requesting from the real
            // checkpoint instead of validating a truncated partial.
            let durableBytes = fileSize(at: entry.workingURL) ?? entry.baseOffset
            let contentRangeTotal = RangeTransferHTTPPolicy.contentRangeTotal(from: http)
            if let contentRangeTotal {
                resolveLifecycleSubmission(store.submitSourcePartSize(for: entry.attemptKey, contentRangeTotal))
            }
            let knownTotal = contentRangeTotal
                ?? entry.expectedBytes.flatMap { $0 > 0 ? $0 : nil }
                ?? store.sourceExactBytes(for: entry.attemptKey)
            let effectiveEntry = entry.replacingExpectedBytes(knownTotal ?? entry.expectedBytes)
            if let knownTotal, durableBytes != knownTotal {
                AppDiagnostics.record(.downloads, "downloads.range_416_mismatch", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "durable_bytes": .bytes(durableBytes),
                    "server_total_bytes": .bytes(knownTotal),
                    "total_source": .label(contentRangeTotal != nil ? "content_range" : "expected_bytes"),
                ])
                if durableBytes < knownTotal {
                    if contentRangeTotal != nil {
                        // Server-confirmed total: same continuation semantics as before.
                        continueRangeAfterBody(entry: effectiveEntry, partialSize: durableBytes)
                    } else if !retryRangeOffsetMismatch(entry: effectiveEntry,
                                                        durableBytes: durableBytes,
                                                        serverOffset: nil) {
                        // No server total, only our expected size — and the server keeps 416ing
                        // the checkpoint offset. Bound the retries (offset-mismatch budget) and
                        // then fail retryable, KEEPING the durable partial as the checkpoint,
                        // instead of either looping 416s or finalizing a truncated file.
                        setFailedPurgingHeldSegments(for: entry.attemptKey)
                        onError?(entry.ratingKey, .transferFailed(
                            "Server no longer serves this download's range. Retry to continue."))
                        onChange?()
                    }
                } else {
                    // IC-2 (for real): this is the ONLY caller of the destructive restart that
                    // is not already on `rangeIOQueue` — running it on the delegate queue races
                    // an in-flight apply between its epoch check and its append. Serialize it,
                    // holding the background-completion gate across the hop (mirrors the
                    // append/replace dispatch below).
                    beginPendingBackgroundCompletionOperation()
                    rangeIOQueue.async { [self] in
                        defer { endPendingBackgroundCompletionOperation() }
                        restartRangeFromChangedResource(entry: effectiveEntry)
                    }
                }
                return
            }
            finalizeRangeWhole(entry: effectiveEntry)

        case .append, .replaceWhole:
            // The append/replace must not block the serial delegate queue. The temp is already
            // stashed (a same-volume rename, O(1)) so it survives past this delegate's return;
            // capture the response headers we still need (#169 HIGH 1), then do the heavy IO +
            // continuation decision off-queue.
            let validator = RangeTransferHTTPPolicy.rangeValidator(from: http)
            let contentRangeStart = RangeTransferHTTPPolicy.contentRangeStart(from: http)
            let contentRangeTotal = RangeTransferHTTPPolicy.contentRangeTotal(from: http)
            let contentLength = (http?.expectedContentLength).flatMap { $0 > 0 ? Int($0) : nil }
            beginPendingBackgroundCompletionOperation()
            rangeIOQueue.async { [self] in
                defer { endPendingBackgroundCompletionOperation() }
                applyFinishedRangeBody(entry: entry, write: write, stash: stash,
                                   validator: validator, contentRangeStart: contentRangeStart,
                                   contentRangeTotal: contentRangeTotal,
                                   responseContentLength: contentLength,
                                   bodyTrainEpoch: bodyTrainEpoch)
            }
        }
    }

    /// Off-queue (on `rangeIOQueue`) tail of `finishRangeRemainder`: fold the stashed response
    /// body into the durable partial and either finalize or request the next remainder. Validates the resource hasn't
    /// shifted under us before appending (#169 HIGH 1).
    private func applyFinishedRangeBody(entry: RangeTransfer, write: StaticRangeBodyWrite, stash: URL,
                                    validator: String?, contentRangeStart: Int?,
                                    contentRangeTotal: Int?, responseContentLength: Int?,
                                    bodyTrainEpoch: Int) {
        guard stillOwnsAttempt(entry.attemptKey, phase: "range_apply") else {
            try? fileManager.removeItem(at: stash)
            return
        }
        // B.2/B.3(b): the train may have been torn down (changed-resource restart, adopted
        // whole-file 200) between this body's delegate finish and this off-queue apply. A stale
        // body must be discarded outright: appending would splice bytes from the previous resource
        // version, and re-running the validator checks against the new pin would destructively
        // restart over the replacement file.
        lock.lock()
        let currentTrainEpoch = rangeTrainEpochs[entry.attemptKey] ?? 0
        lock.unlock()
        if !StaticRangeTrainIntegrityPolicy.shouldProcessFinishedBody(
            bodyTrainEpoch: bodyTrainEpoch, currentTrainEpoch: currentTrainEpoch) {
            try? fileManager.removeItem(at: stash)
            AppDiagnostics.record(.downloads, "downloads.range_stale_train_body_ignored", fields: [
                "download_id": .identifier(entry.ratingKey),
                "base_offset": .int(entry.baseOffset),
                "body_epoch": .int(bodyTrainEpoch),
                "train_epoch": .int(currentTrainEpoch),
            ])
            return
        }
        let unowned = StaticRangeTrainIntegrityPolicy.adoptedFinishRestriction(
            remainderReason: entry.remainderReason) == .discardAndResetOnly
        if let contentRangeTotal {
            // An unowned body's Content-Range total may describe a prior attempt's part — it
            // must not overwrite an owned size (see the didWriteData twin of this gate).
            if unowned {
                resolveLifecycleSubmission(store.submitSourcePartSizeIfMissing(for: entry.attemptKey, contentRangeTotal))
            } else {
                resolveLifecycleSubmission(store.submitSourcePartSize(for: entry.attemptKey, contentRangeTotal))
            }
        }
        let effectiveExpectedBytes = contentRangeTotal ?? entry.expectedBytes
        let entry = entry.replacingExpectedBytes(effectiveExpectedBytes)
        // A cancel/pause may have landed during the delegate→IO hop. The halt KIND (recorded at
        // the halt site) decides: pause preserves the finished body, cancel discards it.
        lock.lock(); let haltKind = rangeHaltKinds[entry.attemptKey]; lock.unlock()
        let finishedBodyDisposition = StaticRangeFinishedBodyPolicy.disposition(haltKind: haltKind)
        if finishedBodyDisposition == .discardTemp {
            let stashBytes = fileSize(at: stash)
            try? fileManager.removeItem(at: stash)
            AppDiagnostics.record(.downloads, "downloads.range_halted_remainder_discarded", fields: [
                "download_id": .identifier(entry.ratingKey),
                "base_offset": .int(entry.baseOffset),
                "body_bytes": .int(stashBytes ?? -1),
            ])
            markPausedIfHaltStrandedRow(ratingKey: entry.ratingKey)
            return
        }
        let durableBytesBeforeWrite = fileSize(at: entry.workingURL) ?? 0
        if durableBytesBeforeWrite > entry.baseOffset {
            let stashBytes = fileSize(at: stash)
            try? fileManager.removeItem(at: stash)
            AppDiagnostics.record(.downloads, "downloads.range_stale_remainder_ignored", fields: [
                "download_id": .identifier(entry.ratingKey),
                "base_offset": .int(entry.baseOffset),
                "durable_bytes": .int(durableBytesBeforeWrite),
                "body_bytes": .int(stashBytes ?? -1),
                "reason": .label("durable_checkpoint_ahead"),
            ])
            onChange?()
            // The discard freed a train slot; without a top-up the row idles at reduced depth (or
            // fully idle) until the stall watchdog notices. Owned bodies only — an unowned
            // (dead-finish-adopted) body is restricted to discard/reset and must not start work.
            if !unowned {
                continueRangeAfterBody(entry: entry, partialSize: durableBytesBeforeWrite)
            }
            return
        }

        // NEW-1: an UNOWNED body (lazily adopted dead-finish) gets NO validator tolerance.
        // `supersededRangeTaskIdentifiers` is in-memory, so after a relaunch a zombie segment
        // from a CANCELLED prior attempt of the same key can pass the adoption guards. It may be
        // applied ONLY when a validator is already pinned AND matches exactly: it must never PIN
        // a validator itself (a fresh attempt at durable 0 — or right after a restart cleared
        // the pin — would adopt the OLD attempt's validator), gets no absent-validator
        // tolerance, and a mismatch discards the body instead of restarting the owned partial
        // (if the resource truly changed, the next OWNED body triggers the restart legitimately).
        if unowned,
           case .discard(let reason) = StaticRangeTrainIntegrityPolicy.unownedBodyValidatorDecision(
               storedValidator: store.rangeValidator(for: entry.attemptKey),
               responseValidator: validator) {
            try? fileManager.removeItem(at: stash)
            guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "unowned_validator"
            ) else { return }
            AppDiagnostics.record(.downloads, "downloads.range_unknown_task_finish", fields: [
                "download_id": .identifier(entry.ratingKey),
                "offset": .int(entry.baseOffset),
                "reason": .label(reason),
                "durable_bytes": .int(durableBytes),
            ])
            onChange?()
            return
        }

        switch write {
        case .replaceWhole:
            // HTTP 200: the server sent the whole CURRENT resource — replace the partial honestly
            // rather than appending real bytes after a stale prefix. But only if the body is
            // plausibly whole (#220): a truncated 200 must not clobber a good partial checkpoint.
            let stashBytes = fileSize(at: stash)
            guard RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody(
                stashBytes: stashBytes,
                expectedBytes: entry.expectedBytes,
                storedValidator: store.rangeValidator(for: entry.attemptKey),
                responseValidator: validator,
                responseContentLength: responseContentLength
            ) else {
                try? fileManager.removeItem(at: stash)
                guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "replace_whole_size"
            ) else { return }
                AppDiagnostics.record(.downloads, "downloads.range_200_size_mismatch", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "body_bytes": .int(stashBytes ?? -1),
                    "expected_bytes": .int(entry.expectedBytes ?? -1),
                    "durable_bytes": .int(durableBytes),
                ])
                if retryRangeOffsetMismatch(entry: entry,
                                            durableBytes: durableBytes,
                                            serverOffset: nil) {
                    return
                }
                setFailedPurgingHeldSegments(for: entry.attemptKey)
                onError?(entry.ratingKey, .transferFailed(
                    "Server returned an incomplete full-file response for a ranged request."))
                onChange?()
                return
            }
            do {
                try? fileManager.removeItem(at: entry.workingURL)
                try fileManager.moveItem(at: stash, to: entry.workingURL)
            } catch {
                try? fileManager.removeItem(at: stash)
                failRangeMove(entry: entry, error: error, stage: "replace_whole")
                return
            }
            if let validator { resolveLifecycleSubmission(store.submitRangeValidator(for: entry.attemptKey, validator)) }
            // C2: the HTTP 200 body just replaced the whole partial with the current resource; any
            // held ranged-segment stashes are now stale and must not be appended onto it.
            // B.3(b): the same goes for every in-flight sibling segment — supersede and cancel the
            // whole train and advance its epoch, or a late tail segment (baseOffset beyond the new
            // file's size) would hit the held path, mismatch the freshly pinned 200 validator, and
            // destructively restart over the file the finalize below is completing.
            purgeHeldRangeSegments(for: entry.attemptKey)
            lock.lock()
            let supersededSiblings = supersedeRangeTasksLocked(ratingKey: entry.ratingKey)
            rangeTrainEpochs[entry.attemptKey] = (rangeTrainEpochs[entry.attemptKey] ?? 0) + 1
            retryCounts.removeValue(forKey: entry.attemptKey)
            rangeHTTPRehydrateCounts.removeValue(forKey: entry.attemptKey)
            lock.unlock()
            for identifier in supersededSiblings {
                cancelURLSessionTask(identifier: identifier)
            }
            if !supersededSiblings.isEmpty {
                AppDiagnostics.record(.downloads, "downloads.range_train_superseded", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "superseded_task_count": .int(supersededSiblings.count),
                    "reason": .label("replace_whole_adopted"),
                ])
            }
            if finishedBodyDisposition == .writeThenPause {
                let bytes = fileSize(at: entry.workingURL) ?? 0
                _ = resolveLifecycleSubmission(store.submitProgress(for: entry.attemptKey,
                                     bytes: bytes,
                                     progress: (entry.expectedBytes ?? 0) > 0
                                        ? min(1, Double(bytes) / Double(entry.expectedBytes!)) : 0))
                AppDiagnostics.record(.downloads, "downloads.range_halted_remainder_preserved", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "base_offset": .int(entry.baseOffset),
                    "partial_bytes": .int(bytes),
                    "write": .label("replaceWhole"),
                ])
                _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .paused))
                onChange?()
                return
            }
            finalizeRangeWhole(entry: entry)

        case .append:
            let durableBytesBeforeAppend = durableBytesBeforeWrite
            if durableBytesBeforeAppend < entry.baseOffset {
                if entry.segmentLength != nil {
                    // C1: an out-of-order held body must clear the SAME validator + Content-Range
                    // checks an in-order body does BEFORE it is stashed. Otherwise a changed resource
                    // or a misaligned 206 is stashed now and blindly folded in later at drain time,
                    // reintroducing exactly the corruption #169 HIGH 1 / the offset guard prevent.
                    // A held segment always sits at baseOffset > 0 (durable < baseOffset).
                    // 1. Validator changed underneath us → the changed-resource restart path.
                    // B.2: when nothing is pinned yet (initial train start, or the restart cleared
                    // it), the FIRST arriving body pins the validator — head or held — so a held
                    // body can never be stashed version-unchecked in that window.
                    switch StaticRangeTrainIntegrityPolicy.arrivingBodyDecision(
                        storedValidator: store.rangeValidator(for: entry.attemptKey),
                        responseValidator: validator
                    ) {
                    case .restartChangedResource:
                        try? fileManager.removeItem(at: stash)
                        restartRangeFromChangedResource(entry: entry)
                        return
                    case .pinAndProceed(let pinned):
                        resolveLifecycleSubmission(store.submitRangeValidator(for: entry.attemptKey, pinned))
                    case .proceed:
                        break
                    }
                    // 2. Content-Range must begin exactly at this segment's baseOffset; anything else
                    // takes the existing offset-mismatch handling rather than stashing an unappendable
                    // body — EXCEPT the internal-resume escape the in-order path also has (lens 2
                    // F1): URLSession can transparently resume a blob-resumed segment mid-body, so
                    // the response reports a later server offset while the assembled temp holds the
                    // FULL segment from `baseOffset`. Rejecting that complete body burns
                    // offset-mismatch budget on a healthy train (repeated blips terminally fail it).
                    // The escape holds the stash at the segment's own baseOffset with its actual
                    // length, exactly like an aligned body.
                    let heldStashBytes = fileSize(at: stash)
                    if contentRangeStart != entry.baseOffset,
                       RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeBody(
                           baseOffset: entry.baseOffset,
                           contentRangeStart: contentRangeStart,
                           stashBytes: heldStashBytes,
                           expectedBodyBytes: expectedRangeBodyBytes(entry: entry)
                       ) {
                        AppDiagnostics.record(.downloads, "downloads.range_internal_resume_adopted", fields: [
                            "download_id": .identifier(entry.ratingKey),
                            "expected_offset": .bytes(entry.baseOffset),
                            "expected_offset_exact": .int(entry.baseOffset),
                            "server_offset": .bytes(contentRangeStart),
                            "server_offset_exact": .int(contentRangeStart ?? -1),
                            "stash_bytes": .bytes(heldStashBytes),
                            "stash_bytes_exact": .int(heldStashBytes ?? -1),
                            "expected_body_bytes": .int(expectedRangeBodyBytes(entry: entry) ?? -1),
                            "held": .bool(true),
                        ])
                    } else if contentRangeStart != entry.baseOffset {
                        try? fileManager.removeItem(at: stash)
                        guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "held_offset_mismatch"
            ) else { return }
                        AppDiagnostics.record(.downloads, "downloads.range_offset_mismatch", fields: [
                            "download_id": .identifier(entry.ratingKey),
                            "expected_offset": .bytes(entry.baseOffset),
                            "expected_offset_exact": .int(entry.baseOffset),
                            "server_offset": .bytes(contentRangeStart),
                            "server_offset_exact": .int(contentRangeStart ?? -1),
                            "bytes": .bytes(durableBytes),
                            "bytes_exact": .int(durableBytes),
                            "held": .bool(true),
                        ])
                        if retryRangeOffsetMismatch(entry: entry, durableBytes: durableBytes, serverOffset: contentRangeStart) {
                            return
                        }
                        setFailedPurgingHeldSegments(for: entry.attemptKey)
                        onError?(entry.ratingKey, .transferFailed("Server returned a misaligned byte range."))
                        onChange?()
                        return
                    }
                    // M1: a zero-length/unreadable stash can never append at its offset (the assembly
                    // policy classifies it discard forever) — reject it up front so it can't wedge the
                    // drain or leak a temp. Treat it like a discard and top the train up.
                    let stashLen = fileSize(at: stash) ?? 0
                    if stashLen <= 0 {
                        try? fileManager.removeItem(at: stash)
                        AppDiagnostics.record(.downloads, "downloads.range_segment_held_discarded", fields: [
                            "download_id": .identifier(entry.ratingKey),
                            "base_offset": .int(entry.baseOffset),
                            "reason": .label("empty_stash"),
                        ])
                        onChange?()
                        continueRangeAfterBody(entry: entry, partialSize: durableBytesBeforeAppend)
                        return
                    }
                    let stableHeldURL = store.heldRangeSegmentDestinationURL(
                        ratingKey: entry.ratingKey, offset: entry.baseOffset)
                    guard let durableStash = store.attemptStagingURL(
                        for: entry.attemptKey, stableURL: stableHeldURL) else {
                        try? fileManager.removeItem(at: stash)
                        failRangeMove(entry: entry, error: CocoaError(.fileWriteInvalidFileName),
                                      stage: "held_attempt_layout")
                        return
                    }
                    do {
                        try fileManager.moveItem(at: stash, to: durableStash)
                    } catch {
                        try? fileManager.removeItem(at: stash)
                        AppDiagnostics.record(.downloads, "downloads.range_held_persist_failed", fields: [
                            "download_id": .identifier(entry.ratingKey),
                            "base_offset": .int(entry.baseOffset),
                            "stage": .label("durable_move"),
                            "error": .error(error),
                        ])
                        continueRangeAfterBody(entry: entry, partialSize: durableBytesBeforeAppend)
                        return
                    }
                    let manifest = OfflineHeldRangeSegment(
                        offset: entry.baseOffset,
                        length: stashLen,
                        validator: validator,
                        relativePath: durableStash.lastPathComponent,
                        attemptID: entry.attemptID.rawValue
                    )
                    lock.lock()
                    var predecessorURLs = Set<URL>()
                    if let current = heldRangeSegments[entry.attemptKey]?[entry.baseOffset]?.url {
                        predecessorURLs.insert(current)
                    }
                    predecessorURLs.formUnion(
                        heldRangeRetainedPredecessorURLs[entry.attemptKey]?[entry.baseOffset] ?? [])
                    lock.unlock()
                    let submission = store.submitHeldRangeSegment(
                        for: entry.attemptKey,
                        segment: manifest,
                        deletingRelativePaths: predecessorURLs.map(\.lastPathComponent))
                    guard case .accepted(let accepted) = submission else {
                        try? fileManager.removeItem(at: durableStash)
                        AppDiagnostics.record(.downloads, "downloads.range_held_persist_failed", fields: [
                            "download_id": .identifier(entry.ratingKey),
                            "base_offset": .int(entry.baseOffset),
                            "stage": .label("manifest_submission"),
                        ])
                        continueRangeAfterBody(entry: entry, partialSize: durableBytesBeforeAppend)
                        return
                    }
                    // #212 (the decisive half of the off-head stall): the caller's gate operation
                    // ends when `applyFinishedRangeBody` returns, but the train slot is refilled
                    // (or the rebuild-grace hold established) only inside the async lifecycle
                    // completion below. Begin a nested gate operation NOW — while the outer one is
                    // still open — and end it inside the completion on every branch, so the gate
                    // can never hit zero (letting the OS suspend a background wake) in between.
                    beginPendingBackgroundCompletionOperation()
                    resolveHeldLifecycle(accepted.ticket) { [weak self] outcome in
                        guard let self else { return }
                        defer { self.endPendingBackgroundCompletionOperation() }
                        switch outcome {
                        case .completed:
                            self.lock.lock()
                            let halt = self.rangeHaltKinds[entry.attemptKey]
                            guard halt == nil, self.store.ownsAttempt(entry.attemptKey) else {
                                self.lock.unlock()
                                _ = self.store.submitHeldRangeSegmentsRemoval(
                                    for: entry.attemptKey,
                                    offsets: [entry.baseOffset],
                                    deletingRelativePaths: [durableStash.lastPathComponent])
                                return
                            }
                            self.heldRangeSegments[entry.attemptKey, default: [:]][entry.baseOffset] =
                                (url: durableStash, length: stashLen, validator: validator)
                            self.heldRangeRetainedPredecessorURLs[entry.attemptKey]?.removeValue(
                                forKey: entry.baseOffset)
                            self.staticRangeRetryBudget.resetOffsetMismatch(
                                key: self.staticRangeRetryKey(for: entry.attemptKey),
                                segmentOffset: entry.baseOffset)
                            self.lock.unlock()
                            AppDiagnostics.record(.downloads, "downloads.range_segment_held", fields: [
                                "download_id": .identifier(entry.ratingKey),
                                "base_offset": .int(entry.baseOffset),
                                "durable_bytes": .int(durableBytesBeforeAppend),
                                "body_bytes": .int(stashLen),
                                "manifest_committed": .bool(true),
                            ])
                            self.onChange?()
                            self.continueRangeAfterBody(
                                entry: entry, partialSize: durableBytesBeforeAppend)
                        case .failed, .timedOut:
                            AppDiagnostics.record(.downloads, "downloads.range_held_persist_failed", fields: [
                                "download_id": .identifier(entry.ratingKey),
                                "base_offset": .int(entry.baseOffset),
                                "stage": .label("manifest_lifecycle"),
                            ])
                            self.onChange?()
                            // The task slot is free even though durability remains retryable. Replan
                            // from the unchanged durable checkpoint rather than silently consuming
                            // the slot forever; duplicate work is attempt-scoped and bounded.
                            self.continueRangeAfterBody(
                                entry: entry, partialSize: durableBytesBeforeAppend)
                        }
                    }
                    return
                }
                try? fileManager.removeItem(at: stash)
                AppDiagnostics.record(.downloads, "downloads.range_durable_offset_gap", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "base_offset": .int(entry.baseOffset),
                    "durable_bytes": .int(durableBytesBeforeAppend),
                    "server_offset": .int(contentRangeStart ?? -1),
                ])
                if retryRangeOffsetMismatch(entry: entry,
                                            durableBytes: durableBytesBeforeAppend,
                                            serverOffset: contentRangeStart) {
                    return
                }
                setFailedPurgingHeldSegments(for: entry.attemptKey)
                onError?(entry.ratingKey, .transferFailed("Download checkpoint no longer matches the finished byte range."))
                onChange?()
                return
            }
            // #169 HIGH 1, primary defense: Plex (the main backend) IGNORES `If-Range` — it returns a
            // 206 from the SAME offset even for a non-matching validator (probed live, deterministic),
            // so we cannot rely on the server downgrading a changed resource to 200. Instead COMPARE
            // the response body's validator against the pinned validator; a definite mismatch means
            // the resource changed underneath us. The body is a middle slice from `baseOffset` (not the
            // whole file), so we can neither append (splices new bytes after a stale prefix → the exact
            // corruption HIGH 1 targets) nor `replaceWhole` — we discard the stale partial and restart
            // from 0. Only act on a present-and-different validator: a nil/absent one (transient header
            // omission) must not trigger a restart loop. Emby/JF still also get the `If-Range` 200 path.
            // B.2: like the held path, the first arriving body pins the validator when none is
            // stored yet, so every sibling — regardless of arrival order — is verified against it.
            switch StaticRangeTrainIntegrityPolicy.arrivingBodyDecision(
                storedValidator: store.rangeValidator(for: entry.attemptKey),
                responseValidator: validator
            ) {
            case .restartChangedResource:
                restartRangeFromChangedResource(entry: entry)
                try? fileManager.removeItem(at: stash)
                return
            case .pinAndProceed(let pinned):
                resolveLifecycleSubmission(store.submitRangeValidator(for: entry.attemptKey, pinned))
            case .proceed:
                break
            }
            // HTTP 206 must start exactly at our durable offset. A changed resource returns 200
            // (handled above, via the `If-Range` we send); a 206 whose `Content-Range` start differs
            // from `baseOffset` — or, at a non-zero offset, omits `Content-Range` entirely (a
            // non-compliant proxy we can't trust to have honored our `Range`) — is refused rather than
            // appended blindly. At offset 0 a missing `Content-Range` is fine (append onto empty).
            let stashBytesBeforeAppend = fileSize(at: stash)
            let misaligned = entry.baseOffset > 0
                ? contentRangeStart != entry.baseOffset            // nil (absent) or wrong → reject
                : (contentRangeStart.map { $0 != 0 } ?? false)     // offset 0: reject only a stated non-zero start
            if misaligned, RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeBody(
                baseOffset: entry.baseOffset,
                contentRangeStart: contentRangeStart,
                stashBytes: stashBytesBeforeAppend,
                expectedBodyBytes: expectedRangeBodyBytes(entry: entry)
            ) {
                AppDiagnostics.record(.downloads, "downloads.range_internal_resume_adopted", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "expected_offset": .bytes(entry.baseOffset),
                    "expected_offset_exact": .int(entry.baseOffset),
                    "server_offset": .bytes(contentRangeStart),
                    "server_offset_exact": .int(contentRangeStart ?? -1),
                    "stash_bytes": .bytes(stashBytesBeforeAppend),
                    "stash_bytes_exact": .int(stashBytesBeforeAppend ?? -1),
                    "expected_body_bytes": .int(expectedRangeBodyBytes(entry: entry) ?? -1),
                ])
            } else if misaligned {
                try? fileManager.removeItem(at: stash)
                guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "offset_mismatch"
            ) else { return }
                AppDiagnostics.record(.downloads, "downloads.range_offset_mismatch", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "expected_offset": .bytes(entry.baseOffset),
                    "expected_offset_exact": .int(entry.baseOffset),
                    "server_offset": .bytes(contentRangeStart),
                    "server_offset_exact": .int(contentRangeStart ?? -1),
                    "bytes": .bytes(durableBytes),
                    "bytes_exact": .int(durableBytes),
                ])
                if retryRangeOffsetMismatch(entry: entry, durableBytes: durableBytes, serverOffset: contentRangeStart) {
                    return
                }
                setFailedPurgingHeldSegments(for: entry.attemptKey)
                onError?(entry.ratingKey, .transferFailed("Server returned a misaligned byte range."))
                onChange?()
                return
            }
            // IC-2: re-check the train epoch AND the on-disk size at the last instant. A
            // 416-triggered changed-resource restart runs on the DELEGATE queue and can tear the
            // train down (epoch++, file deleted) between this apply's entry epoch check and here;
            // appending after that writes this mid-file segment at offset 0 of the recreated file.
            // Size FIRST, epoch SECOND: a restart landing between the two reads then trips the
            // epoch check, so a SAME-epoch size drift is a true invariant violation (durable
            // bytes are monotonic within a train generation) — assertable below.
            let durableBytesAtAppend = fileSize(at: entry.workingURL) ?? 0
            lock.lock()
            let epochAtAppend = rangeTrainEpochs[entry.attemptKey] ?? 0
            lock.unlock()
            switch StaticRangeTrainIntegrityPolicy.preAppendDecision(
                bodyTrainEpoch: bodyTrainEpoch,
                currentTrainEpoch: epochAtAppend,
                durableBytes: durableBytesAtAppend,
                baseOffset: entry.baseOffset
            ) {
            case .append:
                break
            case .discardStaleTrain:
                try? fileManager.removeItem(at: stash)
                AppDiagnostics.record(.downloads, "downloads.range_stale_train_body_ignored", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "base_offset": .int(entry.baseOffset),
                    "body_epoch": .int(bodyTrainEpoch),
                    "train_epoch": .int(epochAtAppend),
                    "stage": .label("pre_append"),
                ])
                return
            case .discardOffsetDrift:
                assertionFailure(
                    "range pre-append drift: durable=\(durableBytesAtAppend) "
                    + "baseOffset=\(entry.baseOffset) — durable bytes moved within a train generation")
                try? fileManager.removeItem(at: stash)
                AppDiagnostics.record(.downloads, "downloads.range_pre_append_drift", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "base_offset": .int(entry.baseOffset),
                    "durable_bytes": .int(durableBytesAtAppend),
                ])
                continueRangeAfterBody(entry: entry, partialSize: durableBytesAtAppend)
                return
            }
            let bodyBytes: Int
            do {
                bodyBytes = try appendFile(at: stash, onto: entry.workingURL)
            } catch {
                try? fileManager.removeItem(at: stash)
                failRangeMove(entry: entry, error: error, stage: "append")
                return
            }
            try? fileManager.removeItem(at: stash)
            // Forward progress: this response body's validator matched, so the resource is stable again — clear
            // the consecutive validator-change restart counter (#169 HIGH 1 livelock bound).
            lock.lock()
            retryCounts.removeValue(forKey: entry.attemptKey)
            staticRangeRetryBudget.reset(key: staticRangeRetryKey(for: entry.attemptKey))
            rangeHTTPRehydrateCounts.removeValue(forKey: entry.attemptKey)
            rangeBlobResumeCounts.removeValue(forKey: entry.attemptKey)
            lock.unlock()
            // The FIRST body carrying a validator already pinned it above (arrivingBodyDecision),
            // so later requests send `If-Range`. Only the never-pinned case is left to record.
            if validator == nil, entry.baseOffset == 0,
               store.rangeValidator(for: entry.attemptKey) == nil {
                // No usable strong validator: subsequent requests can't send `If-Range`, so a resource
                // that changes mid-download would be appended unprotected. Record it so the
                // unprotected case is observable rather than silent (#169 MEDIUM 1).
                AppDiagnostics.record(.downloads, "downloads.range_validator_absent", fields: [
                    "download_id": .identifier(entry.ratingKey),
                ])
            }
            let partialSize = fileSize(at: entry.workingURL) ?? (entry.baseOffset + bodyBytes)
            _ = resolveLifecycleSubmission(store.submitProgress(for: entry.attemptKey,
                                 bytes: partialSize,
                                 progress: (entry.expectedBytes ?? 0) > 0
                                    ? min(1, Double(partialSize) / Double(entry.expectedBytes!)) : 0))
            let drainedPartial = drainHeldRangeSegments(
                for: entry.attemptKey,
                destination: entry.workingURL,
                expectedBytes: entry.expectedBytes)
            let partialSizeAfterDrain = max(partialSize, drainedPartial)
            AppDiagnostics.record(.downloads, "downloads.range_remainder_appended", fields: [
                "download_id": .identifier(entry.ratingKey),
                "base_offset": .int(entry.baseOffset),
                "body_bytes": .int(bodyBytes),
                "partial_bytes": .int(partialSize),
                "expected_exact": .int(entry.expectedBytes ?? -1),
            ])

            if finishedBodyDisposition == .writeThenPause {
                AppDiagnostics.record(.downloads, "downloads.range_halted_remainder_preserved", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "base_offset": .int(entry.baseOffset),
                    "body_bytes": .int(bodyBytes),
                    "partial_bytes": .int(partialSize),
                    "write": .label("append"),
                ])
                // `updateProgress` promotes paused rows to `.downloading` because a normal append is
                // live work. This append, however, is the tail of a pause race: preserve the bytes but
                // do not start the next request behind the user's/system's pause.
                _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .paused))
                onChange?()
                return
            }

            switch rangeRemainderPolicy.nextStep(partialSize: partialSizeAfterDrain,
                                                  expectedBytes: entry.expectedBytes,
                                                  bodyBytes: bodyBytes) {
            case .complete:
                finalizeRangeWhole(entry: entry)
            case .stalled:
                AppDiagnostics.record(.downloads, "downloads.range_incomplete", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "bytes": .bytes(partialSize),
                    "expected_bytes": .bytes(entry.expectedBytes),
                ])
                setFailedPurgingHeldSegments(for: entry.attemptKey)
                onError?(entry.ratingKey, .transferFailed("Download stalled with no progress."))
                onChange?()
            case .continueFrom:
                continueRangeAfterBody(entry: entry, partialSize: partialSizeAfterDrain)
            }

        case .failServer, .alreadyComplete:
            break // resolved inline in finishRangeRemainder; never offloaded
        }
    }

    /// IC-1: a finished body discarded behind a halt writes no status itself, and the pause's
    /// `getAllTasks` sweep can miss the whole exchange — the finished task is no longer live, and
    /// a continuation task started inside the snapshot window is a "replacement" that makes
    /// `pauseStillApplies` skip the paused write. The row then strands as `.downloading` with
    /// zero live tasks and a halted lane. Settle it here: when the lane is halted, no task is
    /// tracked for the row, and it still claims live work, park it `.paused` (the durable partial
    /// stays the checkpoint). A cancel/delete halt has no row left, so this no-ops there.
    private func markPausedIfHaltStrandedRow(ratingKey: String) {
        guard let attemptID = currentAttemptIdentity(ratingKey: ratingKey) else { return }
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard store.ownsAttempt(key) else { return }
        lock.lock()
        let halted = rangeHaltKinds[key] != nil
        let hasLiveTask = inflight.values.contains { $0.ratingKey == ratingKey }
            || rangeInflight.values.contains { $0.ratingKey == ratingKey }
        lock.unlock()
        guard halted, !hasLiveTask else { return }
        let status = store.record(for: key)?.status
        guard status == .downloading || status == .queued else { return }
        guard acceptedAttemptSubmission(resolveLifecycleSubmission(store.submitStatus(for: key, .paused)),
                                      key: key, phase: "halt_stranded_pause") else { return }
        onChange?()
    }

    private func rangeBodyStashURL(taskIdentifier: Int, offset: Int) -> URL {
        // The OS background temp and our temporaryDirectory share the app-container volume, so the
        // stash move is an O(1) rename. Unique per task id (unique within a session) and deleted
        // after the append/replace consumes it.
        fileManager.temporaryDirectory.appendingPathComponent("vp-range-body-\(taskIdentifier)-o\(offset)")
    }

    private func removeRangeBodyStashes(taskIdentifier: Int) {
        let tmp = fileManager.temporaryDirectory
        let prefix = "vp-range-body-\(taskIdentifier)"
        if let entries = try? fileManager.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for url in entries where url.lastPathComponent == prefix || url.lastPathComponent.hasPrefix(prefix + "-o") {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func removeHeldRangeSegment(
        for key: DownloadAttemptKey,
        offset: Int,
        fallbackURL: URL? = nil,
        fallbackURLs: Set<URL> = []
    ) {
        removeHeldRangeSegments(
            for: key,
            segments: [(offset: offset, fallbackURL: fallbackURL)],
            fallbackURLsByOffset: fallbackURLs.isEmpty ? [:] : [offset: fallbackURLs]
        )
    }

    /// Batch removal: one manifest persist for a whole discard set, instead of a full index
    /// rewrite per segment. Retained replacement generations remain owned per offset.
    @discardableResult
    private func removeHeldRangeSegments(
        for key: DownloadAttemptKey,
        segments: [(offset: Int, fallbackURL: URL?)],
        fallbackURLsByOffset: [Int: Set<URL>] = [:]
    ) -> Bool {
        guard !segments.isEmpty else { return true }
        // Snapshot every same-attempt generation before staging the manifest removal. The Store
        // commits these paths as deferred deletion authority in the SAME row revision, so an index
        // failure retains both manifest/body and a later commit/relaunch can finish idempotently.
        lock.lock()
        var candidateURLs = Set<URL>()
        for segment in segments {
            if let current = heldRangeSegments[key]?[segment.offset]?.url {
                candidateURLs.insert(current)
            }
            candidateURLs.formUnion(
                heldRangeRetainedPredecessorURLs[key]?[segment.offset] ?? [])
            if let fallbackURL = segment.fallbackURL { candidateURLs.insert(fallbackURL) }
            candidateURLs.formUnion(fallbackURLsByOffset[segment.offset] ?? [])
        }
        lock.unlock()
        guard case .accepted(let removal) = store.submitHeldRangeSegmentsRemoval(
            for: key,
            offsets: segments.map(\.offset),
            deletingRelativePaths: candidateURLs.map(\.lastPathComponent)) else { return false }
        resolveHeldLifecycle(removal.ticket) { [weak self] outcome in
            guard let self, outcome == .completed else { return }
            self.lock.lock()
            for segment in segments {
                self.heldRangeSegments[key]?.removeValue(forKey: segment.offset)
                self.heldRangeRetainedPredecessorURLs[key]?.removeValue(forKey: segment.offset)
            }
            if self.heldRangeRetainedPredecessorURLs[key]?.isEmpty == true {
                self.heldRangeRetainedPredecessorURLs.removeValue(forKey: key)
            }
            self.lock.unlock()
            if let destination = self.store.attemptWorkingFileURL(for: key) {
                _ = self.drainHeldRangeSegments(
                    for: key,
                    destination: destination,
                    expectedBytes: self.store.sourceExactBytes(for: key))
            }
        }
        // The caller must stop this synchronous drain pass; a later range event/retry observes the
        // terminally-cleared map. Returning true would append/delete ahead of lifecycle durability.
        return false
    }

    private func recordUncommittedHeldManifestRemoval(
        ratingKey: String,
        operation: String,
        persistence: DownloadStore.PersistenceFlushResult
    ) {
        let outcome: String
        switch persistence {
        case .committed:
            outcome = "revision_mismatch"
        case .failed(_, let stage, _):
            outcome = "failed_\(stage)"
        case .timedOut:
            outcome = "timed_out"
        }
        AppDiagnostics.record(.downloads, "downloads.range_held_manifest_remove_uncommitted", fields: [
            "download_id": .identifier(ratingKey),
            "operation": .label(operation),
            "outcome": .label(outcome),
            "body_disposition": .label("retained_for_durable_retry"),
        ])
    }

    /// Fold any held out-of-order segments that are now contiguous with the durable checkpoint.
    /// Returns the new durable size. Alignment is the assembly policy's exact-offset contiguity
    /// guarantee (Content-Range was verified at hold time); version consistency is re-checked here
    /// against the pinned validator recorded with each stash (B.2) — the pin can move between hold
    /// and drain (restart, replaceWhole), and a stale-version body must be dropped so the planner
    /// re-fetches the hole instead of splicing bytes from two file versions.
    @discardableResult
    private func drainHeldRangeSegments(for key: DownloadAttemptKey,
                                        destination: URL, expectedBytes: Int?) -> Int {
        let ratingKey = key.ratingKey
        var durable = fileSize(at: destination) ?? 0
        let storedValidator = store.rangeValidator(for: key)
        while true {
            lock.lock()
            let haltKind = rangeHaltKinds[key]
            let held = heldRangeSegments[key] ?? [:]
            lock.unlock()
            guard haltKind == nil else {
                settleHeldRangeDrainHalt(for: key, haltKind: haltKind!, durableBytes: durable,
                                         expectedBytes: expectedBytes, publishProgress: false)
                break
            }
            let stashed = held.map { (offset: $0.key, length: $0.value.length) }
            let run = StaticRangeSegmentAssemblyPolicy.appendableRun(durableBytes: durable, stashedSegments: stashed)
            guard removeHeldRangeSegments(
                for: key,
                segments: run.discard.map { ($0.offset, held[$0.offset]?.url) }
            ) else { break }
            guard let next = run.append.first, let entry = held[next.offset] else { break }
            if StaticRangeTrainIntegrityPolicy.heldSpliceDecision(
                storedValidator: storedValidator,
                heldValidator: entry.validator
            ) == .discardChangedResource {
                guard removeHeldRangeSegments(
                    for: key,
                    segments: [(offset: next.offset, fallbackURL: entry.url)]
                ) else {
                    AppDiagnostics.record(.downloads, "downloads.range_segment_discard_deferred", fields: [
                        "download_id": .identifier(ratingKey),
                        "base_offset": .int(next.offset),
                        "reason": .label("manifest_persistence_failed"),
                    ])
                    break
                }
                AppDiagnostics.record(.downloads, "downloads.range_segment_held_discarded", fields: [
                    "download_id": .identifier(ratingKey),
                    "base_offset": .int(next.offset),
                    "reason": .label("validator_mismatch_at_drain"),
                ])
                continue
            }
            // Re-verify on-disk alignment before appending.
            let onDisk = fileSize(at: destination) ?? 0
            guard onDisk == next.offset else { break }
            #if DEBUG
            if let delayed = DebugDownloadFaultURLProtocol.delayHeldDrainIfConfigured() {
                AppDiagnostics.record(.downloads, "downloads.fault_injected", fields: [
                    "scenario": .label(delayed.scenario),
                    "stage": .label("held_drain"),
                    "step": .int(delayed.step),
                    "base_offset": .int(next.offset),
                ])
            }
            #endif
            // Pause/delete may land while an expensive append is queued behind other range IO.
            // Re-check immediately before touching the durable file: a pause keeps the stash for
            // Resume, while cancel/delete owns disposal of both the stash map and destination.
            lock.lock(); let haltBeforeAppend = rangeHaltKinds[key]; lock.unlock()
            guard haltBeforeAppend == nil else {
                settleHeldRangeDrainHalt(for: key, haltKind: haltBeforeAppend!,
                                         durableBytes: durable, expectedBytes: expectedBytes,
                                         publishProgress: false)
                break
            }
            do {
                let appended = try appendFile(at: entry.url, onto: destination)
                durable = onDisk + appended
            } catch {
                // M1: an append failure for one held segment must not wedge the drain forever. Drop the
                // failing entry (and its stash), record it, and keep draining the rest of the run.
                guard removeHeldRangeSegments(
                    for: key,
                    segments: [(offset: next.offset, fallbackURL: entry.url)]
                ) else {
                    AppDiagnostics.record(.downloads, "downloads.range_segment_assemble_deferred", fields: [
                        "download_id": .identifier(ratingKey),
                        "base_offset": .int(next.offset),
                        "reason": .label("manifest_persistence_failed"),
                    ])
                    break
                }
                AppDiagnostics.record(.downloads, "downloads.range_segment_assemble_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "base_offset": .int(next.offset),
                    "durable_bytes": .int(durable),
                    "error": .error(error),
                ])
                continue
            }
            removeHeldRangeSegment(for: key, offset: next.offset,
                                   fallbackURL: entry.url)
            AppDiagnostics.record(.downloads, "downloads.range_segment_assembled", fields: [
                "download_id": .identifier(ratingKey),
                "base_offset": .int(next.offset),
                "partial_bytes": .int(durable),
            ])
            // If pause raced the append itself, the append is now a valid durable checkpoint and
            // must be published, but it must not promote the row back to Downloading or allow the
            // rest of the held run to drain. Cancel/delete must not resurrect a removed row.
            lock.lock(); let haltAfterAppend = rangeHaltKinds[key]; lock.unlock()
            if let haltAfterAppend {
                settleHeldRangeDrainHalt(for: key, haltKind: haltAfterAppend,
                                         durableBytes: durable, expectedBytes: expectedBytes,
                                         publishProgress: haltAfterAppend == .pause)
                break
            }
            guard acceptedAttemptSubmission(
                resolveLifecycleSubmission(store.submitProgress(for: key, bytes: durable,
                                     progress: (expectedBytes ?? 0) > 0
                                        ? min(1, Double(durable) / Double(expectedBytes!)) : 0)),
                key: key, phase: "held_drain_progress") else { break }
        }
        // M2: read + mutate the held map under the same lock the rest of the file uses for
        // cross-queue access, rather than reading it unlocked.
        lock.lock()
        if heldRangeSegments[key]?.isEmpty ?? false { heldRangeSegments.removeValue(forKey: key) }
        lock.unlock()
        return durable
    }

    /// Stop an in-progress held-body drain at a pause/cancel boundary. A pause leaves the
    /// unconsumed held stashes mapped for Resume and parks the row after publishing any append that
    /// won the race. Cancel/delete owns teardown and must never recreate or mutate its removed row.
    private func settleHeldRangeDrainHalt(for key: DownloadAttemptKey,
                                          haltKind: StaticRangeHaltKind,
                                          durableBytes: Int, expectedBytes: Int?,
                                          publishProgress: Bool) {
        let ratingKey = key.ratingKey
        guard haltKind == .pause else { return }
        if publishProgress {
            guard acceptedAttemptSubmission(
                resolveLifecycleSubmission(store.submitProgress(for: key, bytes: durableBytes,
                                     progress: (expectedBytes ?? 0) > 0
                                        ? min(1, Double(durableBytes) / Double(expectedBytes!)) : 0)),
                key: key, phase: "held_drain_halt_progress") else { return }
        }
        guard acceptedAttemptSubmission(resolveLifecycleSubmission(store.submitStatus(for: key, .paused)),
                                      key: key, phase: "held_drain_halt_status") else { return }
        AppDiagnostics.record(.downloads, "downloads.range_held_drain_halted", fields: [
            "download_id": .identifier(ratingKey),
            "partial_bytes": .int(durableBytes),
            "published_append": .bool(publishProgress),
        ])
        onChange?()
    }

    /// C2: a terminal `.failed` transition has no automatic continuation — the only way forward is
    /// a user Retry, which re-plans the train from the durable checkpoint (mirroring pause, which
    /// already purges). Without this, up to a full train of ahead-of-checkpoint stashes stayed
    /// pinned in `tmp/` — protected from the orphan sweep and invisible to the storage cap — for
    /// the rest of the app run. No-op for rows with no held segments (including the opaque lane).
    private func setFailedPurgingHeldSegments(for key: DownloadAttemptKey) {
        let ratingKey = key.ratingKey
        purgeHeldRangeSegments(for: key)
        // A terminal failure must tear the rest of the train down BEFORE the `.failed` write: up
        // to 7 live siblings would
        // otherwise keep transferring, auto-promote the row back to `.downloading` via
        // `updateProgress`, and loop an unbudgeted refetch cycle over the purged held bodies. The
        // failed row deliberately retains attempt A: explicit Retry mints B and atomically replaces
        // exactly A, while late callbacks from A remain identifiable as stale.
        let teardown = StaticRangeTrainIntegrityPolicy.terminalFailureTeardown()
        var superseded: [Int] = []
        lock.lock()
        if teardown.insertHalt { rangeHaltKinds[key] = .cancel }
        if teardown.supersedeLiveTasks {
            superseded = supersedeRangeTasksLocked(ratingKey: ratingKey)
        }
        if teardown.advanceTrainEpoch {
            rangeTrainEpochs[key] = (rangeTrainEpochs[key] ?? 0) + 1
        }
        lock.unlock()
        for identifier in superseded {
            cancelURLSessionTask(identifier: identifier)
        }
        if !superseded.isEmpty {
            AppDiagnostics.record(.downloads, "downloads.range_train_superseded", fields: [
                "download_id": .identifier(ratingKey),
                "superseded_task_count": .int(superseded.count),
                "reason": .label("terminal_failed"),
            ])
        }
        _ = acceptedAttemptSubmission(resolveLifecycleSubmission(store.submitStatus(for: key, .failed)),
                                    key: key, phase: "terminal_failed")
    }

    /// Finding 2: manager-driven terminal teardown for a static-Range remainder whose post-logout auth
    /// HTTP failure the manager resolved as `.fail` (a genuine auth error — the backend session is still
    /// live). `finishRangeRemainder` hands the terminal decision to the manager over `onRangeAuthHTTPFailure`
    /// and returns BEFORE its own `setFailedPurgingHeldSegments`, so the manager must drive that same
    /// teardown back here: otherwise held out-of-order stashes leak in `tmp/`, live siblings keep
    /// transferring and auto-promote the `.failed` row straight back to `.downloading` (the C2 loop), and
    /// the row never fails terminally. Runs the row's current attempt through the identical
    /// purge + supersede + epoch-advance + attempt-fenced `.failed` write. Fences on the `attemptKey`
    /// that actually 401'd (carried through the callback): the manager's disposition runs after a
    /// main-actor Task hop, so if a newer attempt has taken the row since the failure it no longer owns
    /// this key and the teardown must no-op — a fresh attempt owns the row, leave it alone.
    func failStaticRangeAuthTerminal(attemptKey: DownloadAttemptKey) {
        guard store.ownsAttempt(attemptKey) else { return }
        setFailedPurgingHeldSegments(for: attemptKey)
    }

    /// Finding 2: manager-driven quiescence for a static-Range remainder the manager is parking as
    /// deferred (post-logout auth failure while the backend session is GONE). Unlike the `.fail`
    /// teardown this is resume-safe: it PRESERVES held out-of-order segment stashes so the later resume
    /// can reuse them, and installs a `.pause` (never `.cancel`) halt so a finished body still in the
    /// delegate→IO hop is kept rather than discarded. It still supersedes + cancels the live sibling
    /// tasks and advances the train epoch so a same-attempt sibling progress/finish callback cannot
    /// auto-promote the parked `.paused`/`.queued` row back to `.downloading`, and resets the exhausted
    /// retry/rehydration budget so a clean rehydration path exists once the account is signed back in.
    /// The `.pause` halt is cleared by the eventual user/auto resume (`start` removes it), so it cannot
    /// wedge the deferred continuation. The manager owns the row status write. Fences on the `attemptKey`
    /// that actually 401'd (carried through the callback): the manager's disposition runs after a
    /// main-actor Task hop, so if a newer attempt has taken the row since the failure it no longer owns
    /// this key and the quiescence must no-op — a fresh attempt owns the row, leave it alone.
    func quiesceStaticRangeForDeferredResume(attemptKey: DownloadAttemptKey) {
        guard store.ownsAttempt(attemptKey) else { return }
        let ratingKey = attemptKey.ratingKey
        var superseded: [Int] = []
        lock.lock()
        if rangeHaltKinds[attemptKey] != .cancel { rangeHaltKinds[attemptKey] = .pause }
        superseded = supersedeRangeTasksLocked(ratingKey: ratingKey)
        rangeTrainEpochs[attemptKey] = (rangeTrainEpochs[attemptKey] ?? 0) + 1
        lock.unlock()
        for identifier in superseded {
            cancelURLSessionTask(identifier: identifier)
        }
        if !superseded.isEmpty {
            AppDiagnostics.record(.downloads, "downloads.range_train_superseded", fields: [
                "download_id": .identifier(ratingKey),
                "superseded_task_count": .int(superseded.count),
                "reason": .label("deferred_awaiting_session"),
            ])
        }
        clearRetryCount(for: attemptKey)
    }

    /// C2: remove every held out-of-order segment stash for a row AND delete its on-disk temp file.
    /// Called from every path that abandons or resets the transfer (cancel/changed-resource
    /// restart/whole-file replace/finalize). Pause deliberately preserves durable held bodies so a
    /// later Resume can reuse them. A purged body can neither leak on disk nor be
    /// resurrected against a partial it no longer matches.
    private func purgeHeldRangeSegments(for key: DownloadAttemptKey) {
        let ratingKey = key.ratingKey
        lock.lock()
        let currentURLs = heldRangeSegments[key]?.values.map(\.url) ?? []
        let retainedURLs = heldRangeRetainedPredecessorURLs[key]?.values.flatMap { $0 } ?? []
        lock.unlock()
        guard case .accepted(let take) = store.submitHeldRangeSegmentsRemoval(
            for: key,
            offsets: nil,
            deletingRelativePaths: (currentURLs + retainedURLs).map(\.lastPathComponent)) else { return }
        resolveHeldLifecycle(take.ticket) { [weak self] outcome in
            guard let self, outcome == .completed else { return }
            self.lock.lock()
            self.heldRangeSegments.removeValue(forKey: key)
            self.heldRangeRetainedPredecessorURLs.removeValue(forKey: key)
            self.lock.unlock()
            AppDiagnostics.record(.downloads, "downloads.range_held_segments_purged", fields: [
                "download_id": .identifier(ratingKey),
                "purged_count": .int(take.removed.count),
            ])
        }
    }

    private func expectedRangeBodyBytes(entry: RangeTransfer) -> Int? {
        rangeRemainderPolicy.expectedBodyBytes(offset: entry.baseOffset,
                                               expectedBytes: entry.expectedBytes,
                                               segmentLength: entry.segmentLength)
    }

    /// Start a fresh open-ended Range remainder if we still hold the request (same launch);
    /// otherwise persist a system-resume intent so DownloadManager rebuilds the request and
    /// continues from the durable partial (a relaunch-adopted task has no in-memory request — its
    /// auth headers can't be reconstructed).
    private func continueRangeAfterBody(entry: RangeTransfer, partialSize: Int) {
        // Defense in depth alongside the `finishRangeRemainder` halt gate: never start a request
        // behind a concurrent cancel/pause.
        lock.lock(); let halted = rangeHaltKinds[entry.attemptKey] != nil; lock.unlock()
        let disposition = StaticRangeContinuationPolicy.afterFinishedBody(
            isHalted: halted,
            hasRequest: entry.request != nil
        )
        switch disposition {
        case .halted:
            return
        case .requestNeeded(let reason):
            AppDiagnostics.record(.downloads, "downloads.range_request_rebuild_needed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "bytes": .bytes(partialSize),
            ])
            // Persist active system-resume intent before the in-memory callback. If the app is killed
            // again before DownloadManager rebuilds the authenticated request, launch reconciliation
            // can derive that this non-user-paused row should continue from the durable checkpoint.
            // Hold the background completion handler across the rebuild (#212): without this hold the
            // gate hits zero the moment the append returns, the handler fires, and the OS suspends
            // the app before the next task is created — the decisive half of the off-head stall.
            beginRangeRequestRebuildGrace(for: entry.attemptKey)
            _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .queued))
            onRangeRequestNeeded?(entry.ratingKey, reason)
            return
        case .startInSession:
            guard let request = entry.request else { return }
            do {
                try startRangeRemainder(ratingKey: entry.ratingKey, with: request, to: entry.workingURL,
                                    expectedBytes: entry.expectedBytes, resetsRetryCount: false,
                                    attemptID: entry.attemptID)
            } catch {
                if shouldSuppressRangeStartFailure(for: entry.attemptKey,
                                                   error: error,
                                                   context: "continue_remainder") {
                    onChange?()
                    return
                }
                if handleRangeStartStorageFull(for: entry.attemptKey,
                                               error: error,
                                               context: "continue_remainder") {
                    return
                }
                _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .paused))
                onError?(entry.ratingKey, .interruptedResumable)
                onChange?()
            }
        case .failExhausted:
            return
        }
    }

    /// A misaligned 206 body has NOT been appended, so the durable partial is still safe. Treat it
    /// like a transient range-body failure first: discard the bad temp and re-request from the SAME
    /// durable checkpoint a few times before surfacing a terminal error. This covers
    /// server/proxy/background-daemon oddities observed on Emby where a later response can
    /// occasionally come back with an absent or
    /// unexpected `Content-Range`; failing immediately strands a valid multi-GB checkpoint even
    /// though a clean retry can continue without corruption.
    private func retryRangeOffsetMismatch(entry: RangeTransfer, durableBytes: Int, serverOffset: Int?) -> Bool {
        lock.lock()
        let halted = rangeHaltKinds[entry.attemptKey] != nil
        let retryAttempt = staticRangeRetryBudget.recordOffsetMismatch(
            key: staticRangeRetryKey(for: entry.attemptKey),
            segmentOffset: entry.baseOffset)
        lock.unlock()

        let disposition = StaticRangeContinuationPolicy.afterOffsetMismatch(
            isHalted: halted,
            retryAttempt: retryAttempt,
            hasRequest: entry.request != nil
        )
        switch disposition {
        case .halted:
            return true
        case .failExhausted:
            lock.lock()
            staticRangeRetryBudget.resetOffsetMismatch(
                key: staticRangeRetryKey(for: entry.attemptKey),
                segmentOffset: entry.baseOffset)
            lock.unlock()
            AppDiagnostics.record(.downloads, "downloads.range_offset_retry_exhausted", fields: [
                "download_id": .identifier(entry.ratingKey),
                "attempt": .int(retryAttempt.attempt - 1),
                "expected_offset": .bytes(entry.baseOffset),
                "expected_offset_exact": .int(entry.baseOffset),
                "server_offset": .bytes(serverOffset),
                "server_offset_exact": .int(serverOffset ?? -1),
                "bytes": .bytes(durableBytes),
                "bytes_exact": .int(durableBytes),
            ])
            return false
        case .requestNeeded(let reason):
            AppDiagnostics.record(.downloads, "downloads.range_offset_retry", fields: [
                "download_id": .identifier(entry.ratingKey),
                "attempt": .int(retryAttempt.attempt),
                "expected_offset": .bytes(entry.baseOffset),
                "expected_offset_exact": .int(entry.baseOffset),
                "server_offset": .bytes(serverOffset),
                "server_offset_exact": .int(serverOffset ?? -1),
                "bytes": .bytes(durableBytes),
                "bytes_exact": .int(durableBytes),
            ])
            // Relaunch-adopted range task: the bad temp is gone and the durable partial remains the
            // checkpoint, but this object lacks auth headers. Persist an active continuation intent
            // so DownloadManager rebuilds the backend-owned request and resumes automatically.
            // #212: hold the background completion handler across the main-actor rebuild (mirrors the
            // counter-reset rebuild site); `startRangeRemainder` releases it once the task exists.
            beginRangeRequestRebuildGrace(for: entry.attemptKey)
            _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .queued))
            onRangeRequestNeeded?(entry.ratingKey, reason)
            onChange?()
            return true
        case .startInSession:
            AppDiagnostics.record(.downloads, "downloads.range_offset_retry", fields: [
                "download_id": .identifier(entry.ratingKey),
                "attempt": .int(retryAttempt.attempt),
                "expected_offset": .bytes(entry.baseOffset),
                "expected_offset_exact": .int(entry.baseOffset),
                "server_offset": .bytes(serverOffset),
                "server_offset_exact": .int(serverOffset ?? -1),
                "bytes": .bytes(durableBytes),
                "bytes_exact": .int(durableBytes),
            ])
            guard let request = entry.request else { return false }
            do {
                try startRangeRemainder(ratingKey: entry.ratingKey,
                                    with: request,
                                    to: entry.workingURL,
                                    expectedBytes: entry.expectedBytes,
                                    resetsRetryCount: false,
                                    attemptID: entry.attemptID)
                onChange?()
                return true
            } catch {
                if shouldSuppressRangeStartFailure(for: entry.attemptKey,
                                                   error: error,
                                                   context: "offset_retry") {
                    onChange?()
                    return true
                }
                if handleRangeStartStorageFull(for: entry.attemptKey,
                                               error: error,
                                               context: "offset_retry") {
                    return true
                }
                AppDiagnostics.record(.downloads, "downloads.range_offset_retry_failed", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "attempt": .int(retryAttempt.attempt),
                    "error": .error(error),
                ])
                return false
            }
        }
    }

    /// The pinned resource validator changed mid-download (#169 HIGH 1, Plex path): the durable partial
    /// is now a stale prefix and the just-fetched body is bytes from a different resource. Throw both
    /// away and restart from offset 0 so the partial is rebuilt against the current resource — the only
    /// honest recovery when the server won't downgrade a changed resource to a whole-file 200.
    private func restartRangeFromChangedResource(entry: RangeTransfer) {
        lock.lock()
        let halted = rangeHaltKinds[entry.attemptKey] != nil
        let retryAttempt = staticRangeRetryBudget.recordValidatorChange(key: staticRangeRetryKey(for: entry.attemptKey))
        // B.2: tear the whole segment train down BEFORE re-planning. Stale old-resource siblings
        // left in flight would (a) be counted by the re-plan's liveSegmentOffsets as covering
        // their offsets in the NEW train, and (b) each trigger another delete-and-restart (or a
        // version-unchecked held stash) as they finish. Advancing the epoch also invalidates
        // sibling bodies already past the delegate finish.
        let supersededSiblings = supersedeRangeTasksLocked(ratingKey: entry.ratingKey)
        rangeTrainEpochs[entry.attemptKey] = (rangeTrainEpochs[entry.attemptKey] ?? 0) + 1
        lock.unlock()
        for identifier in supersededSiblings {
            cancelURLSessionTask(identifier: identifier)
        }
        if !supersededSiblings.isEmpty {
            AppDiagnostics.record(.downloads, "downloads.range_train_superseded", fields: [
                "download_id": .identifier(entry.ratingKey),
                "superseded_task_count": .int(supersededSiblings.count),
                "reason": .label("changed_resource_restart"),
            ])
        }
        AppDiagnostics.record(.downloads, "downloads.range_validator_changed", fields: [
            "download_id": .identifier(entry.ratingKey),
            "bytes": .bytes(entry.baseOffset),
            "restart_count": .int(retryAttempt.attempt),
        ])
        try? fileManager.removeItem(at: entry.workingURL)
        resolveLifecycleSubmission(store.submitRangeValidator(for: entry.attemptKey, nil))
        _ = resolveLifecycleSubmission(store.submitProgress(for: entry.attemptKey, bytes: 0, progress: 0))
        // C2: the durable partial (offset 0..) is being rebuilt against the CURRENT resource; any held
        // segments belong to the stale resource and must be dropped, not appended after the restart.
        purgeHeldRangeSegments(for: entry.attemptKey)
        let disposition = StaticRangeContinuationPolicy.afterValidatorChange(
            isHalted: halted,
            retryAttempt: retryAttempt,
            hasRequest: entry.request != nil
        )
        switch disposition {
        case .halted:
            return
        case .failExhausted:
            // Bound the loop: a validator that keeps changing per-response (mechanism certain, e.g. a
            // PlexOptimize Part still being written, or a load-balanced/proxied ETag) would otherwise spin
            // forever re-downloading from 0 with zero forward progress. After N consecutive restarts with
            // no successful append, fail clearly instead of livelocking.
            lock.lock()
            staticRangeRetryBudget.reset(key: staticRangeRetryKey(for: entry.attemptKey))
            lock.unlock()
            AppDiagnostics.record(.downloads, "downloads.range_validator_unstable", fields: [
                "download_id": .identifier(entry.ratingKey),
                "restart_count": .int(retryAttempt.attempt),
            ])
            setFailedPurgingHeldSegments(for: entry.attemptKey)
            onError?(entry.ratingKey, .transferFailed("The source file kept changing during download."))
            onChange?()
        case .requestNeeded(let reason):
            // Relaunch-adopted range task: no in-memory request to rebuild auth headers, and the stale
            // partial has already been discarded. Persist active restart intent before the in-memory
            // callback so a second app kill still auto-restarts from byte 0 on the next launch.
            // #212: hold the background completion handler across the main-actor rebuild (mirrors the
            // counter-reset rebuild site); `startRangeRemainder` releases it once the task exists.
            beginRangeRequestRebuildGrace(for: entry.attemptKey)
            _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .queued))
            onRangeRequestNeeded?(entry.ratingKey, reason)
        case .startInSession:
            guard let request = entry.request else { return }
            do {
                // The partial was just deleted, so `startRangeRemainder` derives offset 0 and pins a fresh
                // validator on the new first range body.
                try startRangeRemainder(ratingKey: entry.ratingKey, with: request, to: entry.workingURL,
                                    expectedBytes: entry.expectedBytes, resetsRetryCount: false,
                                    attemptID: entry.attemptID)
            } catch {
                if shouldSuppressRangeStartFailure(for: entry.attemptKey,
                                                   error: error,
                                                   context: "validator_restart") {
                    onChange?()
                    return
                }
                if handleRangeStartStorageFull(for: entry.attemptKey,
                                               error: error,
                                               context: "validator_restart") {
                    return
                }
                _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .paused))
                onError?(entry.ratingKey, .interruptedResumable)
                onChange?()
            }
        }
    }


    /// Synchronously claims the exact attempt before any Task is scheduled. The manager then
    /// installs the one registry lease that owns execution/cancellation. A missing broker is an
    /// immediate abandon, not a leaked finalizing/background-completion count.
    @discardableResult
    private func requestFinalization(
        attemptKey: DownloadAttemptKey,
        destination: URL,
        bytes: Int,
        validationLabel: String,
        expectedExactBytes: Int? = nil,
        publishesWorkingFile: Bool = true,
        holdsBackgroundCompletion: Bool
    ) -> Bool {
        if case .started = requestFinalizationAdmission(
            attemptKey: attemptKey, destination: destination, bytes: bytes,
            validationLabel: validationLabel, expectedExactBytes: expectedExactBytes,
            publishesWorkingFile: publishesWorkingFile,
            holdsBackgroundCompletion: holdsBackgroundCompletion) { return true }
        return false
    }

    private func requestFinalizationAdmission(
        attemptKey: DownloadAttemptKey,
        destination: URL,
        bytes: Int,
        validationLabel: String,
        expectedExactBytes: Int? = nil,
        publishesWorkingFile: Bool = true,
        holdsBackgroundCompletion: Bool
    ) -> FinalizationAdmission {
        guard stillOwnsAttempt(attemptKey, phase: "finalize_admission") else { return .unavailable }
        let requestID = UUID()
        let admitted = finalizationStateQueue.sync { () -> Bool in
            guard finalizerRequestIDsByAttempt[attemptKey] == nil else { return false }
            finalizerRequestIDsByAttempt[attemptKey] = requestID
            return true
        }
        guard admitted else {
            AppDiagnostics.record(.downloads, "downloads.finalize_duplicate_ignored", fields: [
                "download_id": .identifier(attemptKey.ratingKey),
                "bytes": .bytes(bytes),
                "validation": .label(validationLabel),
            ])
            return .alreadyFinalizing
        }
        if holdsBackgroundCompletion { beginPendingBackgroundCompletionOperation() }
        let request = FinalizerRequest(
            id: requestID,
            attemptKey: attemptKey,
            destination: destination,
            bytes: bytes,
            validationLabel: validationLabel,
            expectedExactBytes: expectedExactBytes,
            publishesWorkingFile: publishesWorkingFile,
            holdsBackgroundCompletion: holdsBackgroundCompletion)
        guard let onFinalizerRequest else {
            abandonFinalizerRequest(request)
            return .unavailable
        }
        onFinalizerRequest(request)
        return .started(requestID: requestID)
    }

    /// Called by DownloadManager when registry admission loses to an existing exact finalizer (or
    /// when a broker is being torn down). Safe and idempotent for a request no longer admitted.
    func abandonFinalizerRequest(
        _ request: FinalizerRequest,
        revalidationOutcome: RevalidationRequestOutcome = .cancelled
    ) {
        let removed = finalizationStateQueue.sync {
            guard finalizerRequestIDsByAttempt[request.attemptKey] == request.id else {
                return false
            }
            finalizerRequestIDsByAttempt.removeValue(forKey: request.attemptKey)
            return true
        }
        if removed && request.holdsBackgroundCompletion {
            endPendingBackgroundCompletionOperation()
        }
        if removed && !request.publishesWorkingFile {
            onRevalidationRequestFinished?(request.attemptKey, request.id, revalidationOutcome)
        }
    }

    /// Execute only after DownloadManager has installed the exact `.finalizer` registry lease.
    func executeFinalizerRequest(_ request: FinalizerRequest) async {
        defer {
            let outcome: RevalidationRequestOutcome = Task.isCancelled ? .cancelled : .finished
            abandonFinalizerRequest(request, revalidationOutcome: outcome)
        }
        guard finalizationStateQueue.sync(execute: {
            finalizerRequestIDsByAttempt[request.attemptKey] == request.id
        }), !Task.isCancelled else { return }
        await finalizeTransferredFile(
            attemptKey: request.attemptKey,
            destination: request.destination,
            bytes: request.bytes,
            validationLabel: request.validationLabel,
            expectedExactBytes: request.expectedExactBytes,
            publishesWorkingFile: request.publishesWorkingFile)
    }

    @discardableResult
    func finalizeCompletedStaticRangeFile(ratingKey: String, validationLabel: String) -> Bool {
        guard isStartupAdmissionActive else { return false }
        guard let record = store.record(for: ratingKey), let attemptID = record.attemptID else {
            return false
        }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard store.ownsAttempt(attemptKey) else { return false }
        guard let destination = store.attemptWorkingFileURL(for: attemptKey) else { return false }
        let bytes = fileSize(at: destination) ?? record.bytes
        guard bytes > 0 else { return false }

        AppDiagnostics.record(.downloads, "downloads.range_finalize_recovered", fields: [
            "download_id": .identifier(ratingKey),
            "bytes": .bytes(bytes),
            "validation": .label(validationLabel),
        ])
        guard publishTransferFinalizing(for: attemptKey, bytes: bytes) else { return false }
        let expectedExactBytes = store.sourceExactBytes(for: attemptKey)
        return requestFinalization(
            attemptKey: attemptKey, destination: destination, bytes: bytes,
            validationLabel: validationLabel, expectedExactBytes: expectedExactBytes,
            holdsBackgroundCompletion: true)
    }

    /// Re-run the same bounded local playability probe for a byte-complete row that was previously
    /// preserved as `.unverified`. Safe to call on reconnect/scene-active; the finalization guard
    /// coalesces duplicates and another inconclusive probe leaves the file preserved.
    @discardableResult
    func revalidateCompletedDownload(
        ratingKey: String, validationLabel: String
    ) -> RevalidationAdmission {
        // Do not even claim a finalizer while a background wake is active. A claim used to look
        // like a real probe to DownloadManager, but the finalizer later skipped AVFoundation and
        // left the exact attempt suppressed for 90 seconds.
        guard let record = store.record(for: ratingKey),
              let attemptID = record.attemptID else { return .unavailable }
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard store.ownsAttempt(key),
              fileManager.fileExists(atPath: record.localURL.path) else { return .unavailable }
        if deferPlaybackProbeIfBackgroundWakePending(revalidationKey: key) {
            return .deferredForBackgroundWake
        }
        let destination = record.localURL
        let bytes = fileSize(at: destination) ?? 0
        guard bytes > 0 else {
            AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label("empty_file"),
                "bytes": .bytes(bytes),
                "preserved": .bool(false),
                "validation": .label(validationLabel),
            ])
            try? fileManager.removeItem(at: destination)
            clearRetryCount(for: key)
            setFailedPurgingHeldSegments(for: key)
            recordFinalizeFinished(ratingKey: ratingKey,
                                   result: "failed_empty",
                                   validationLabel: validationLabel,
                                   durationMs: 0,
                                   bytes: bytes)
            onError?(ratingKey, .transferFailed("Downloaded file is empty."))
            onChange?()
            return .unavailable
        }
        // Short-circuit BEFORE the probe when the durable bytes provably fall short of the
        // source's exact size: the probe can never rescue an incomplete static file (it either
        // false-passes off the leading moov or misses forever), and re-probing it on every
        // session/scene edge is what kept truncated rows looping as `.unverified` for hours.
        // Preserve the partial — it is the resume checkpoint.
        if let expectedExactBytes = store.sourceExactBytes(for: key),
           DownloadCompletionValidation.isIncomplete(downloadedBytes: bytes,
                                                     expectedExactBytes: expectedExactBytes) {
            AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label("incomplete_bytes"),
                "bytes": .bytes(bytes),
                "expected_bytes": .bytes(expectedExactBytes),
                "preserved": .bool(true),
                "validation": .label(validationLabel),
            ])
            _ = store.resetStaticRangeProgressToDurableCheckpoint(
                for: key, expectedBytes: expectedExactBytes)
            clearRetryCount(for: key)
            setFailedPurgingHeldSegments(for: key)
            recordFinalizeFinished(ratingKey: ratingKey,
                                   result: "failed_incomplete_bytes",
                                   validationLabel: validationLabel,
                                   durationMs: 0,
                                   bytes: bytes)
            onError?(ratingKey, .transferFailed(
                "Download is incomplete (\(bytes / 1_000_000) of \(expectedExactBytes / 1_000_000) MB). Retry to continue."))
            onChange?()
            return .unavailable
        }
        AppDiagnostics.record(.downloads, "downloads.unverified_revalidate", fields: [
            "download_id": .identifier(ratingKey),
            "bytes": .bytes(bytes),
            "validation": .label(validationLabel),
        ])
        guard store.ownsAttempt(key) else {
            AppDiagnostics.record(.downloads, "downloads.finalize_owner_missing", fields: [
                "download_id": .identifier(ratingKey),
                "validation": .label(validationLabel),
            ])
            return .unavailable
        }
        switch requestFinalizationAdmission(
            attemptKey: key, destination: destination, bytes: bytes,
            validationLabel: validationLabel,
            expectedExactBytes: store.sourceExactBytes(for: key),
            publishesWorkingFile: false, holdsBackgroundCompletion: false) {
        case .started(let requestID): return .started(requestID: requestID)
        case .alreadyFinalizing: return .alreadyFinalizing
        case .unavailable: return .unavailable
        }
    }

    /// The durable partial now holds the whole file: validate it through the SAME finalize pipeline as
    /// the opaque lane (HEVC `hvc1` fixup, #98 retrying probe, truncation guard, complete/unverified).
    private func finalizeRangeWhole(entry: RangeTransfer) {
        // C2/M3: the file is complete — no held segment may remain to be picked up by the tmp sweep
        // or a late drain. (The append path already drains before finalizing; this is the backstop
        // for the replaceWhole / 416-complete / offset>=expected finalize entrypoints.)
        purgeHeldRangeSegments(for: entry.attemptKey)
        let bytes = fileSize(at: entry.workingURL) ?? entry.totalBytes
        guard publishTransferFinalizing(for: entry.attemptKey, bytes: bytes) else { return }
        let destination = entry.workingURL
        // The range lane knows the source's exact size; the finalize byte-completeness guard
        // depends on it (headset evidence: a 416'd legacy bounded response finalized a truncated
        // 5.9 GB file straight to `.complete` because the moov-led MP4 passed the probe).
        let expectedExactBytes = entry.expectedBytes ?? store.sourceExactBytes(for: entry.attemptKey)
        _ = requestFinalization(
            attemptKey: entry.attemptKey, destination: destination, bytes: bytes,
            validationLabel: "range_checkpoint", expectedExactBytes: expectedExactBytes,
            holdsBackgroundCompletion: true)
    }

    /// Shared handoff from byte transfer to local finalization for both URLSession pipelines.
    ///
    /// Keep the persisted progress at exact 100% so the bar reflects that the network/file transfer
    /// finished, then let the UI derive the explicit "Verifying download…" display state from
    /// `.downloading + progress == 1.0` until `finalizeTransferredFile` writes the terminal status.
    private func publishTransferFinalizing(for key: DownloadAttemptKey, bytes: Int) -> Bool {
        guard acceptedAttemptSubmission(
            resolveLifecycleSubmission(store.submitProgress(for: key, bytes: bytes, progress: 1.0)),
            key: key, phase: "publish_finalizing") else { return false }
        onChange?()
        return true
    }

    private func failRangeMove(entry: RangeTransfer, error: Error, stage: String) {
        // Disk full is not transient and not recoverable by retrying the same append: fail with
        // the real reason (user must free space) and tear the train down instead of surfacing
        // "Transfer failed (system code 640)" or looping bounded retries. The durable partial
        // stays as the retry checkpoint.
        if DownloadDiskSpacePolicy.isOutOfSpace(error) {
            guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "move_storage_full"
            ) else { return }
            AppDiagnostics.record(.downloads, "downloads.move_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "stage": .label(stage),
                "reason": .label("storage_full"),
                "error": .error(error),
                "bytes": .bytes(durableBytes),
            ])
            setFailedPurgingHeldSegments(for: entry.attemptKey)
            onError?(entry.ratingKey, .storageFull)
            onChange?()
            return
        }
        if recoverRangeMoveFailure(entry: entry, error: error, stage: stage) {
            return
        }
        guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "move_failure"
            ) else { return }
        AppDiagnostics.record(.downloads, "downloads.move_failed", fields: [
            "download_id": .identifier(entry.ratingKey),
            "stage": .label(stage),
            "error": .error(error),
            "bytes": .bytes(durableBytes),
        ])
        setFailedPurgingHeldSegments(for: entry.attemptKey)
        onError?(entry.ratingKey, .transferFailed(
            DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer")))
        onChange?()
    }

    /// Recover "Cocoa code=4" Range temp/body move/append failures by doing what the user's Retry button
    /// would do: preserve/reset to the app-owned checkpoint and reissue/rebuild the next Range request
    /// a bounded number of times instead of terminally failing the row.
    private func recoverRangeMoveFailure(entry: RangeTransfer, error: Error, stage: String) -> Bool {
        let nsError = error as NSError
        guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "move_recovery"
            ) else { return false }
        lock.lock()
        let decision = BackgroundDownloadTransientRetryPolicy.rangeMoveDecision(
            errorDomain: nsError.domain,
            errorCode: nsError.code,
            hasRequest: entry.request != nil,
            currentRetryCount: retryCounts[entry.attemptKey] ?? 0
        )
        guard case .retry(let nextAttempt) = decision else {
            lock.unlock()
            // #220: a move failure committed no bytes, so the durable partial is a valid restart
            // point for the next open-ended remainder.
            if case .reject(.missingRangeRequest) = decision,
               nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.fileNoSuchFile.rawValue {
                AppDiagnostics.record(.downloads, "downloads.range_move_rehydrate", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "stage": .label(stage),
                    "error": .error(error),
                    "bytes": .bytes(durableBytes),
                    "reason": .label("missing_request"),
                ])
                _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .queued))
                onRangeRequestNeeded?(entry.ratingKey, .requestRebuildNeeded)
                onChange?()
                return true
            }
            return false
        }
        retryCounts[entry.attemptKey] = nextAttempt
        lock.unlock()

        guard let request = entry.request else { return false }
        let delay = Self.rangeHTTPRetryDelay(nextAttempt: nextAttempt)
        AppDiagnostics.record(.downloads, "downloads.range_move_retry", fields: [
            "download_id": .identifier(entry.ratingKey),
            "stage": .label(stage),
            "attempt": .int(nextAttempt),
            "max_attempts": .int(BackgroundDownloadTransientRetryPolicy.defaultMaxRangeMoveRetries),
            "error": .error(error),
            "bytes": .bytes(durableBytes),
            "delay_ms": .int(Int(delay * 1000)),
        ])
        _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .queued))
        rangeRetryQueue.asyncAfter(deadline: .now() + delay) { [self] in
            do {
                try startRangeRemainder(ratingKey: entry.ratingKey,
                                    with: request,
                                    to: entry.workingURL,
                                    expectedBytes: entry.expectedBytes,
                                    resetsRetryCount: false,
                                    remainderReasonOverride: "move_retry",
                                    attemptID: entry.attemptID)
                onChange?()
            } catch {
                if shouldSuppressRangeStartFailure(for: entry.attemptKey,
                                                   error: error,
                                                   context: "move_retry") {
                    onChange?()
                    return
                }
                if handleRangeStartStorageFull(for: entry.attemptKey,
                                               error: error,
                                               context: "move_retry") {
                    return
                }
                AppDiagnostics.record(.downloads, "downloads.range_move_retry_failed", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "attempt": .int(nextAttempt),
                    "error": .error(error),
                ])
                setFailedPurgingHeldSegments(for: entry.attemptKey)
                onError?(entry.ratingKey, .transferFailed("Retry after a missing download range body failed."))
                onChange?()
            }
        }
        onChange?()
        return true
    }

    /// Append `source` onto the end of `destination` in bounded blocks (never loading a whole
    /// temp file into memory). Returns the number of bytes appended.
    private func appendFile(at source: URL, onto destination: URL) throws -> Int {
        // Append-only: the durable partial is created at `start` and must already exist. If it is
        // gone, a concurrent cancel/pause deleted it out from under us (the bounded HIGH 2 race) —
        // refuse rather than re-create an orphan partial with no index row. The caller surfaces this
        // as a move failure; the halt gate then stops the chain.
        guard fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        #if DEBUG
        if DebugDownloadFaultURLProtocol.consumeInjectedWriteFailure() {
            AppDiagnostics.record(.downloads, "downloads.fault_injected", fields: [
                "scenario": .label("write-failure"),
                "stage": .label("append"),
            ])
            throw NSError(domain: NSCocoaErrorDomain,
                          code: CocoaError.fileWriteOutOfSpace.rawValue)
        }
        #endif
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        try writer.seekToEnd()
        var appended = 0
        let blockSize = 4 * 1_024 * 1_024
        while true {
            let data = try reader.read(upToCount: blockSize) ?? Data()
            if data.isEmpty { break }
            try writer.write(contentsOf: data)
            appended += data.count
        }
        return appended
    }

    /// Shared post-transfer finalize for BOTH download pipelines (the opaque background
    /// `downloadTask` and the static byte-range `downloadTask`). Runs the `hev1`→`hvc1` HEVC tag
    /// fixup, the GH #98 retrying playability probe, the duration truncation guard, and records the
    /// unified `.complete` / `.failed` (truncated) / `.unverified` (probe miss) outcome. GH #135:
    /// the range pipeline historically re-implemented a thinner, drifted version of this (no fixup,
    /// no truncation guard, probe miss → `.failed`); funnel both here so the decisions can't diverge.
    private func finalizeTransferredFile(attemptKey: DownloadAttemptKey,
                                         destination: URL,
                                         bytes: Int,
                                         validationLabel: String,
                                         expectedExactBytes: Int? = nil,
                                         publishesWorkingFile: Bool = true) async {
        let ratingKey = attemptKey.ratingKey
        guard stillOwnsAttempt(attemptKey, phase: "finalize_entry"), !Task.isCancelled else { return }

        // Lens 5 F3: the probe below can run 2–45s, and a delete + re-download of the same key
        // during it swaps the row AND the destination file under this finalize. Snapshot the
        // attempt token now; the verdict is applied only if the row still carries it — otherwise
        // a stale `.truncated` verdict would DELETE the new transfer's partial, or a stale
        // `.complete` would stamp a barely-started replacement row complete.
        let finalizeStarted = Date()
        AppDiagnostics.record(.downloads, "downloads.finalize_start", fields: [
            "download_id": .identifier(ratingKey),
            "bytes": .bytes(bytes),
            "validation": .label(validationLabel),
        ])

        guard !Task.isCancelled else { return }

        // #83/#127: rewrite a stream-copied HEVC MP4 from `hev1` to `hvc1` (AVFoundation black-screens
        // on `hev1`) BEFORE the playability probe. Gated on the CONTAINER, not the lane — any
        // mp4-family download can be `hev1`-tagged. `rewriteFile` no-ops on non-HEVC/non-`hev1` bodies.
        if DownloadCompletionValidation.needsHEVCTagFixup(pathExtension: destination.pathExtension) {
            do {
                let count = try HEVCTagFixup.rewriteFile(at: destination)
                if count > 0 {
                    AppDiagnostics.record(.downloads, "downloads.hevc_tag_fixup", fields: [
                        "download_id": .identifier(ratingKey),
                        "entries": .int(count),
                    ])
                }
            } catch {
                // A fixup failure is not fatal — let the probe decide. Never log the file path.
                AppDiagnostics.record(.downloads, "downloads.hevc_tag_fixup_failed", fields: [
                    "download_id": .identifier(ratingKey),
                    "error": .error(error),
                ])
            }
        }
        guard !Task.isCancelled else { return }

        // Lens 4 F4: while the app is background-launched (the app-delegate completion handler is
        // pending), the muted AVPlayer probe cannot advance — every file would burn the full
        // 8s + 4s timeouts SERIALIZED, holding the OS wake handler past its window (wake-kill and
        // rate-limit throttling). Skip the probe entirely: the durable move/progress are already
        // written, so finalize as `.unverified` and let `revalidateUnverifiedDownloads` run the
        // real probe on the next foreground pass. Foreground finalizes (no pending handler) are
        // unchanged.
        let deferProbeForBackgroundWake = deferPlaybackProbeIfBackgroundWakePending(
            revalidationKey: publishesWorkingFile ? nil : attemptKey)
        var validation: (played: Bool, reason: String, durationMs: Int?, detail: String?)
        if deferProbeForBackgroundWake {
            if !publishesWorkingFile {
                let requestID = finalizationStateQueue.sync {
                    finalizerRequestIDsByAttempt[attemptKey]
                }
                if let requestID { onRevalidationProbeDeferred?(attemptKey, requestID) }
            }
            AppDiagnostics.record(.downloads, "downloads.finalize_probe_deferred", fields: [
                "download_id": .identifier(ratingKey),
                "bytes": .bytes(bytes),
                "validation": .label(validationLabel),
            ])
            validation = (played: false, reason: "bg_probe_deferred", durationMs: nil, detail: nil)
        } else {
            // GH #98: the post-download playability probe is an INTERMITTENT false-negative — on a
            // device busy right after a heavy transcode+download, AVFoundation can transiently fail
            // to open/advance a COMPLETE file that a later attempt on the same bytes plays fine.
            // Retry with progressively longer timeouts before deciding.
            do {
                try await Self.playbackValidationLimiter.wait()
            } catch {
                return
            }
            defer { Task { await Self.playbackValidationLimiter.signal() } }
            validation = await validateLocalPlayback(destination)
            guard !Task.isCancelled else { return }
            if !validation.played {
                // #187: keep headset-idle finalization bounded. Multiple long AVPlayer probes in
                // parallel are a plausible source of the observed idle gray/freeze/crash while
                // MB-sized files sit at "Verifying download…". Serialize probes and give one longer
                // retry before preserving the file as `.unverified` for later playback instead of
                // repeatedly burning foreground resources.
                for extraTimeout in [15.0] {
                    downloadLog.notice("playback-probe retry ratingKey=\(ratingKey, privacy: .public) reason=\(validation.reason, privacy: .public) nextTimeout=\(extraTimeout, privacy: .public)")
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    validation = await validateLocalPlayback(
                        destination, timeoutSecondsOverride: extraTimeout)
                    guard !Task.isCancelled else { return }
                    if validation.played { break }
                }
            }
        }

        // Truncation guard (only meaningful when both durations are known): a transcode that aborts
        // early — or a static download the server cut short while still returning 2xx — can play its
        // first fraction of a second and pass the probe. A decoded duration far under the source's is
        // truncated, not complete. Legitimate short clips compare against their own short duration.
        guard !Task.isCancelled else { return }
        let finalizeRecord = store.record(for: ratingKey)
        // Lens 5 F3: apply the verdict only to the attempt it was probed for. A delete (row gone)
        // or delete + re-download (attempt token changed) during the probe means `destination` and
        // the row now belong to a DIFFERENT transfer — deleting the file or stamping a status here
        // would corrupt the replacement. Drop the verdict; the live attempt finalizes itself.
        guard finalizeRecord?.attemptID == attemptKey.attemptID else {
            AppDiagnostics.record(.downloads, "downloads.finalize_stale_attempt_dropped", fields: [
                "download_id": .identifier(ratingKey),
                "bytes": .bytes(bytes),
                "validation": .label(validationLabel),
                "row_present": .bool(finalizeRecord != nil),
                "probe_reason": .label(validation.reason),
            ])
            return
        }
        let expectedDurationMs = finalizeRecord?.metadata?.duration
        // JF-F2: a live forward-only encoder stream has no exact byte size, so its duration guard
        // is the only completeness signal — tightened threshold, and no `.complete` on faith when
        // either duration is unknown.
        let forwardOnly = finalizeRecord?.metadata?
            .resolvedResumeMode(ratingKey: ratingKey) == .liveForwardOnly
        guard !Task.isCancelled else { return }
        let outcome = DownloadCompletionValidation.outcome(played: validation.played,
                                                           probeReason: validation.reason,
                                                           expectedDurationMs: expectedDurationMs,
                                                           actualDurationMs: validation.durationMs,
                                                           downloadedBytes: bytes,
                                                           expectedExactBytes: expectedExactBytes,
                                                           forwardOnly: forwardOnly)
        guard !Task.isCancelled else { return }
        let truncationFailures: Int? = finalizationStateQueue.sync {
            guard !Task.isCancelled else { return nil }
            switch outcome {
            case .truncated:
                let next = truncationFailureCounts[attemptKey.ratingKey, default: 0] + 1
                truncationFailureCounts[attemptKey.ratingKey] = next
                return next
            case .complete:
                truncationFailureCounts.removeValue(forKey: attemptKey.ratingKey)
                return 0
            default:
                return truncationFailureCounts[attemptKey.ratingKey] ?? 0
            }
        }
        guard let truncationFailures else { return }
        let finalizationResult = BackgroundFinalizationResultPolicy.result(
            for: outcome,
            consecutiveTruncationFailures: truncationFailures)
        let finalizationDurationMs = max(0, Int(Date().timeIntervalSince(finalizeStarted) * 1000))
        guard !Task.isCancelled else { return }
        switch outcome {
        case .emptyFile:
            downloadLog.error("empty-download ratingKey=\(ratingKey, privacy: .public) bytes=\(bytes, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(finalizationResult.validationFailureReason ?? "empty_file"),
                "bytes": .bytes(bytes),
                "preserved": .bool(false),
            ])
            guard !Task.isCancelled else { return }
            clearRetryCount(for: attemptKey)
            guard acceptedAttemptSubmission(
                resolveLifecycleSubmission(store.submitStatus(for: attemptKey, finalizationResult.status)),
                key: attemptKey, phase: "finalize_empty_status"
            ) else { return }
            if finalizationResult.shouldDeleteFile,
               !Task.isCancelled,
               stillOwnsAttempt(attemptKey, phase: "finalize_empty_delete") {
                try? fileManager.removeItem(at: destination)
            }
            guard !Task.isCancelled,
                  stillOwnsAttempt(attemptKey, phase: "finalize_empty_publish") else { return }
            onError?(ratingKey, .transferFailed(finalizationResult.userFacingErrorMessage ?? "Downloaded file is empty."))
            recordFinalizeFinished(ratingKey: ratingKey,
                                   result: finalizationResult.resultLabel,
                                   validationLabel: validationLabel,
                                   durationMs: finalizationDurationMs,
                                   bytes: bytes)
        case .incompleteBytes(let actualBytes, let expectedTotalBytes):
            downloadLog.error("incomplete-download ratingKey=\(ratingKey, privacy: .public) bytes=\(actualBytes, privacy: .public) expected=\(expectedTotalBytes, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(finalizationResult.validationFailureReason ?? "incomplete_bytes"),
                "bytes": .bytes(actualBytes),
                "expected_bytes": .bytes(expectedTotalBytes),
                "preserved": .bool(true),
            ])
            // Keep the partial as the resume checkpoint (shouldDeleteFile is false) and pull the
            // published 100% "finalizing" progress back to the durable byte count so the row shows
            // its real position again.
            guard !Task.isCancelled else { return }
            clearRetryCount(for: attemptKey)
            guard acceptedAttemptSubmission(
                resolveLifecycleSubmission(store.submitStatus(for: attemptKey, finalizationResult.status)),
                key: attemptKey, phase: "finalize_incomplete_status"
            ) else { return }
            if !Task.isCancelled,
               stillOwnsAttempt(attemptKey, phase: "finalize_incomplete_reset") {
                guard resetStaticRangeProgressToDurableCheckpoint(
                    for: attemptKey, expectedBytes: expectedTotalBytes,
                    context: "finalize_incomplete") != nil else { return }
            }
            guard !Task.isCancelled,
                  stillOwnsAttempt(attemptKey, phase: "finalize_incomplete_publish") else { return }
            onError?(ratingKey, .transferFailed(finalizationResult.userFacingErrorMessage ?? "Download is incomplete."))
            recordFinalizeFinished(ratingKey: ratingKey,
                                   result: finalizationResult.resultLabel,
                                   validationLabel: validationLabel,
                                   durationMs: finalizationDurationMs,
                                   bytes: bytes)
        case .truncated(let actualDurationMs, let expectedMs):
            downloadLog.error("truncated-download ratingKey=\(ratingKey, privacy: .public) expectedMs=\(expectedMs, privacy: .public) actualMs=\(actualDurationMs, privacy: .public) attempt=\(truncationFailures, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(finalizationResult.validationFailureReason ?? "truncated_duration"),
                "expected_duration_ms": .int(expectedMs),
                "actual_duration_ms": .int(actualDurationMs),
                "consecutive_failures": .int(truncationFailures),
                "preserved": .bool(!finalizationResult.shouldDeleteFile),
            ])
            guard !Task.isCancelled else { return }
            clearRetryCount(for: attemptKey)
            guard acceptedAttemptSubmission(
                resolveLifecycleSubmission(store.submitStatus(for: attemptKey, finalizationResult.status)),
                key: attemptKey, phase: "finalize_truncated_status"
            ) else { return }
            if finalizationResult.shouldDeleteFile,
               !Task.isCancelled,
               stillOwnsAttempt(attemptKey, phase: "finalize_truncated_delete") {
                try? fileManager.removeItem(at: destination)
            }
            guard !Task.isCancelled,
                  stillOwnsAttempt(attemptKey, phase: "finalize_truncated_publish") else { return }
            onError?(ratingKey, .invalidDownload(finalizationResult.userFacingErrorMessage ?? "Downloaded file is truncated."))
            recordFinalizeFinished(ratingKey: ratingKey,
                                   result: finalizationResult.resultLabel,
                                   validationLabel: validationLabel,
                                   durationMs: finalizationDurationMs,
                                   bytes: bytes)
        case .complete:
            // Validated: mark explicitly complete (D2) so a relaunch trusts it.
            downloadLog.info("complete ratingKey=\(ratingKey, privacy: .public) bytes=\(bytes, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.complete", fields: [
                "download_id": .identifier(ratingKey),
                "bytes": .bytes(bytes),
                "validation": .label(validationLabel),
            ])
            guard !Task.isCancelled else { return }
            clearRetryCount(for: attemptKey)
            if publishesWorkingFile {
                guard await promoteValidatedWorkingFile(
                    for: attemptKey, status: .complete,
                    phase: "finalize_complete_promote") else { return }
            } else {
                guard acceptedAttemptSubmission(
                    resolveLifecycleSubmission(store.submitProgress(for: attemptKey, bytes: bytes, progress: 1)),
                    key: attemptKey, phase: "revalidate_complete_progress"
                ), acceptedAttemptSubmission(
                    resolveLifecycleSubmission(store.submitStatus(for: attemptKey, finalizationResult.status)),
                    key: attemptKey, phase: "revalidate_complete_status"
                ) else { return }
            }
            guard !Task.isCancelled,
                  stillOwnsAttempt(attemptKey, phase: "finalize_complete_publish") else { return }
            recordFinalizeFinished(ratingKey: ratingKey,
                                   result: finalizationResult.resultLabel,
                                   validationLabel: validationLabel,
                                   durationMs: finalizationDurationMs,
                                   bytes: bytes)
        case .unverified(let reason):
            // GH #98: do NOT delete or fail the file on a probe miss — the probe is an intermittent
            // false-negative on COMPLETE downloads; deleting/failing forces a wasteful 0%
            // re-download and discards good bytes. Keep the row playable but explicitly unverified.
            // (H3: the range pipeline used to condemn this identical condition to `.failed`.)
            downloadLog.error("invalid-download ratingKey=\(ratingKey, privacy: .public) reason=\(reason, privacy: .public) detail=\(validation.detail ?? "nil", privacy: .public) bytes=\(bytes, privacy: .public) preserved=true")
            AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label(reason),
                "detail": .label(validation.detail ?? "none"),
                "bytes": .bytes(bytes),
                "preserved": .bool(true),
            ])
            guard !Task.isCancelled else { return }
            clearRetryCount(for: attemptKey)
            if publishesWorkingFile {
                guard await promoteValidatedWorkingFile(
                    for: attemptKey, status: .unverified,
                    phase: "finalize_unverified_promote") else { return }
            } else {
                guard acceptedAttemptSubmission(
                    resolveLifecycleSubmission(store.submitStatus(for: attemptKey, finalizationResult.status)),
                    key: attemptKey, phase: "revalidate_unverified_status"
                ) else { return }
            }
            guard !Task.isCancelled,
                  stillOwnsAttempt(attemptKey, phase: "finalize_unverified_publish") else { return }
            recordFinalizeFinished(ratingKey: ratingKey,
                                   result: finalizationResult.resultLabel,
                                   validationLabel: validationLabel,
                                   durationMs: finalizationDurationMs,
                                   bytes: bytes)
        }
        guard !Task.isCancelled else { return }
        onChange?()
    }

    private func promoteValidatedWorkingFile(for key: DownloadAttemptKey,
                                                status: DownloadStatus,
                                                phase: String) async -> Bool {
        var shouldSurfaceFailure = true
        var shouldMarkFailed = true
        let submission = store.submitValidatedPromotion(for: key, terminalStatus: status)
        switch await store.resolveValidatedPromotion(submission) {
        case .promoted:
            return true
        case .staleOrMissingOwner:
            shouldSurfaceFailure = false
            AppDiagnostics.record(.downloads, "downloads.stale_attempt_mutation_dropped", fields: [
                "download_id": .identifier(key.ratingKey), "phase": .label(phase)])
        case .resetPending:
            AppDiagnostics.record(.downloads, "downloads.finalize_promotion_rejected", fields: [
                "download_id": .identifier(key.ratingKey), "phase": .label(phase),
                "reason": .label("reset_pending")])
        case .invalidWorkingLayout:
            AppDiagnostics.record(.downloads, "downloads.finalize_promotion_rejected", fields: [
                "download_id": .identifier(key.ratingKey), "phase": .label(phase),
                "reason": .label("invalid_working_layout")])
        case .sourceMissing:
            AppDiagnostics.record(.downloads, "downloads.finalize_promotion_rejected", fields: [
                "download_id": .identifier(key.ratingKey), "phase": .label(phase),
                "reason": .label("source_missing")])
        case .invalidTerminalStatus:
            shouldSurfaceFailure = false
            assertionFailure("Only complete/unverified may publish a validated attempt")
        case .renameFailed(let errorType):
            AppDiagnostics.record(.downloads, "downloads.finalize_promotion_failed", fields: [
                "download_id": .identifier(key.ratingKey), "phase": .label(phase),
                "reason": .label("rename_failed"), "error_type": .label(errorType)])
        case .persistenceFailed(_, let persistence):
            // A committed pending-promotion intent may already own recovery after relaunch. Do not
            // overwrite it with `.failed`; surface the problem now and let exact intent recovery
            // finish the publication safely.
            shouldMarkFailed = false
            AppDiagnostics.record(.downloads, "downloads.finalize_promotion_failed", fields: [
                "download_id": .identifier(key.ratingKey), "phase": .label(phase),
                "reason": .label("persistence_failed"),
                "persistence": .label(String(describing: persistence))])
        }
        if shouldSurfaceFailure {
            if shouldMarkFailed { _ = resolveLifecycleSubmission(store.submitStatus(for: key, .failed)) }
            onError?(key.ratingKey, .transferFailed(
                "Downloaded file was verified but could not be published. Retry the download."))
            onChange?()
        }
        return false
    }

    private func recordFinalizeFinished(ratingKey: String,
                                        result: String,
                                        validationLabel: String,
                                        durationMs: Int,
                                        bytes: Int) {
        AppDiagnostics.record(.downloads, "downloads.finalize_finished", fields: [
            "download_id": .identifier(ratingKey),
            "result": .label(result),
            "validation": .label(validationLabel),
            "duration_ms": .int(durationMs),
            "duration_bucket": .millisecondsBucket(durationMs),
            "bytes": .bytes(bytes),
        ])
    }


    /// - Parameter timeoutSecondsOverride: when set, overrides the policy's ready/play deadline.
    ///   Used by the GH #98 retry to give a busy device more time before condemning a complete file.
    /// - Returns: `detail` carries `AVPlayerItem.error` on an `item_failed` result, for diagnosis.
    private func validateLocalPlayback(_ url: URL, timeoutSecondsOverride: Double? = nil)
        async -> (played: Bool, reason: String, durationMs: Int?, detail: String?) {
        if let injectedPlaybackValidator {
            let result = await injectedPlaybackValidator(url, timeoutSecondsOverride)
            return (result.played, result.reason, result.durationMs, result.detail)
        }
        return await Self.validateLocalPlaybackUsingAVFoundation(
            url, timeoutSecondsOverride: timeoutSecondsOverride)
    }

    private static func validateLocalPlaybackUsingAVFoundation(
        _ url: URL, timeoutSecondsOverride: Double? = nil
    ) async -> (played: Bool, reason: String, durationMs: Int?, detail: String?) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        var durationMs: Int?
        let timeoutSeconds = timeoutSecondsOverride ?? OfflinePlaybackValidationPolicy.make(durationMs: nil).timeoutSeconds
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeoutSeconds * 1000)))
        var sawReady = false
        var stalledReadyItem: AVPlayerItem?
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else {
                return (false, "cancelled", durationMs, nil)
            }
            switch item.status {
            case .failed:
                return (false, "item_failed", durationMs,
                        item.error.map { DiagnosticRedactor.safeErrorSummary($0) })
            case .readyToPlay:
                sawReady = true
                stalledReadyItem = item
                if durationMs == nil {
                    durationMs = Self.durationMilliseconds(from: item.duration)
                }
            case .unknown:
                break
            @unknown default:
                break
            }
            let policy = OfflinePlaybackValidationPolicy.make(durationMs: durationMs)
            let seconds = player.currentTime().seconds
            if sawReady, seconds.isFinite, seconds >= policy.requiredPlaybackSeconds {
                return (true, "played", durationMs, nil)
            }
            do {
                try await Task.sleep(for: .milliseconds(policy.pollIntervalMilliseconds))
            } catch {
                return (false, "cancelled", durationMs, nil)
            }
        }

        // A hidden muted AVPlayer can occasionally reach `.readyToPlay` but never advance wall-clock
        // time while the app is inactive/background-throttled (observed during #227 Mac lid-sleep
        // testing). Do not make the user manually start playback just to promote an otherwise-good
        // download. If AVPlayer says the local item is ready but realtime playback did not tick,
        // fall back to bounded AVFoundation asset/decode checks before preserving as `.unverified`.
        if sawReady {
            guard !Task.isCancelled else {
                return (false, "cancelled", durationMs, nil)
            }
            let fallback = await validateReadyLocalAsset(asset, readyItem: stalledReadyItem,
                                                         knownDurationMs: durationMs)
            guard !Task.isCancelled else {
                return (false, "cancelled", durationMs, nil)
            }
            if fallback.played {
                return fallback
            }
            if durationMs == nil {
                durationMs = fallback.durationMs
            }
        }

        return (false, sawReady ? "no_playback_progress" : "timeout_not_ready", durationMs, nil)
    }

    private static func validateReadyLocalAsset(_ asset: AVURLAsset,
                                                readyItem: AVPlayerItem?,
                                                knownDurationMs: Int?) async
        -> (played: Bool, reason: String, durationMs: Int?, detail: String?) {
        let fallbackTimeoutSeconds = 4.0
        do {
            return try await withThrowingTaskGroup(
                of: (played: Bool, reason: String, durationMs: Int?, detail: String?).self
            ) { group in
                group.addTask {
                    try await Task.sleep(for: .milliseconds(Int(fallbackTimeoutSeconds * 1000)))
                    return (false, "decode_fallback_timeout", knownDurationMs, nil)
                }
                group.addTask {
                    let isPlayable = (try? await asset.load(.isPlayable)) ?? false
                    guard isPlayable else {
                        return (false, "asset_not_playable", knownDurationMs, nil)
                    }

                    let duration = (try? await asset.load(.duration)) ?? readyItem?.duration ?? .invalid
                    let durationMs = Self.durationMilliseconds(from: duration) ?? knownDurationMs
                    let hasVideo = ((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty == false
                    guard hasVideo else {
                        // Audio-only downloads cannot produce a frame, but a ready playable asset with a
                        // finite duration is the best bounded local proof we can get without relying on
                        // realtime player advancement.
                        if durationMs != nil {
                            return (true, "asset_playable", durationMs, nil)
                        }
                        return (false, "asset_duration_unknown", durationMs, nil)
                    }

                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                    let requestedSeconds = min(0.5, max(0.0, (duration.seconds.isFinite ? duration.seconds : 1.0) * 0.05))
                    _ = try await generator.image(at: CMTime(seconds: requestedSeconds,
                                                             preferredTimescale: 600)).image
                    return (true, "decoded_frame", durationMs, nil)
                }
                let result = try await group.next() ?? (false, "decode_fallback_timeout", knownDurationMs, nil)
                group.cancelAll()
                return result
            }
        } catch {
            return (false, "decode_fallback_failed", knownDurationMs,
                    DiagnosticRedactor.safeErrorSummary(error))
        }
    }

    private static func durationMilliseconds(from time: CMTime) -> Int? {
        guard time.seconds.isFinite, time.seconds > 0 else { return nil }
        return Int(time.seconds * 1000)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard !rejectTaskCallback(task) else { return }
        // #169: opaque and range tasks now share ONE session, so the task id uniquely identifies its
        // lane (no independent id spaces). A range task's SUCCESS path is fully handled in
        // `finishRangeRemainder` (which removes the entry), so a range entry still present here means the
        // task errored or was cancelled before finishing.
        lock.lock()
        let superseded = supersededRangeTaskIdentifiers.remove(task.taskIdentifier) != nil
        let rangeEntry = superseded ? nil : rangeInflight.removeValue(forKey: task.taskIdentifier)
        let entry = (rangeEntry == nil && !superseded) ? inflight.removeValue(forKey: task.taskIdentifier) : nil
        loggedExpectation.remove(task.taskIdentifier)
        loggedProgressMilestones.removeValue(forKey: task.taskIdentifier)
        lastRangeProgressDiagnostic.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if superseded {
            AppDiagnostics.record(.downloads, "downloads.range_superseded_complete_ignored", fields: [
                "task_id": .int(task.taskIdentifier),
                "had_error": .bool(error != nil),
            ])
            return
        }

        if let rangeEntry {
            // Deletion can become pending after the delegate entry passed `rejectTaskCallback`
            // but before this completion owns its extracted Range entry. Re-check exact ownership
            // and the sealed-row barrier before choosing any disposition: the branches below can
            // purge held bodies, replace resume data, change status, or start replacement tasks.
            guard stillOwnsAttempt(
                rangeEntry.attemptKey, phase: "range_error_completion") else { return }
            let rangeDisposition = BackgroundRangeCompletionPolicy.disposition(
                hasError: error != nil,
                errorCode: error.map { ($0 as NSError).code },
                hasRequest: rangeEntry.request != nil
            )
            guard let error else { return } // success already handled in finishRangeRemainder
            let nsError = error as NSError
            if case .cancelled = rangeDisposition {
                downloadLog.info("range-cancelled ratingKey=\(rangeEntry.ratingKey, privacy: .public) bytes=\(rangeEntry.totalBytes, privacy: .public)")
                AppDiagnostics.record(.downloads, "downloads.range_cancelled", fields: [
                    "download_id": .identifier(rangeEntry.ratingKey),
                    "bytes": .bytes(rangeEntry.totalBytes),
                ])
                return
            }
            // Disk full surfaces from URLSession as a wrapped ENOSPC/Cocoa-640 failure and cannot
            // be blob-resumed or retried in place — a "resumable" pause here immediately fails
            // again on the next byte. Fail with the real reason and tear the train down; the
            // durable partial stays as the checkpoint for after the user frees space.
            if DownloadDiskSpacePolicy.isOutOfSpace(nsError) {
                let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: rangeEntry.attemptKey, expectedBytes: rangeEntry.expectedBytes,
                context: "completion_storage_full"
            ) ?? rangeEntry.baseOffset
                var fields: [String: DiagnosticFieldValue] = [
                    "download_id": .identifier(rangeEntry.ratingKey),
                    "context": .label("task_completion"),
                    "bytes": .bytes(durableBytes),
                ]
                if let free = availableStorageBytes() {
                    fields["free_bytes"] = .bytes(Int(free))
                    fields["free_bytes_exact"] = .int(Int(free))
                }
                AppDiagnostics.record(.downloads, "downloads.range_storage_full", fields: fields)
                setFailedPurgingHeldSegments(for: rangeEntry.attemptKey)
                onError?(rangeEntry.ratingKey, .storageFull)
                onChange?()
                return
            }
            // #227: a failed continuous remainder may carry many GB of non-durable temp in the
            // resume data the OS handed back — re-resume from the blob (budget-bounded) before
            // falling to a fresh-request retry that would discard it. The append-time
            // Content-Range/validator checks keep a strangely-resumed body from corrupting the
            // durable partial (worst case is a wasted fetch).
            let rangeResumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let blobResumeAttempt = resumeRangeAfterFailure(
                entry: rangeEntry,
                error: nsError,
                resumeData: rangeResumeData
            )
            switch blobResumeAttempt {
            case .resumed:
                return
            case .rejectedResumeData:
                if restartRangeFromDurableCheckpointAfterResumeDataFailure(
                    entry: rangeEntry,
                    error: nsError,
                    reason: .resumeDataRejected
                ) {
                    return
                }
            case .notAttempted:
                break
            }
            if retryTransientRangeFailure(nsError, task: task, entry: rangeEntry) {
                return
            }
            if let fallbackReason = StaticRangeResumeDataPolicy.durableFallbackReason(
                errorDomain: nsError.domain,
                errorCode: nsError.code,
                hasResumeData: rangeResumeData?.isEmpty == false
            ), restartRangeFromDurableCheckpointAfterResumeDataFailure(
                entry: rangeEntry,
                error: nsError,
                reason: fallbackReason
            ) {
                return
            }
            // Parking (paused/queued): keep the blob so a manual Resume — even after a relaunch —
            // continues the remainder's temp progress instead of re-fetching it.
            if rangeEntry.segmentLength == nil,
               StaticRangeResumeDataPolicy.shouldPersistBlobOnPark(
                hasResumeData: rangeResumeData?.isEmpty == false,
                resumeDataWasRejected: blobResumeAttempt == .rejectedResumeData
            ), let rangeResumeData {
                let displayBytes: Int
                if rangeEntry.segmentLength != nil {
                    // B1 (failure-driven park): under a segment train the paused-row watermark must be
                    // the honest downloaded aggregate (durable + Σ live segment bodies, including this
                    // failing segment's temp that the blob carries) — NOT this segment's file position
                    // `baseOffset + body`. An off-head blob whose offset != durable is discarded on
                    // Resume, which clears this watermark (B2 rejectStale).
                    guard let durable = store.durableStaticRangeCheckpointSize(
                        for: rangeEntry.attemptKey) else { return }
                    lock.lock()
                    var bodies = rangeInflight.values
                        .filter { $0.ratingKey == rangeEntry.ratingKey }
                        .map(\.bodyBytesWritten)
                    bodies.append(contentsOf: heldRangeSegments[rangeEntry.attemptKey]?.values.map(\.length) ?? [])
                    lock.unlock()
                    let reportedBodyBytes = max(
                        rangeEntry.bodyBytesWritten,
                        Int(max(task.countOfBytesReceived, 0)))
                    bodies.append(DownloadLiveRangeProgressPolicy.accountedTaskBodyBytes(
                        reportedBytes: reportedBodyBytes,
                        segmentLength: rangeEntry.segmentLength))
                    displayBytes = DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
                        durableBytes: durable, liveSegmentBodyBytes: bodies)
                } else {
                    displayBytes = rangeEntry.baseOffset + max(rangeEntry.bodyBytesWritten, Int(max(task.countOfBytesReceived, 0)))
                }
                resolveLifecycleSubmission(store.submitResumeData(for: rangeEntry.attemptKey, rangeResumeData, displayBytes: displayBytes))
            }
            // A non-transient interruption (commonly a long headset-off that outlived the OS's own
            // retry, or connectivity loss) leaves the durable partial's completed bytes intact — the
            // failed remainder's bytes were in the OS temp, never appended — so surface a resumable
            // pause rather than a failure. The partial IS the checkpoint; Resume re-requests only the
            // in-flight remainder from its current size.
            let summary = DiagnosticRedactor.safeErrorSummary(error)
            guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: rangeEntry.attemptKey, expectedBytes: rangeEntry.expectedBytes,
                context: "completion_pause"
            ) else { return }
            downloadLog.error("range-paused ratingKey=\(rangeEntry.ratingKey, privacy: .public) error=\(summary, privacy: .public) bytes=\(durableBytes, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.range_paused", fields: [
                "download_id": .identifier(rangeEntry.ratingKey),
                "error": .error(error),
                "base_offset": .int(rangeEntry.baseOffset),
                "optimistic_temp_bytes": .bytes(rangeEntry.bodyBytesWritten),
                "bytes": .bytes(durableBytes),
            ])
            if case .requestNeeded(let reason) = rangeDisposition {
                // Adopted failed remainders were active system work, not user pauses. Persist queued
                // intent before the callback so backend restore can be missed/terminated safely.
                // Hold the background completion handler across the main-actor request rebuild
                // (#212): releasing it here lets the OS suspend us before the next task exists.
                beginRangeRequestRebuildGrace(for: rangeEntry.attemptKey)
                _ = resolveLifecycleSubmission(store.submitStatus(for: rangeEntry.attemptKey, .queued))
                onRangeRequestNeeded?(rangeEntry.ratingKey, reason)
                return
            }
            _ = resolveLifecycleSubmission(store.submitStatus(for: rangeEntry.attemptKey, .paused))
            onError?(rangeEntry.ratingKey, .interruptedResumable)
            onChange?()
            return
        }

        guard let entry, let error else { return }
        guard stillOwnsAttempt(entry.attemptKey, phase: "opaque_completion") else { return }
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let hasResumeData = resumeData?.isEmpty == false
        let supportsResumeData = hasResumeData && supportsPersistedResumeData(for: entry.attemptKey)
        let opaqueDisposition = BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: nsError.code,
            hasResumeData: hasResumeData,
            supportsPersistedResumeData: supportsResumeData
        )
        // A cancel is not a failure. Any other error keeps a `.failed` row (D3) with a
        // surfaced reason, rather than silently erasing it so the UI can offer retry.
        switch opaqueDisposition {
        case .cancelled:
            clearRetryCount(for: entry.attemptKey)
            downloadLog.info("cancelled ratingKey=\(entry.ratingKey, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.cancelled", fields: [
                "download_id": .identifier(entry.ratingKey),
            ])
        case .pauseWithResumeData, .failNonResumableStream, .fail:
            if retryTransientFailure(nsError, task: task, entry: entry) {
                return
            }
            // #95: a recoverable interruption (commonly a long headset-off, which can produce an
            // error OUTSIDE the narrow transient set yet still hand back resume data) should be
            // treated as PAUSED-and-resumable, not failed. Branch on the PRESENCE of resume data
            // rather than the error code, persist the blob so a manual Resume — even after a
            // relaunch — continues from the offset, and surface a non-red "will resume" state.
            // The partial bytes are retained (reconcile keeps a `.paused` row's file).
            if case .failNonResumableStream = opaqueDisposition {
                let summary = DiagnosticRedactor.safeErrorSummary(error)
                downloadLog.error("transfer-nonresumable ratingKey=\(entry.ratingKey, privacy: .public) error=\(summary, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public) resumeData=true")
                AppDiagnostics.record(.downloads, "downloads.transfer_nonresumable", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "error": .error(error),
                    "bytes_received": .bytes(Int(task.countOfBytesReceived)),
                    "resume_data_present": .bool(true),
                ])
                clearRetryCount(for: entry.attemptKey)
                setFailedPurgingHeldSegments(for: entry.attemptKey)
                onError?(entry.ratingKey, .transferFailed("Download interrupted; this transcoded stream can’t resume from its byte offset. Retry will restart from the beginning."))
                onChange?()
                return
            }
            if case .pauseWithResumeData = opaqueDisposition, let resumeData {
                let displayBytes = Int(max(task.countOfBytesReceived, 0))
                let summary = DiagnosticRedactor.safeErrorSummary(error)
                downloadLog.error("transfer-paused ratingKey=\(entry.ratingKey, privacy: .public) error=\(summary, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public)")
                AppDiagnostics.record(.downloads, "downloads.transfer_paused", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "error": .error(error),
                    "bytes_received": .bytes(Int(task.countOfBytesReceived)),
                ])
                resolveLifecycleSubmission(store.submitResumeData(for: entry.attemptKey, resumeData, displayBytes: displayBytes))
                clearRetryCount(for: entry.attemptKey)
                _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .paused))
                onError?(entry.ratingKey, .interruptedResumable)
                onChange?()
                return
            }
            let summary = DiagnosticRedactor.safeErrorSummary(error)
            downloadLog.error("transfer-failed ratingKey=\(entry.ratingKey, privacy: .public) error=\(summary, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.transfer_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "error": .error(error),
                "bytes_received": .bytes(Int(task.countOfBytesReceived)),
            ])
            clearRetryCount(for: entry.attemptKey)
            setFailedPurgingHeldSegments(for: entry.attemptKey)
            onError?(entry.ratingKey, .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer")))
        }
        onChange?()
    }

    private func recordRangeProgressIfNeeded(taskIdentifier: Int,
                                             entry: RangeTransfer,
                                             bodyBytes: Int,
                                             totalBytes: Int,
                                             aggregateBytes: Int,
                                             expectedBytes: Int?,
                                             progress: Double,
                                             firstCallback: Bool) {
        let now = Date()
        lock.lock()
        let shouldRecord = BackgroundDownloadProgressPolicy.shouldRecordRangeProgress(
            last: lastRangeProgressDiagnostic[taskIdentifier],
            now: now,
            totalBytes: totalBytes,
            byteInterval: Self.rangeProgressDiagnosticByteInterval,
            isFirstCallback: firstCallback
        )
        if shouldRecord {
            lastRangeProgressDiagnostic[taskIdentifier] = BackgroundRangeProgressDiagnosticSnapshot(
                time: now,
                bytes: totalBytes
            )
        }
        lock.unlock()

        guard shouldRecord else { return }
        AppDiagnostics.record(.downloads, "downloads.range_progress", fields: [
            "download_id": .identifier(entry.ratingKey),
            "task_id": .int(taskIdentifier),
            // Per-TASK facts: `base_offset` is this segment's file position, `body_bytes` its own temp
            // body, and `total_bytes` == base_offset + body_bytes (this task's file position, NOT the
            // row's downloaded total — for a segment train it can be far ahead of what's transferred).
            "base_offset": .int(entry.baseOffset),
            "body_bytes": .int(bodyBytes),
            "total_bytes": .int(totalBytes),
            // ROW-level display total = durable checkpoint + Σ(live segment bodies), the same value the
            // UI shows. For the single open-ended remainder `aggregate_bytes == total_bytes`; for a
            // segment train it is the honest downloaded aggregate across all live segments.
            "aggregate_bytes": .int(aggregateBytes),
            "expected_exact": .int(expectedBytes ?? -1),
            "progress_percent": .int(Int((progress * 100).rounded(.down))),
        ])
    }

    private func notifyProgressChangeIfNeeded(ratingKey _: String, progress: Double) {
        let now = Date()
        lock.lock()
        let last = lastProgressNotify
        let shouldNotify = BackgroundDownloadProgressPolicy.shouldNotifyProgressChange(
            lastNotification: last,
            now: now,
            progress: progress,
            interval: progressNotifyInterval
        )
        if shouldNotify { lastProgressNotify = now }
        lock.unlock()
        if shouldNotify { onChange?() }
    }

    private func clearRetryCount(for attemptKey: DownloadAttemptKey) {
        lock.lock()
        retryCounts.removeValue(forKey: attemptKey)
        rangeHTTPRehydrateCounts.removeValue(forKey: attemptKey)
        rangeBlobResumeCounts.removeValue(forKey: attemptKey)
        lastProgressNotify = nil
        lock.unlock()
    }

    private enum RangeBlobResumeAttempt: Equatable {
        case resumed
        case rejectedResumeData
        case notAttempted
    }

    /// Resume transient transfer drops before surfacing a failed row. Plex/static-file
    /// downloads can start successfully and then lose the TCP stream mid-body (`-1005`);
    /// URLSession gives us resume data in that case, so failing immediately throws away
    /// exactly the recovery mechanism the OS provides.
    private func retryTransientFailure(_ error: NSError,
                                       task: URLSessionTask,
                                       entry: OpaqueTransfer) -> Bool {
        let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let hasResumeData = resumeData?.isEmpty == false
        // #95: JF/Emby optimized downloads are live transcode streams; do not offset-resume them
        // even if URLSession hands back a blob. Let the caller surface a restart-required failure
        // instead of silently trying a 200-full-restart/416-prone resume.
        let isTransientURLFailure = error.domain == NSURLErrorDomain
            && BackgroundDownloadTransientRetryPolicy.transientErrorCodes.contains(error.code)
        let supportsResumeData = isTransientURLFailure
            && hasResumeData
            && supportsPersistedResumeData(for: entry.attemptKey)

        lock.lock()
        let decision = BackgroundDownloadTransientRetryPolicy.opaqueDownloadDecision(
            errorDomain: error.domain,
            errorCode: error.code,
            hasResumeData: hasResumeData,
            supportsResumeData: supportsResumeData,
            currentRetryCount: retryCounts[entry.attemptKey] ?? 0
        )
        guard case .retry(let nextAttempt) = decision,
              let resumeData,
              !resumeData.isEmpty else {
            lock.unlock()
            return false
        }
        retryCounts[entry.attemptKey] = nextAttempt
        lock.unlock()

        let retryTask = urlSession.downloadTask(withResumeData: resumeData)
        retryTask.taskDescription = DownloadAttemptMarker.taskDescription(
            ratingKey: entry.ratingKey, attemptID: entry.attemptID)
        lock.lock()
        inflight[retryTask.taskIdentifier] = entry
        loggedProgressMilestones[retryTask.taskIdentifier] = []
        lock.unlock()
        downloadLog.error("transfer-retry ratingKey=\(entry.ratingKey, privacy: .public) attempt=\(nextAttempt, privacy: .public) code=\(error.code, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.transfer_retry", fields: [
            "download_id": .identifier(entry.ratingKey),
            "attempt": .int(nextAttempt),
            "error": .error(error),
            "bytes_received": .bytes(Int(task.countOfBytesReceived)),
        ])
        retryTask.resume()
        onChange?()
        return true
    }

    /// App-managed Range downloads write into the final partial file, so a transient connection
    /// loss can be retried by issuing a fresh Range request from the now-durable file size. Do that
    /// before surfacing `.paused`; otherwise fragile long HTTPS range streams can force the user to
    /// tap Resume every couple of megabytes even though each retry is making forward progress.
    private func retryTransientRangeFailure(_ error: NSError,
                                            task: URLSessionTask,
                                            entry: RangeTransfer) -> Bool {
        // No in-memory request (a relaunch-adopted remainder) means we can't reissue here; fall through
        // to the resumable-pause path so DownloadManager rebuilds the request and resumes.
        lock.lock()
        let decision = BackgroundDownloadTransientRetryPolicy.rangeDecision(
            errorDomain: error.domain,
            errorCode: error.code,
            hasRequest: entry.request != nil,
            currentRetryCount: retryCounts[entry.attemptKey] ?? 0
        )
        guard case .retry(let nextAttempt) = decision,
              let request = entry.request else {
            lock.unlock()
            return false
        }
        retryCounts[entry.attemptKey] = nextAttempt
        lock.unlock()

        guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "transient_retry"
            ) else { return false }
        downloadLog.error("range-retry ratingKey=\(entry.ratingKey, privacy: .public) attempt=\(nextAttempt, privacy: .public) code=\(error.code, privacy: .public) bytes=\(durableBytes, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.range_retry", fields: [
            "download_id": .identifier(entry.ratingKey),
            "attempt": .int(nextAttempt),
            "error": .error(error),
            "bytes": .bytes(durableBytes),
        ])

        do {
            try startRangeRemainder(ratingKey: entry.ratingKey,
                                with: request,
                                to: entry.workingURL,
                                expectedBytes: entry.expectedBytes,
                                resetsRetryCount: false,
                                attemptID: entry.attemptID)
            onChange?()
            return true
        } catch {
            if shouldSuppressRangeStartFailure(for: entry.attemptKey,
                                               error: error,
                                               context: "transient_retry") {
                onChange?()
                return true
            }
            if handleRangeStartStorageFull(for: entry.attemptKey,
                                           error: error,
                                           context: "transient_retry") {
                return true
            }
            AppDiagnostics.record(.downloads, "downloads.range_retry_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "attempt": .int(nextAttempt),
                "error": .error(error),
            ])
            return false
        }
    }

    /// #227: re-resume a failed continuous remainder from the resume data the OS handed back,
    /// preserving its non-durable temp bytes. Budget-bounded; halted rows never resume.
    private func resumeRangeAfterFailure(entry: RangeTransfer,
                                         error: NSError,
                                         resumeData: Data?) -> RangeBlobResumeAttempt {
        lock.lock()
        let decision = StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: error.code,
            hasResumeData: resumeData?.isEmpty == false,
            currentBlobResumeCount: rangeBlobResumeCounts[entry.attemptKey] ?? 0,
            isClosedRange: entry.segmentLength != nil
        )
        guard case .resume(let nextAttempt) = decision, let resumeData else {
            lock.unlock()
            if case .reject(.budgetExhausted(_, _)) = decision,
               resumeData?.isEmpty == false {
                return .rejectedResumeData
            }
            return .notAttempted
        }
        rangeBlobResumeCounts[entry.attemptKey] = nextAttempt
        lock.unlock()
        guard !isRangeHalted(for: entry.attemptKey) else { return .notAttempted }
        downloadLog.error("range-blob-resume ratingKey=\(entry.ratingKey, privacy: .public) attempt=\(nextAttempt, privacy: .public) code=\(error.code, privacy: .public)")
        return adoptBlobResumedRangeTask(ratingKey: entry.ratingKey,
                                         resumeData: resumeData,
                                         request: entry.request,
                                         destination: entry.workingURL,
                                         expectedBytes: entry.expectedBytes,
                                         remainderReason: "blob_resume",
                                         attempt: nextAttempt,
                                         // Only a CLOSED train segment retries in place; an
                                         // open-ended remainder keeps the durable-offset rule.
                                         retryingSegment: entry.segmentLength != nil ? entry : nil)
            ? .resumed
            : .rejectedResumeData
    }

    /// URLSession can reject resume data after creating the task (for example when the persisted
    /// temp disappeared). In that case discard the blob and immediately fall back to the durable
    /// partial size by issuing a fresh open-ended Range request, or ask DownloadManager to rebuild
    /// one if this was a relaunch-adopted task with no request in memory.
    private func restartRangeFromDurableCheckpointAfterResumeDataFailure(
        entry: RangeTransfer,
        error: NSError,
        reason: StaticRangeResumeDataPolicy.DurableFallbackReason
    ) -> Bool {
        // Clear the blob budget even when halted: falling back to the durable checkpoint ends this
        // blob lifecycle regardless, and a halted (paused) row must not carry the dead budget into
        // its next user resume. Clearing a counter is safe behind a halt; starting work is not.
        lock.lock()
        rangeBlobResumeCounts.removeValue(forKey: entry.attemptKey)
        lock.unlock()

        guard !isRangeHalted(for: entry.attemptKey) else { return false }

        guard let durableBytes = resetStaticRangeProgressToDurableCheckpoint(
                for: entry.attemptKey, expectedBytes: entry.expectedBytes,
                context: "resume_data_fallback"
            ) else { return false }
        AppDiagnostics.record(.downloads, "downloads.range_resume_data_fallback", fields: [
            "download_id": .identifier(entry.ratingKey),
            "reason": .label(reason.rawValue),
            "error": .error(error),
            "base_offset": .int(entry.baseOffset),
            "checkpoint_bytes": .bytes(durableBytes),
            "discarded_temp_bytes": .bytes(entry.bodyBytesWritten),
        ])

        guard let request = entry.request else {
            beginRangeRequestRebuildGrace(for: entry.attemptKey)
            _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .queued))
            onRangeRequestNeeded?(entry.ratingKey, .requestRebuildNeeded)
            return true
        }

        do {
            try startRangeRemainder(
                ratingKey: entry.ratingKey,
                with: request,
                to: entry.workingURL,
                expectedBytes: entry.expectedBytes,
                resetsRetryCount: false,
                remainderReasonOverride: reason.rawValue,
                attemptID: entry.attemptID
            )
            onChange?()
            return true
        } catch {
            if shouldSuppressRangeStartFailure(
                for: entry.attemptKey,
                error: error,
                context: "resume_data_fallback"
            ) {
                onChange?()
                return true
            }
            if handleRangeStartStorageFull(for: entry.attemptKey,
                                           error: error,
                                           context: "resume_data_fallback") {
                return true
            }
            AppDiagnostics.record(.downloads, "downloads.range_resume_data_fallback_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "reason": .label(reason.rawValue),
                "error": .error(error),
                "checkpoint_bytes": .bytes(durableBytes),
            ])
            return false
        }
    }

    /// Create and register a Range-lane task from a URLSession resume blob. The blob's original
    /// Range offset must equal the durable partial size, or the blob is stale (the partial
    /// advanced, or the blob is from another lifecycle) and must not become authoritative.
    /// `retryingSegment` marks the in-process failure retry of a LIVE train segment: the blob is
    /// then judged against that segment's own base offset (not durable, which belongs to the
    /// head), and adoption replaces only that segment — the rest of the train stays running, so
    /// no supersede sweep and no refill.
    private func adoptBlobResumedRangeTask(ratingKey: String,
                                           resumeData: Data,
                                           request: URLRequest?,
                                           destination: URL,
                                           expectedBytes: Int?,
                                           remainderReason: String,
                                           attempt: Int?,
                                           retryingSegment failedSegment: RangeTransfer? = nil) -> Bool {
        let attemptID: DownloadAttemptID
        if let failedSegment {
            attemptID = failedSegment.attemptID
        } else if let current = currentAttemptIdentity(ratingKey: ratingKey) {
            attemptID = current
        } else {
            return false
        }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard store.ownsAttempt(attemptKey),
              let workingDestination = store.attemptWorkingFileURL(for: attemptKey) else { return false }
        let destination = workingDestination
        let task = urlSession.downloadTask(withResumeData: resumeData)
        task.taskDescription = DownloadAttemptMarker.taskDescription(ratingKey: ratingKey,
                                                                     attemptID: attemptID)
        let blobOffset = RangeTransferHTTPPolicy.rangeRequestStart(from: task.originalRequest)
            ?? RangeTransferHTTPPolicy.rangeRequestStart(from: task.currentRequest)
        let durableBytes = fileSize(at: destination) ?? 0
        let blobRangeHeader = (task.originalRequest ?? task.currentRequest)?
            .value(forHTTPHeaderField: "Range")
        // Migration/backstop for blobs persisted by earlier builds. Even when the original
        // request still says `bytes=start-end`, CFNetwork may replay the blob beyond `end`; reject
        // every closed-range blob before it becomes an authoritative live task.
        if !StaticRangeResumeDataPolicy.shouldAdoptBlob(
            hasClosedRangeEnd: RangeTransferHTTPPolicy.rangeRequestEnd(blobRangeHeader) != nil
        ) {
            task.cancel()
            _ = resolveLifecycleSubmission(store.submitClearResumeData(for: attemptKey))
            AppDiagnostics.record(.downloads, "downloads.range_closed_blob_refused", fields: [
                "download_id": .identifier(ratingKey),
                "blob_offset": .int(blobOffset ?? -1),
                "durable_bytes": .int(durableBytes),
                "reason": .label(remainderReason),
            ])
            return false
        }
        switch StaticRangeResumeDataPolicy.adoptionDecision(blobRangeOffset: blobOffset,
                                                            durableBytes: durableBytes,
                                                            segmentBaseOffset: failedSegment?.baseOffset) {
        case .rejectStale(let blobOffset, let durableBytes):
            task.cancel()
            // B2: the persisted blob no longer matches the durable partial, so it can never resume
            // (the transfer will fall back to a fresh Range from `durableBytes`). Drop the stale blob
            // AND its display watermark in the same breath, or the paused/queued row keeps claiming a
            // byte position the transfer no longer holds (the "resuming from another point" leak).
            _ = resolveLifecycleSubmission(store.submitClearResumeData(for: attemptKey))
            AppDiagnostics.record(.downloads, "downloads.range_blob_resume_stale", fields: [
                "download_id": .identifier(ratingKey),
                "blob_offset": .int(blobOffset ?? -1),
                "durable_bytes": .int(durableBytes),
                "reason": .label(remainderReason),
            ])
            return false
        case .adopt(let baseOffset):
            // The caller's expectedBytes is often nil on resume-from-pause: the manager derives it
            // from bytes/progress, which is unknowable at durable 0. The store's static-lane exact
            // source size (recorded at first train start) is authoritative — without it the refill
            // below can't plan and the finish validator loses the tail clamp.
            let expectedBytes = expectedBytes ?? store.sourceExactBytes(for: attemptKey)
            // A blob persisted from a CLOSED head segment must come back as a segment: recover its
            // length from the blob's own Range header (URLSession keeps the original request). With
            // segmentLength nil the finish validator judges the body against the whole-file
            // remainder — and a resumed task's Content-Range starts at the blob's byte position, so
            // the completed segment would trip the offset-mismatch path and be discarded. A legacy
            // open-ended blob (`bytes=N-`) has no end bound and stays nil (unchanged semantics).
            let blobSegmentLength: Int? = {
                let start = RangeTransferHTTPPolicy.rangeRequestStart(blobRangeHeader) ?? baseOffset
                guard let end = RangeTransferHTTPPolicy.rangeRequestEnd(blobRangeHeader),
                      end >= start else { return nil }
                return end - start + 1
            }()
            // Keep the authenticated base request when the caller still holds it so a short
            // resumed body can start the next open-ended remainder in-session; the blob's own original
            // request is the fallback (it carries the auth headers URLSession persisted).
            let entry = RangeTransfer(
                ratingKey: ratingKey,
                attemptID: attemptID,
                request: request ?? task.originalRequest,
                destination: destination,
                expectedBytes: expectedBytes,
                baseOffset: baseOffset,
                segmentLength: blobSegmentLength,
                responseStatus: nil,
                bodyBytesWritten: 0,
                remainderReason: remainderReason)
            if failedSegment != nil, blobSegmentLength != nil {
                task.taskDescription = StaticRangeSegmentMarker.taskDescription(
                    ratingKey: ratingKey, offset: baseOffset, attemptID: attemptID)
            }
            lock.lock()
            // Retrying one live train segment must not tear down its siblings: sweep only
            // same-offset leftovers. The head-adoption paths (manual Resume / relaunch) keep the
            // full supersede — there the blob IS the sole survivor and the train is rebuilt below.
            let superseded = failedSegment != nil
                ? supersedeRangeSegmentTasksLocked(ratingKey: ratingKey,
                                                   offset: baseOffset,
                                                   keeping: task.taskIdentifier)
                : supersedeRangeTasksLocked(ratingKey: ratingKey, keeping: task.taskIdentifier)
            loggedProgressMilestones[task.taskIdentifier] = []
            lastRangeProgressDiagnostic.removeValue(forKey: task.taskIdentifier)
            rangeInflight[task.taskIdentifier] = entry
            lock.unlock()
            for identifier in superseded {
                cancelURLSessionTask(identifier: identifier)
            }
            endRangeRequestRebuildGrace(for: attemptKey, reason: "blob_resumed")
            guard acceptedAttemptSubmission(resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .downloading)),
                                          key: entry.attemptKey,
                                          phase: "blob_resume_status") else {
                task.cancel()
                return false
            }
            AppDiagnostics.record(.downloads, "downloads.range_blob_resume", fields: [
                "download_id": .identifier(ratingKey),
                "task_id": .int(task.taskIdentifier),
                "base_offset": .int(baseOffset),
                "segment_length": .int(blobSegmentLength ?? -1),
                "resume_blob_bytes": .bytes(resumeData.count),
                "attempt": .int(attempt ?? 0),
                "reason": .label(remainderReason),
            ])
            task.resume()
            // The blob resumes ONLY the head segment; without a refill the row runs at
            // single-segment depth until that head finishes. Top the train back up behind it —
            // the head's offset is already registered as a live segment, so the planner enqueues
            // only the trailing segments. Closed blobs with a known total only: an unknown total
            // plans an open-ended remainder that would double-cover (and supersede) the head.
            if StaticRangeTransferRegime.current == .segmentTrain,
               failedSegment == nil, // in-process segment retry: train is intact, nothing to refill
               blobSegmentLength != nil,
               expectedBytes != nil,
               let baseRequest = entry.request {
                do {
                    try startRangeRemainder(ratingKey: ratingKey,
                                            with: baseRequest,
                                            to: destination,
                                            expectedBytes: expectedBytes,
                                            resetsRetryCount: false,
                                            // Keep under 24 chars: the diagnostic redactor's
                                            // generic secret rule blanks longer bare tokens.
                                            remainderReasonOverride: "blob_resume_refill",
                                            attemptID: attemptID)
                } catch {
                    // Non-fatal: the resumed head is running; the train refills on its finish.
                    AppDiagnostics.record(.downloads, "downloads.range_blob_resume_train_refill_failed", fields: [
                        "download_id": .identifier(ratingKey),
                        "error": .error(error),
                    ])
                }
            }
            onChange?()
            return true
        }
    }

    /// #227: resume a `.paused` static byte-range row from a persisted URLSession resume blob
    /// (produced by pausing or failing a continuous remainder). Registers the task in the RANGE
    /// lane — the opaque `resume(...)` would treat the partial-body temp as a whole-file move at
    /// completion and corrupt the durable partial. Returns `false` when the blob is stale or
    /// unusable; the caller falls back to a fresh Range restart from the durable checkpoint.
    @discardableResult
    func resumeRange(ratingKey: String, resumeData: Data, to destination: URL,
                     expectedBytes: Int?) -> Bool {
        guard isStartupAdmissionActive else { return false }
        guard !resumeData.isEmpty else { return false }
        guard let attemptID = currentAttemptIdentity(ratingKey: ratingKey) else { return false }
        let attemptKey = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        guard store.ownsAttempt(attemptKey) else { return false }
        lock.lock()
        rangeHaltKinds.removeValue(forKey: attemptKey)
        // Mirror `start()`'s user-initiated reset: a manual Resume clears ALL restart budgets,
        // not just the blob counter — otherwise a row resumed via persisted blob keeps the prior
        // attempt's rehydrate/validator budgets while a plain Retry would have cleared them.
        rangeBlobResumeCounts.removeValue(forKey: attemptKey)
        staticRangeRetryBudget.reset(key: staticRangeRetryKey(for: attemptKey))
        rangeHTTPRehydrateCounts.removeValue(forKey: attemptKey)
        retryCounts[attemptKey] = 0
        lock.unlock()
        return adoptBlobResumedRangeTask(ratingKey: ratingKey,
                                         resumeData: resumeData,
                                         request: nil,
                                         destination: destination,
                                         expectedBytes: expectedBytes,
                                         remainderReason: "persisted_blob_resume",
                                         attempt: nil)
    }

    /// Auth/forbidden HTTP statuses are not transient edge outages: replaying the same static Range
    /// URL usually repeats the 401/403. Ask the manager/backend layer to rebuild PlaybackInfo /
    /// source selection once while preserving the durable partial-file checkpoint.
    private func requestRangeRehydrationAfterHTTPFailure(statusCode: Int,
                                                         entry: RangeTransfer,
                                                         durableBytes: Int) -> Bool {
        lock.lock()
        let decision = BackgroundDownloadTransientRetryPolicy.rangeRehydrationDecision(
            statusCode: statusCode,
            supportsDurableCheckpoint: true,
            currentRehydrationCount: rangeHTTPRehydrateCounts[entry.attemptKey] ?? 0
        )
        guard case .retry(let nextAttempt) = decision else {
            lock.unlock()
            return false
        }
        rangeHTTPRehydrateCounts[entry.attemptKey] = nextAttempt
        lock.unlock()

        downloadLog.error("range-http-rehydrate ratingKey=\(entry.ratingKey, privacy: .public) attempt=\(nextAttempt, privacy: .public) status=\(statusCode, privacy: .public) bytes=\(durableBytes, privacy: .public)")
        let delay = Self.rangeHTTPRetryDelay(nextAttempt: nextAttempt)
        AppDiagnostics.record(.downloads, "downloads.range_http_rehydrate", fields: [
            "download_id": .identifier(entry.ratingKey),
            "attempt": .int(nextAttempt),
            "max_attempts": .int(BackgroundDownloadTransientRetryPolicy.defaultMaxRangeRehydrations),
            "status_code": .int(statusCode),
            "bytes": .bytes(durableBytes),
            "delay_ms": .int(Int(delay * 1000)),
        ])
        // Persist active intent before the callback so a kill during backend rehydration still leaves
        // a queued static-range row with its durable partial as the checkpoint. Hold the background
        // completion handler across the delayed rebuild (#212).
        beginRangeRequestRebuildGrace(for: entry.attemptKey)
        _ = resolveLifecycleSubmission(store.submitStatus(for: entry.attemptKey, .queued))
        rangeRetryQueue.asyncAfter(deadline: .now() + delay) { [self] in
            onRangeRequestNeeded?(entry.ratingKey, .serverAuthorizationRejected)
            onChange?()
        }
        onChange?()
        return true
    }

    /// HTTP 52x/503-style responses are real server replies, so URLSession reports a successful
    /// transfer and hands us an error-page temp file. Treat those edge/origin statuses like
    /// transient transport drops: keep the partial file checkpoint intact and reissue one
    /// open-ended Range request a few times before surfacing failure.
    private func retryTransientRangeHTTPFailure(statusCode: Int,
                                                entry: RangeTransfer,
                                                durableBytes: Int) -> Bool {
        lock.lock()
        let decision = BackgroundDownloadTransientRetryPolicy.rangeHTTPDecision(
            statusCode: statusCode,
            hasRequest: entry.request != nil,
            supportsDurableCheckpoint: true,
            currentRetryCount: retryCounts[entry.attemptKey] ?? 0
        )
        guard case .retry(let nextAttempt) = decision,
              let request = entry.request else {
            lock.unlock()
            return false
        }
        retryCounts[entry.attemptKey] = nextAttempt
        lock.unlock()

        let delay = Self.rangeHTTPRetryDelay(nextAttempt: nextAttempt)
        downloadLog.error("range-http-retry ratingKey=\(entry.ratingKey, privacy: .public) attempt=\(nextAttempt, privacy: .public) status=\(statusCode, privacy: .public) bytes=\(durableBytes, privacy: .public) delay=\(delay, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.range_http_retry", fields: [
            "download_id": .identifier(entry.ratingKey),
            "attempt": .int(nextAttempt),
            "max_attempts": .int(BackgroundDownloadTransientRetryPolicy.defaultMaxRetries),
            "status_code": .int(statusCode),
            "bytes": .bytes(durableBytes),
            "delay_ms": .int(Int(delay * 1000)),
        ])

        rangeRetryQueue.asyncAfter(deadline: .now() + delay) { [self] in
            do {
                try startRangeRemainder(ratingKey: entry.ratingKey,
                                    with: request,
                                    to: entry.workingURL,
                                    expectedBytes: entry.expectedBytes,
                                    resetsRetryCount: false,
                                    remainderReasonOverride: "http_retry_\(statusCode)",
                                    attemptID: entry.attemptID)
                onChange?()
            } catch {
                if shouldSuppressRangeStartFailure(for: entry.attemptKey,
                                                   error: error,
                                                   context: "http_retry") {
                    onChange?()
                    return
                }
                if handleRangeStartStorageFull(for: entry.attemptKey,
                                               error: error,
                                               context: "http_retry") {
                    return
                }
                AppDiagnostics.record(.downloads, "downloads.range_http_retry_failed", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "attempt": .int(nextAttempt),
                    "status_code": .int(statusCode),
                    "error": .error(error),
                ])
                setFailedPurgingHeldSegments(for: entry.attemptKey)
                onError?(entry.ratingKey, .transferFailed("Retry after HTTP \(statusCode) failed."))
                onChange?()
            }
        }
        onChange?()
        return true
    }

    private static func rangeHTTPRetryDelay(nextAttempt: Int) -> TimeInterval {
        switch nextAttempt {
        case ..<2:
            return 1
        case 2:
            return 2
        default:
            return 4
        }
    }

    /// Phase-7 path-handoff evidence from the connections that actually served this task. This is
    /// stronger than a point-in-time NWPath snapshot: a multi-transaction task records whether any
    /// transaction used cellular/expensive/constrained networking without logging addresses/hosts.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard admitsTaskCallback(task) else { return }
        lock.lock()
        let rangeEntry = rangeInflight[task.taskIdentifier]
        let opaqueEntry = rangeEntry == nil ? inflight[task.taskIdentifier] : nil
        lock.unlock()
        let stampedRatingKey = task.taskDescription.map {
            DownloadAttemptMarker.ratingKey(
                fromTaskDescription: StaticRangeSegmentMarker.ratingKey(fromTaskDescription: $0))
        }
        let fallbackRatingKey = Self.ratingKey(for: task, knownKeys: store.allRatingKeys)
        let ratingKey = rangeEntry?.ratingKey ?? opaqueEntry?.ratingKey
            ?? stampedRatingKey ?? fallbackRatingKey
        let hasRangeRequest = RangeTransferHTTPPolicy.rangeRequestStart(from: task.originalRequest) != nil
            || RangeTransferHTTPPolicy.rangeRequestStart(from: task.currentRequest) != nil
        let transactions = metrics.transactionMetrics
        AppDiagnostics.record(.downloads, "downloads.task_network_metrics", fields: [
            "download_id": .identifier(ratingKey),
            "task_id": .int(task.taskIdentifier),
            "task_type": .label(rangeEntry != nil || hasRangeRequest
                ? "rangeDownloadTask" : "downloadTask"),
            "transaction_count": .int(transactions.count),
            "redirect_count": .int(metrics.redirectCount),
            "cellular_observed": .bool(transactions.contains { $0.isCellular }),
            "expensive_observed": .bool(transactions.contains { $0.isExpensive }),
            "constrained_observed": .bool(transactions.contains { $0.isConstrained }),
            "network_protocol": .label(transactions.last?.networkProtocolName ?? "unknown"),
        ])
    }

    /// Called when the background session has delivered all events queued while the
    /// app was suspended/terminated (after a relaunch). We invoke the system-supplied
    /// completion handler the app delegate stashed, so the OS knows our UI is current
    /// and snapshots a fresh app preview. Must run on the main queue.
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard !rejectTaskCallback(task) else { return }
        lock.lock()
        let rangeEntry = rangeInflight[task.taskIdentifier]
        let entry = rangeEntry == nil ? inflight[task.taskIdentifier] : nil
        lock.unlock()
        AppDiagnostics.record(.downloads, "downloads.task_waiting_for_connectivity", fields: [
            "download_id": .identifier(rangeEntry?.ratingKey ?? entry?.ratingKey),
            "task_id": .int(task.taskIdentifier),
            "task_type": .label(rangeEntry == nil ? "downloadTask" : "rangeDownloadTask"),
            "bytes_received": .int(Int(task.countOfBytesReceived)),
        ])
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onChange?()
        let identifier = session.configuration.identifier ?? Self.identifier
        AppDiagnostics.record(.downloads, "downloads.background_events_finished", fields: [
            "session": .label(identifier),
        ])
        fireBackgroundCompletionWhenFinalizationIsSafe(identifier: identifier)
    }
}


#if DEBUG
/// Test-only URLProtocol used by the download probe to inject faults into real static-range tasks
/// without mutating host networking. Healthy requests are proxied through a URLSession whose
/// protocol list excludes this class; scenarios can alter validators, synthesize one 401, or fail
/// one streamed body with `NSURLErrorNetworkConnectionLost`.
final class DebugDownloadFaultURLProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    enum Fault: Sendable {
        case connectionDrop(afterBytes: Int)
        case repeatedConnectionDrop(afterBytes: Int, count: Int)
        case validatorFlip
        case unauthorizedMidTrain
        case heldBodyPause
        case heldBodyDelete
        case writeFailure
        case range416Restart
        case range200Replace
        case heldBodyRelaunch
        case drainPause
        case drainDelete

        var label: String {
            switch self {
            case .connectionDrop: "connection-drop"
            case .repeatedConnectionDrop: "double-connection-drop"
            case .validatorFlip: "validator-flip"
            case .unauthorizedMidTrain: "401-mid-train"
            case .heldBodyPause: "held-body-pause"
            case .heldBodyDelete: "held-body-delete"
            case .writeFailure: "write-failure"
            case .range416Restart: "416-restart"
            case .range200Replace: "200-replace"
            case .heldBodyRelaunch: "held-body-relaunch"
            case .drainPause: "drain-pause"
            case .drainDelete: "drain-delete"
            }
        }
    }

    private static let handledKey = "LabstreamDebugDownloadFaultHandled"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuredFault: Fault?
    nonisolated(unsafe) private static var injectedDropCount = 0
    nonisolated(unsafe) private static var didInjectUnauthorized = false
    nonisolated(unsafe) private static var didAssignInitialZeroValidator = false
    nonisolated(unsafe) private static var didInjectWriteFailure = false
    nonisolated(unsafe) private static var didInject416 = false
    nonisolated(unsafe) private static var didInject200 = false
    nonisolated(unsafe) private static var drainDelayCount = 0

    private var upstreamTask: URLSessionDataTask?
    private var session: URLSession?
    private var delivered = 0
    private var responseValidator: String?
    private var finishedInjectedBody = false

    static func configure(_ fault: Fault) {
        lock.lock()
        configuredFault = fault
        injectedDropCount = 0
        didInjectUnauthorized = false
        didAssignInitialZeroValidator = false
        didInjectWriteFailure = false
        didInject416 = false
        didInject200 = false
        drainDelayCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil,
              request.value(forHTTPHeaderField: "Range") != nil,
              request.url?.scheme == "http" || request.url?.scheme == "https" else { return false }
        lock.lock()
        let fault = configuredFault
        lock.unlock()
        guard let fault else { return false }
        if case .repeatedConnectionDrop = fault {
            // Repeated-reset coverage is specifically the segment-zero resume chain. Sibling
            // segments start concurrently; faulting any two of them would prove only parallel
            // failures, not reset→blob adoption→second reset on the same logical segment.
            // Derive the boundary from the live regime (it honors the DEBUG segment-size
            // override): a hardcoded 512 MiB survived the shrink to 64 MiB segments and let the
            // two drops land on two different concurrent siblings.
            let firstSegmentEnd = StaticRangeTransferRegime.segmentBytes - 1
            return rangeEnd(request.value(forHTTPHeaderField: "Range")).map { $0 <= firstSegmentEnd } ?? false
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let rangeStart = Self.rangeStart(request.value(forHTTPHeaderField: "Range")) ?? 0
        Self.lock.lock()
        let fault = Self.configuredFault
        var injectUnauthorized = false
        var inject416 = false
        var inject200 = false
        switch fault {
        case .validatorFlip:
            if rangeStart == 0, !Self.didAssignInitialZeroValidator {
                Self.didAssignInitialZeroValidator = true
                responseValidator = "\"labstream-fault-validator-v1\""
            } else {
                responseValidator = "\"labstream-fault-validator-v2\""
            }
        case .unauthorizedMidTrain:
            if rangeStart > 0, !Self.didInjectUnauthorized {
                Self.didInjectUnauthorized = true
                injectUnauthorized = true
            }
        case .range416Restart:
            if rangeStart > 0, !Self.didInject416 {
                Self.didInject416 = true
                inject416 = true
            }
        case .range200Replace:
            if rangeStart > 0, !Self.didInject200 {
                Self.didInject200 = true
                inject200 = true
            } else {
                responseValidator = "\"labstream-fault-200-v1\""
            }
        default:
            break
        }
        Self.lock.unlock()

        if injectUnauthorized {
            let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "0"])!
            AppDiagnostics.record(.downloads, "downloads.fault_injected", fields: [
                "scenario": .label("401-mid-train"),
                "range_start": .int(rangeStart),
            ])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if inject416 {
            // Give the bounded head response and at least one sibling apply enough time to land so
            // the 416 observes durableBytes > its synthetic total while stale train work exists.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: 416,
                                               httpVersion: "HTTP/1.1",
                                               headerFields: [
                                                "Content-Length": "0",
                                                "Content-Range": "bytes */1",
                                               ])!
                self.finishedInjectedBody = true
                AppDiagnostics.record(.downloads, "downloads.fault_injected", fields: [
                    "scenario": .label("416-restart"),
                    "range_start": .int(rangeStart),
                    "server_total": .int(1),
                ])
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        if inject200 {
            // Let the v1 head append and v1 sibling bodies enter held/apply state first. The tiny
            // v2 200 is nevertheless adoptable through the production changed-validator rule,
            // driving the real replaceWhole + sibling teardown path without a multi-GB body.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: 200,
                                               httpVersion: "HTTP/1.1",
                                               headerFields: [
                                                "Content-Length": "1",
                                                "ETag": "\"labstream-fault-200-v2\"",
                                               ])!
                self.finishedInjectedBody = true
                AppDiagnostics.record(.downloads, "downloads.fault_injected", fields: [
                    "scenario": .label("200-replace"),
                    "range_start": .int(rangeStart),
                    "body_bytes": .int(1),
                ])
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data([0]))
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: mutable as URLRequest)
        self.upstreamTask = task
        task.resume()
    }

    override func stopLoading() {
        upstreamTask?.cancel()
        upstreamTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let deliveredResponse: URLResponse
        if let responseValidator, let http = response as? HTTPURLResponse {
            var headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                let key = String(describing: pair.key)
                if key.caseInsensitiveCompare("ETag") != .orderedSame {
                    result[key] = String(describing: pair.value)
                }
            }
            headers["ETag"] = responseValidator
            deliveredResponse = HTTPURLResponse(url: http.url ?? request.url!,
                                                statusCode: http.statusCode,
                                                httpVersion: "HTTP/1.1",
                                                headerFields: headers) ?? response
            Self.lock.lock()
            let supportingScenario: String
            if case .range200Replace? = Self.configuredFault {
                supportingScenario = "200-replace-support"
            } else {
                supportingScenario = "validator-flip"
            }
            Self.lock.unlock()
            AppDiagnostics.record(.downloads, "downloads.fault_injected", fields: [
                "scenario": .label(supportingScenario),
                "range_start": .int(Self.rangeStart(request.value(forHTTPHeaderField: "Range")) ?? 0),
                "validator_generation": .label(responseValidator.hasSuffix("v1\"") ? "v1" : "v2"),
            ])
        } else {
            deliveredResponse = response
        }
        client?.urlProtocol(self, didReceive: deliveredResponse, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        Self.lock.lock()
        let threshold: Int
        let dropLimit: Int
        switch Self.configuredFault {
        case .connectionDrop(let afterBytes):
            threshold = afterBytes
            dropLimit = 1
        case .repeatedConnectionDrop(let afterBytes, let count):
            threshold = afterBytes
            dropLimit = count
        default:
            threshold = 0
            dropLimit = 0
        }
        let mayInjectDrop = Self.injectedDropCount < dropLimit
        let fault = Self.configuredFault
        Self.lock.unlock()

        // Validator comparison happens when the download body finishes, not when URLSession
        // delivers response headers. Letting every real full-size segment complete makes this
        // deterministic fault take minutes and several gigabytes. End each mutated response after
        // a small body: the real delegate/stash/apply path still runs, and validator integrity is
        // deliberately checked before body-length/alignment handling.
        let rangeStart = Self.rangeStart(request.value(forHTTPHeaderField: "Range")) ?? 0
        let shouldFinishSmallBody: Bool
        switch fault {
        case .validatorFlip:
            shouldFinishSmallBody = true
        case .heldBodyPause, .heldBodyDelete, .heldBodyRelaunch:
            shouldFinishSmallBody = rangeStart > 0
        case .writeFailure:
            shouldFinishSmallBody = rangeStart == 0
        case .range416Restart:
            shouldFinishSmallBody = true
        case .range200Replace:
            shouldFinishSmallBody = true
        default:
            shouldFinishSmallBody = false
        }
        if shouldFinishSmallBody {
            let finishAfterBytes = 64 * 1_024
            let remaining = max(0, finishAfterBytes - delivered)
            let emitCount = min(remaining, data.count)
            if emitCount > 0 {
                client?.urlProtocol(self, didLoad: data.prefix(emitCount))
                delivered += emitCount
            }
            if delivered >= finishAfterBytes, !finishedInjectedBody {
                finishedInjectedBody = true
                if case .heldBodyPause? = fault {
                    AppDiagnostics.record(.downloads, "downloads.fault_injected", fields: [
                        "scenario": .label("held-body-pause"),
                        "range_start": .int(rangeStart),
                        "after_bytes": .int(delivered),
                    ])
                } else if case .heldBodyDelete? = fault {
                    AppDiagnostics.record(.downloads, "downloads.fault_injected", fields: [
                        "scenario": .label("held-body-delete"),
                        "range_start": .int(rangeStart),
                        "after_bytes": .int(delivered),
                    ])
                } else if case .heldBodyRelaunch? = fault {
                    AppDiagnostics.record(.downloads, "downloads.fault_injected", fields: [
                        "scenario": .label("held-body-relaunch"),
                        "range_start": .int(rangeStart),
                        "after_bytes": .int(delivered),
                    ])
                }
                dataTask.cancel()
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        guard threshold > 0, mayInjectDrop else {
            client?.urlProtocol(self, didLoad: data)
            return
        }

        let remaining = threshold - delivered
        if remaining <= 0 {
            failOnce(dataTask)
            return
        }

        let emitCount = min(remaining, data.count)
        if emitCount > 0 {
            client?.urlProtocol(self, didLoad: data.prefix(emitCount))
            delivered += emitCount
        }
        if delivered >= threshold {
            failOnce(dataTask)
        }
    }

    private func failOnce(_ dataTask: URLSessionDataTask) {
        Self.lock.lock()
        let fault = Self.configuredFault
        let dropLimit: Int
        switch fault {
        case .connectionDrop:
            dropLimit = 1
        case .repeatedConnectionDrop(_, let count):
            dropLimit = count
        default:
            dropLimit = 0
        }
        let shouldInject = Self.injectedDropCount < dropLimit
        if shouldInject {
            Self.injectedDropCount += 1
        }
        let attempt = Self.injectedDropCount
        Self.lock.unlock()
        guard shouldInject else { return }
        let scenario = fault?.label ?? "connection-drop"
        AppDiagnostics.record(.downloads, "downloads.fault_injected", fields: [
            "scenario": .label(scenario),
            "attempt": .int(attempt),
            "after_bytes": .int(delivered),
        ])
        dataTask.cancel()
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: nil)
        client?.urlProtocol(self, didFailWithError: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if finishedInjectedBody { return }
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static func rangeStart(_ header: String?) -> Int? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        return Int(header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1)[0])
    }

    private static func rangeEnd(_ header: String?) -> Int? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let pieces = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1,
                                                               omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[1].isEmpty else { return nil }
        return Int(pieces[1])
    }

    static func consumeInjectedWriteFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .writeFailure? = configuredFault, !didInjectWriteFailure else { return false }
        didInjectWriteFailure = true
        return true
    }

    static func delayHeldDrainIfConfigured() -> (scenario: String, step: Int)? {
        lock.lock()
        let scenario: String
        switch configuredFault {
        case .drainPause?: scenario = "drain-pause"
        case .drainDelete?: scenario = "drain-delete"
        default:
            lock.unlock()
            return nil
        }
        drainDelayCount += 1
        let step = drainDelayCount
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.5)
        return (scenario, step)
    }
}
#endif
