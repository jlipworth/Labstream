import Foundation
import AVFoundation
import PMSKit

private actor DownloadPlaybackValidationLimiter {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct BackgroundDownloadSessionDiagnosticSnapshot: Sendable {
    let opaqueInflightCount: Int
    let rangeInflightCount: Int
    let haltedRangeKeyCount: Int
    let pendingBackgroundCompletionOperationCount: Int
    let deferredBackgroundCompletionIdentifierCount: Int
    let backgroundCompletionHandlerCount: Int
    let finalizingRatingKeyCount: Int
    let rangeBackgroundHandoffGraceTaskCount: Int
    let gracefulRangePauseKeyCount: Int
    let pendingTempCleanupBytes: Int
}

enum BackgroundRangeRequestReason: String, Sendable, Equatable {
    /// A background Range chunk was adopted after relaunch and finished, but the session object no
    /// longer has the authenticated base request needed to schedule the next chunk.
    case adoptedChunkFinished
    /// The pinned HTTP validator changed under an adopted chunk. The stale partial was discarded and
    /// the manager/backend layer must rebuild an authenticated request to restart from byte 0.
    case validatorChanged
    /// A Range chunk failed after relaunch before it could be appended. The durable partial remains
    /// the checkpoint and the manager/backend layer must rebuild the authenticated request.
    case adoptedChunkFailed
}

/// Wraps a background `URLSession` so transfers survive app suspension and
/// relaunch. On visionOS the OS pauses background transfers while the headset is
/// OFF and resumes them when worn again — surface that reality in the UI
/// (research/10): a "download" is best-effort and may stall until the headset is
/// back on the user's head.
///
/// Delegate callbacks land off the main actor; we hop to `@MainActor` for record
/// updates via `onChange`. The store itself is internally locked.
final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// The fixed background-session identifier. Shared with the app delegate so it can
    /// route `handleEventsForBackgroundURLSession` to THIS session's completion handler.
    static let identifier = "com.visionplay.downloads.background"

    private let store: DownloadStore
    private let fileManager = FileManager.default
    /// taskIdentifier -> (ratingKey, destination)
    private var inflight: [Int: (ratingKey: String, destination: URL)] = [:]
    /// taskIdentifier -> in-flight static byte-range chunk state (#169). Each chunk is a background
    /// `URLSessionDownloadTask`; on completion its temp is appended into the durable partial and the
    /// next chunk is started, so a restart/relaunch resumes with `Range: bytes=<partial-size>-`.
    private var rangeInflight: [Int: RangeTransfer] = [:]
    /// #169: ratingKeys whose chunk chain must NOT spawn another chunk — inserted by `cancel`/`pause`
    /// under `lock`, checked before each continuation, cleared on a fresh user start/resume. Without
    /// it, a chunk finishing on the delegate queue AFTER `cancel`/`pause` snapshotted task ids would
    /// start a fresh (un-cancelled) chunk and resurrect a just-deleted file.
    private var haltedRangeKeys: Set<String> = []
    /// #169 HIGH 1: range-specific retry counters that must not be reset by URLSession progress
    /// callbacks. They bound validator-change restart loops and misaligned `Content-Range` retries
    /// until an actual chunk append proves forward progress.
    private var staticRangeRetryBudget = StaticRangeRetryBudget()
    /// taskIdentifiers whose expected-size has already been logged once (diagnostics).
    private var loggedExpectation: Set<Int> = []
    /// Retry count by ratingKey for transient URLSession drops that provide resume data.
    private var retryCounts: [String: Int] = [:]
    /// RatingKeys currently inside post-transfer finalization. A duplicated URLSession/adoption
    /// callback must not launch a second AVPlayer validation for the same finished file; that can
    /// leave the UI stuck on repeated "Verifying download…" and increases headset memory/CPU load.
    private var finalizingRatingKeys: Set<String> = []
    private let finalizationStateQueue = DispatchQueue(label: "com.visionplay.downloads.finalization-state")
    /// Last UI refresh across the whole downloads screen; progress callbacks can arrive many
    /// times per second per task, so per-row throttling still scales linearly with concurrent
    /// downloads and can overwhelm the Offline list. Coalesce globally instead.
    private var lastProgressNotify: Date?
    /// Progress milestones already mirrored to the diagnostics ring buffer per task.
    private var loggedProgressMilestones: [Int: Set<Int>] = [:]
    /// Last range-progress diagnostic per task. This is intentionally separate from UI throttling:
    /// the off-head headset probe needs durable breadcrumbs showing whether delegate progress kept
    /// arriving, without logging every `didWriteData` callback.
    private var lastRangeProgressDiagnostic: [Int: (time: Date, bytes: Int)] = [:]
    private let maxTransientRetries = 3
    /// Cap UI progress publication to roughly 4 Hz total while preserving terminal updates.
    private let progressNotifyInterval: TimeInterval = 0.5
    private static let cfNetworkTempPrefix = "CFNetworkDownload_"
    private static let cfNetworkTempSuffix = ".tmp"
    private static let nsurlsessiondRelativeDownloadCache = "Caches/com.apple.nsurlsessiond/Downloads/com.jlipworth.VisionPlay"
    private let lock = NSLock()

    /// #169/#190: the static byte-range lane downloads in bounded Range chunks via the
    /// background `downloadTask`, appending each finished chunk into the durable partial.
    /// Foreground and off-head/background chunks use the same small checkpoint size: overnight
    /// progress should become durable frequently instead of parking multi-GB bodies in
    /// non-durable CFNetwork temp files until EOF.
    private static let playbackValidationLimiter = DownloadPlaybackValidationLimiter()
    static let rangeChunkSize = 64 * 1_024 * 1_024
    static let backgroundRangeChunkSize = rangeChunkSize
    private let rangeChunkPlanner = RangeChunkPlanner(
        chunkSize: BackgroundDownloadSession.rangeChunkSize,
        backgroundChunkSize: BackgroundDownloadSession.backgroundRangeChunkSize)
    /// #169: a finished Range segment append must not run on the (serial) URLSession delegate
    /// queue, or it stalls every other download's progress/completion callbacks for the copy's
    /// duration. The delegate hop only does an O(1) rename of the OS temp into a stash; the heavy
    /// append + chunk decision run here.
    private let rangeIOQueue = DispatchQueue(label: "com.visionplay.downloads.range-io")
    /// Number of finished background transfers whose durable-file/finalization work has not yet
    /// reached a safe state. `urlSessionDidFinishEvents` must not release the app delegate
    /// background completion handler until these reach zero, or visionOS can suspend us between a
    /// temp-stash move and the append/finalize/status write that makes the row durable.
    private var backgroundCompletionGate = BackgroundDownloadCompletionGate()
    /// Range tasks started while a background-session completion handler is deferred. Holding that
    /// handler briefly gives `nsurlsessiond` time to observe the newly chained task before the app is
    /// suspended again; otherwise an off-head device can finish chunk N, start chunk N+1 in the event
    /// drain, immediately release the handler, and make no progress on chunk N+1 until foreground.
    private var rangeBackgroundHandoffGraceTasks: Set<Int> = []
    private static let rangeBackgroundHandoffGraceSeconds: TimeInterval = 15
    /// User pause requested while a bounded Range checkpoint is in flight. Rather than canceling a
    /// partially written OS temp file and visibly snapping the row back to the previous checkpoint,
    /// let the current bounded chunk finish, append it to the durable partial, then stop before
    /// starting the next chunk. This keeps Pause/Pause All aligned with "pause at a real checkpoint."
    private var gracefulRangePauseKeys: Set<String> = []
    /// Nil means future static-byte-range work should use foreground-friendly bounded checkpoints.
    /// A non-nil reason means future starts should use background-owned checkpoint chunks. The
    /// active task is NOT automatically reverted when the app becomes active again; avoiding churn
    /// is more important than changing segment policy mid-transfer.
    private var continuousRangeRemainderReason: String?
    private var lastAppScenePhase: String?
    /// Task identifiers intentionally abandoned while replacing a bounded chunk with a continuous
    /// remainder. If their delegate completions race in after cancellation, ignore their temp bytes.
    private var supersededRangeTaskIdentifiers: Set<Int> = []

    /// One in-flight Range chunk of a static byte-range download. Unlike the opaque `downloadTask`
    /// lane, the bytes for the current chunk live in the OS temp file until `didFinishDownloadingTo`
    /// hands them over, at which point we append them into `destination` (the durable partial, which
    /// IS the final file). `request` is the base (un-ranged) request used to issue the next chunk;
    /// it is `nil` for a task adopted on relaunch (we can't rebuild auth headers), in which case a
    /// finished-but-incomplete chunk surfaces `.paused` for `DownloadManager` to resume.
    private struct RangeTransfer {
        let ratingKey: String
        let request: URLRequest?
        let destination: URL
        let expectedBytes: Int?
        var baseOffset: Int
        var responseStatus: Int?
        var chunkBytesWritten: Int
        let segmentKind: RangeTransferSegmentKind
        let segmentReason: String?

        var totalBytes: Int { baseOffset + chunkBytesWritten }

        func replacingExpectedBytes(_ expectedBytes: Int?) -> RangeTransfer {
            RangeTransfer(ratingKey: ratingKey,
                          request: request,
                          destination: destination,
                          expectedBytes: expectedBytes,
                          baseOffset: baseOffset,
                          responseStatus: responseStatus,
                          chunkBytesWritten: chunkBytesWritten,
                          segmentKind: segmentKind,
                          segmentReason: segmentReason)
        }
    }

    private struct DuplicateRangeTaskDecision {
        let existingTaskIdentifier: Int
        let existingEntry: RangeTransfer
        let shouldReplaceExisting: Bool
    }

    private func rangeTaskSnapshot(taskIdentifier: Int,
                                   entry: RangeTransfer,
                                   chunkBytesWritten: Int? = nil) -> StaticRangeTaskSnapshot {
        StaticRangeTaskSnapshot(
            taskIdentifier: taskIdentifier,
            downloadID: entry.ratingKey,
            baseOffset: entry.baseOffset,
            chunkBytesWritten: chunkBytesWritten ?? entry.chunkBytesWritten
        )
    }

    /// Enforce the #169 ownership invariant: a static byte-range row may have only one authoritative
    /// URLSession range task at a time. A stale/lower checkpoint task must never publish progress or
    /// append after a newer checkpoint has taken over.
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

    private func newerRangeTaskIdentifier(for entry: RangeTransfer,
                                          currentTaskIdentifier: Int,
                                          currentChunkBytes: Int) -> Int? {
        StaticRangeTaskSelectionPolicy.newerTaskIdentifier(
            than: rangeTaskSnapshot(
                taskIdentifier: currentTaskIdentifier,
                entry: entry,
                chunkBytesWritten: currentChunkBytes
            ),
            in: rangeInflight.map { rangeTaskSnapshot(taskIdentifier: $0.key, entry: $0.value) }
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

    /// Ephemeral live byte observations for static Range chunks. The store remains checkpoint-only
    /// for durable/resumable accounting; DownloadManager uses these samples for active speed/ETA.
    var onRangeLiveProgress: ((_ ratingKey: String, _ liveBytes: Int, _ expectedBytes: Int?) -> Void)?

    /// True when this process currently owns an opaque or Range URLSession task for the row.
    /// `DownloadManager.activeJobs` is intentionally broader app-level bookkeeping and can survive
    /// a relaunch-adopted chunk handoff; stale active slots must not make a queued static partial
    /// look live forever.
    func isTrackingTransfer(ratingKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inflight.values.contains { $0.ratingKey == ratingKey }
            || rangeInflight.values.contains { $0.ratingKey == ratingKey }
    }

    func cleanupOrphanedNetworkTemps() {
        urlSession.getAllTasks { [weak self] tasks in
            self?.sweepOrphanedNetworkTemps(liveTaskCount: tasks.count, reason: "manual_scan")
        }
    }

    func diagnosticSnapshot() -> BackgroundDownloadSessionDiagnosticSnapshot {
        lock.lock()
        let opaqueInflightCount = inflight.count
        let rangeInflightCount = rangeInflight.count
        let haltedRangeKeyCount = haltedRangeKeys.count
        let pendingBackgroundCompletionOperationCount = backgroundCompletionGate.pendingOperationCount
        let deferredBackgroundCompletionIdentifierCount = backgroundCompletionGate.deferredIdentifierCount
        let backgroundCompletionHandlerCount = backgroundCompletionGate.awaitingFinishIdentifierCount
        let rangeBackgroundHandoffGraceTaskCount = rangeBackgroundHandoffGraceTasks.count
        let gracefulRangePauseKeyCount = gracefulRangePauseKeys.count
        lock.unlock()
        let finalizingRatingKeyCount = finalizationStateQueue.sync { finalizingRatingKeys.count }
        return BackgroundDownloadSessionDiagnosticSnapshot(
            opaqueInflightCount: opaqueInflightCount,
            rangeInflightCount: rangeInflightCount,
            haltedRangeKeyCount: haltedRangeKeyCount,
            pendingBackgroundCompletionOperationCount: pendingBackgroundCompletionOperationCount,
            deferredBackgroundCompletionIdentifierCount: deferredBackgroundCompletionIdentifierCount,
            backgroundCompletionHandlerCount: backgroundCompletionHandlerCount,
            finalizingRatingKeyCount: finalizingRatingKeyCount,
            rangeBackgroundHandoffGraceTaskCount: rangeBackgroundHandoffGraceTaskCount,
            gracefulRangePauseKeyCount: gracefulRangePauseKeyCount,
            pendingTempCleanupBytes: pendingCFNetworkTempBytes())
    }

    private lazy var urlSession: URLSession = {
        let config: URLSessionConfiguration
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
            downloadLog.info("using FOREGROUND URLSession (simulator) for downloads")
            #if DEBUG
            // #169: the byte-range lane now runs on THIS session, so the range-drop test harness
            // attaches here (a URLProtocol can only live on a foreground/default config — never on
            // the device background session). Sim-only dev tooling.
            if let dropAfter = Self.debugRangeDropAfterBytesArgument() {
                DebugRangeDropURLProtocol.configure(dropAfterBytes: dropAfter)
                config.protocolClasses = [DebugRangeDropURLProtocol.self] + (config.protocolClasses ?? [])
                downloadLog.info("using DEBUG range-drop URLProtocol after bytes=\(dropAfter, privacy: .public)")
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
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    #if DEBUG
    private static func debugRangeDropAfterBytesArgument() -> Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--vp-probe-range-drop-after-bytes"),
              args.indices.contains(idx + 1),
              let bytes = Int(args[idx + 1]),
              bytes > 0 else { return nil }
        return bytes
    }
    #endif

    init(store: DownloadStore) {
        self.store = store
        super.init()
        // Register so the app delegate can hand us the system completion handler when
        // the app is relaunched to process finished background events.
        let session = self
        Task { @MainActor in BackgroundDownloadCompletionRegistry.shared.register(session) }
    }

    private func fileSize(at url: URL) -> Int? {
        guard let raw = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) else {
            return nil
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let int = raw as? Int {
            return int
        }
        if let int64 = raw as? Int64 {
            return Int(int64)
        }
        return nil
    }

    private func beginPendingBackgroundCompletionOperation() {
        lock.lock()
        backgroundCompletionGate.beginOperation()
        lock.unlock()
    }

    private func endPendingBackgroundCompletionOperation() {
        lock.lock()
        let identifiers = backgroundCompletionGate.endOperation()
        lock.unlock()
        for identifier in identifiers {
            Task { @MainActor in
                BackgroundDownloadCompletionRegistry.shared.fireCompletion(for: identifier)
            }
        }
    }

    func noteBackgroundCompletionHandlerStored(identifier: String) {
        lock.lock()
        backgroundCompletionGate.storeHandler(identifier: identifier)
        lock.unlock()
    }

    private func fireBackgroundCompletionWhenFinalizationIsSafe(identifier: String) {
        lock.lock()
        let identifiers = backgroundCompletionGate.finishEvents(identifier: identifier)
        lock.unlock()
        for identifier in identifiers {
            Task { @MainActor in
                BackgroundDownloadCompletionRegistry.shared.fireCompletion(for: identifier)
            }
        }
    }

    private func hasPendingBackgroundCompletionHandler() -> Bool {
        lock.lock()
        let hasPending = backgroundCompletionGate.hasPendingHandler
        lock.unlock()
        return hasPending
    }

    private func beginRangeBackgroundHandoffGrace(taskIdentifier: Int, ratingKey: String) {
        guard taskIdentifier >= 0 else { return }
        beginPendingBackgroundCompletionOperation()
        lock.lock()
        rangeBackgroundHandoffGraceTasks.insert(taskIdentifier)
        lock.unlock()
        AppDiagnostics.record(.downloads, "downloads.range_background_handoff_grace_start", fields: [
            "download_id": .identifier(ratingKey),
            "task_id": .int(taskIdentifier),
            "grace_seconds": .int(Int(Self.rangeBackgroundHandoffGraceSeconds)),
        ])
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.rangeBackgroundHandoffGraceSeconds
        ) { [weak self] in
            self?.endRangeBackgroundHandoffGrace(
                taskIdentifier: taskIdentifier,
                ratingKey: ratingKey,
                reason: "timeout"
            )
        }
    }

    private func endRangeBackgroundHandoffGrace(taskIdentifier: Int, ratingKey: String, reason: String) {
        lock.lock()
        let wasHeld = rangeBackgroundHandoffGraceTasks.remove(taskIdentifier) != nil
        lock.unlock()
        guard wasHeld else { return }
        AppDiagnostics.record(.downloads, "downloads.range_background_handoff_grace_end", fields: [
            "download_id": .identifier(ratingKey),
            "task_id": .int(taskIdentifier),
            "reason": .label(reason),
        ])
        endPendingBackgroundCompletionOperation()
    }

    /// Called by the app-lifetime `DownloadManager` when SwiftUI scene phase changes. `.inactive`
    /// and `.background` mean the user may be taking the headset off; in that window future static
    /// range segments switch to background-owned checkpoint chunks. `.active` only affects
    /// future starts. Existing bounded chunks are allowed to finish and append instead of being
    /// cancelled into a non-durable open-ended remainder.
    func noteAppScenePhase(_ phase: String) {
        let normalized = phase.lowercased()
        lock.lock()
        guard lastAppScenePhase != normalized else {
            lock.unlock()
            return
        }
        lastAppScenePhase = normalized
        let shouldPreferBackgroundCheckpoint = normalized == "inactive" || normalized == "background"
        let reason = shouldPreferBackgroundCheckpoint ? "scene_\(normalized)" : nil
        continuousRangeRemainderReason = reason
        let candidateCount = shouldPreferBackgroundCheckpoint
            ? rangeInflight.values.filter {
                RangeTransferHTTPPolicy.isDurableCheckpointSegment($0.segmentKind) && $0.request != nil
            }.count
            : 0
        lock.unlock()

        AppDiagnostics.record(.downloads, "downloads.range_strategy", fields: [
            "phase": .label(normalized),
            "strategy": .label(shouldPreferBackgroundCheckpoint ? "background_checkpoint" : "bounded_checkpoint"),
            "candidate_count": .int(candidateCount),
        ])
    }

    private func rangeSegmentPreference(holdBackgroundCompletionForFirstProgress: Bool)
        -> (kind: RangeTransferSegmentKind, reason: String?) {
        lock.lock()
        let sceneReason = continuousRangeRemainderReason
        lock.unlock()
        if let sceneReason {
            return (.backgroundCheckpoint, sceneReason)
        }
        if holdBackgroundCompletionForFirstProgress {
            return (.backgroundCheckpoint, "background_events")
        }
        return (.boundedCheckpoint, nil)
    }

    /// Legacy escape hatch for replacing in-flight bounded Range chunks with one open-ended
    /// remainder request from the durable checkpoint. The normal off-head path no longer calls this:
    /// it keeps bounded background checkpoints so overnight progress becomes durable periodically.
    private func promoteActiveRangeChunksToContinuousRemainder(reason: String) {
        urlSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let taskByIdentifier = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskIdentifier, $0) })
            var promotions: [(taskIdentifier: Int, task: URLSessionTask?, entry: RangeTransfer)] = []

            self.lock.lock()
            let candidateIDs = self.rangeInflight.compactMap { element -> Int? in
                let (id, entry) = element
                guard RangeTransferHTTPPolicy.isDurableCheckpointSegment(entry.segmentKind), entry.request != nil else { return nil }
                return id
            }
            for id in candidateIDs {
                guard let entry = self.rangeInflight.removeValue(forKey: id) else { continue }
                self.supersededRangeTaskIdentifiers.insert(id)
                promotions.append((id, taskByIdentifier[id], entry))
            }
            self.lock.unlock()

            guard !promotions.isEmpty else { return }
            AppDiagnostics.record(.downloads, "downloads.range_remainder_prepare", fields: [
                "reason": .label(reason),
                "candidate_count": .int(promotions.count),
            ])

            for promotion in promotions {
                self.promoteRangeChunkToContinuousRemainder(
                    taskIdentifier: promotion.taskIdentifier,
                    task: promotion.task,
                    entry: promotion.entry,
                    reason: reason
                )
            }
        }
    }

    private func promoteRangeChunkToContinuousRemainder(taskIdentifier: Int,
                                                       task: URLSessionTask?,
                                                       entry: RangeTransfer,
                                                       reason: String) {
        endRangeBackgroundHandoffGrace(taskIdentifier: taskIdentifier,
                                       ratingKey: entry.ratingKey,
                                       reason: "promoted_remainder")
        task?.cancel()
        let durableBytes = store.resetStaticRangeProgressToDurableCheckpoint(
            ratingKey: entry.ratingKey,
            expectedBytes: entry.expectedBytes
        )
        AppDiagnostics.record(.downloads, "downloads.range_remainder_promote", fields: [
            "download_id": .identifier(entry.ratingKey),
            "task_id": .int(taskIdentifier),
            "reason": .label(reason),
            "task_found": .bool(task != nil),
            "base_offset": .int(entry.baseOffset),
            "checkpoint_bytes": .bytes(durableBytes),
            "discarded_temp_bytes": .bytes(entry.chunkBytesWritten),
        ])
        guard !isRangeHalted(ratingKey: entry.ratingKey) else {
            AppDiagnostics.record(.downloads, "downloads.range_remainder_promote_halted", fields: [
                "download_id": .identifier(entry.ratingKey),
                "task_id": .int(taskIdentifier),
                "reason": .label(reason),
                "checkpoint_bytes": .bytes(durableBytes),
            ])
            onChange?()
            return
        }
        guard let request = entry.request else {
            store.setStatus(ratingKey: entry.ratingKey, .queued)
            onRangeRequestNeeded?(entry.ratingKey, .adoptedChunkFailed)
            return
        }
        do {
            try startRangeChunk(ratingKey: entry.ratingKey,
                                with: request,
                                to: entry.destination,
                                expectedBytes: entry.expectedBytes,
                                resetsRetryCount: false,
                                segmentKindOverride: .continuousRemainder,
                                segmentReasonOverride: reason)
            onChange?()
        } catch {
            if shouldSuppressRangeStartFailure(ratingKey: entry.ratingKey,
                                               error: error,
                                               context: "promote_remainder") {
                onChange?()
                return
            }
            AppDiagnostics.record(.downloads, "downloads.range_remainder_promote_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "reason": .label(reason),
                "error": .error(error),
            ])
            store.setStatus(ratingKey: entry.ratingKey, .paused)
            onError?(entry.ratingKey, .interruptedResumable)
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
        urlSession.getAllTasks { [weak self] tasks in
            guard let self else { onReattached?([]); return }
            // Rebuild the taskIdentifier -> (ratingKey, destination) map for any
            // tasks the OS resumed. We match a task to a record by its source URL's
            // `path` query param (the metadataKey), which is stable per item; if we
            // can't match we still leave the task running and rely on the store row.
            var liveKeys: Set<String> = []
            // Build the indexed-key set ONCE (FS-free) before the task loop, instead of
            // stat'ing every store row per task under the held lock (was O(tasks×rows)).
            let knownKeys = self.store.allRatingKeys
            let destinations = self.store.destinationsByRatingKey
            let recordsByKey = Dictionary(self.store.records.map { ($0.ratingKey, $0) },
                                          uniquingKeysWith: { first, _ in first })
            var rangeTaskIdentifiersToCancel: [Int] = []
            var adoptedRangeKeys: Set<String> = []
            self.lock.lock()
            for task in tasks {
                guard self.inflight[task.taskIdentifier] == nil,
                      self.rangeInflight[task.taskIdentifier] == nil,
                      let ratingKey = Self.ratingKey(for: task, knownKeys: knownKeys) else { continue }
                let destination = destinations[ratingKey]
                    ?? self.store.destinationURL(ratingKey: ratingKey, ext: "mp4")
                let record = recordsByKey[ratingKey]
                if record?.metadata?.resolvedResumeMode(ratingKey: ratingKey) == .staticByteRange {
                    // #169: a surviving static byte-range chunk must be adopted into the RANGE map,
                    // or `didFinishDownloadingTo` would treat its partial-chunk temp as a whole-file
                    // move and corrupt the download. We can't rebuild the request (auth headers)
                    // across relaunch, so `request` is nil: a finished-but-incomplete chunk surfaces
                    // `.paused` and DownloadManager resumes the next chunk. `baseOffset` is the
                    // durable partial size (this chunk has not been appended yet); expected is
                    // recovered from the persisted bytes/progress.
                    let partialSize = self.fileSize(at: destination) ?? 0
                    let requestedOffset = RangeTransferHTTPPolicy.rangeRequestStart(from: task.originalRequest)
                        ?? RangeTransferHTTPPolicy.rangeRequestStart(from: task.currentRequest)
                    let reattachedRequest = task.originalRequest ?? task.currentRequest
                    let reattachedSegmentKind = RangeTransferHTTPPolicy.segmentKind(
                        rangeHeader: reattachedRequest?.value(forHTTPHeaderField: "Range"),
                        foregroundChunkSize: Self.rangeChunkSize
                    )
                    if let requestedOffset, requestedOffset != partialSize {
                        // The durable partial is the only checkpoint we trust. A reappearing task
                        // whose Range begins before/after that checkpoint is stale (or gapped) and
                        // must not become authoritative, publish backwards progress, or append later.
                        self.supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
                        rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                        AppDiagnostics.record(.downloads, "downloads.range_reattach_offset_mismatch", fields: [
                            "download_id": .identifier(ratingKey),
                            "task_id": .int(task.taskIdentifier),
                            "requested_offset": .int(requestedOffset),
                            "durable_bytes": .int(partialSize),
                            "segment_kind": .label(reattachedSegmentKind.rawValue),
                        ])
                        continue
                    }
                    let reattached = RangeTransfer(
                        ratingKey: ratingKey,
                        request: nil,
                        destination: destination,
                        expectedBytes: record.flatMap(Self.derivedExpectedBytes),
                        baseOffset: requestedOffset ?? partialSize,
                        responseStatus: nil,
                        chunkBytesWritten: max(0, Int(task.countOfBytesReceived)),
                        segmentKind: reattachedSegmentKind,
                        segmentReason: "reattached")
                    if let duplicate = self.duplicateRangeTaskDecision(for: reattached) {
                        if duplicate.shouldReplaceExisting {
                            let superseded = self.supersedeRangeTasksLocked(ratingKey: ratingKey)
                            self.rangeInflight[task.taskIdentifier] = reattached
                            self.supersededRangeTaskIdentifiers.remove(task.taskIdentifier)
                            rangeTaskIdentifiersToCancel.append(contentsOf: superseded)
                            AppDiagnostics.record(.downloads, "downloads.range_duplicate_reattach_replaced", fields: [
                                "download_id": .identifier(ratingKey),
                                "task_id": .int(task.taskIdentifier),
                                "existing_task_id": .int(duplicate.existingTaskIdentifier),
                                "superseded_task_count": .int(superseded.count),
                                "base_offset": .int(reattached.baseOffset),
                                "existing_base_offset": .int(duplicate.existingEntry.baseOffset),
                            ])
                        } else {
                            let superseded = self.supersedeRangeTasksLocked(
                                ratingKey: ratingKey,
                                keeping: duplicate.existingTaskIdentifier
                            )
                            self.supersededRangeTaskIdentifiers.insert(task.taskIdentifier)
                            rangeTaskIdentifiersToCancel.append(task.taskIdentifier)
                            rangeTaskIdentifiersToCancel.append(contentsOf: superseded)
                            AppDiagnostics.record(.downloads, "downloads.range_duplicate_reattach_suppressed", fields: [
                                "download_id": .identifier(ratingKey),
                                "task_id": .int(task.taskIdentifier),
                                "existing_task_id": .int(duplicate.existingTaskIdentifier),
                                "superseded_task_count": .int(superseded.count + 1),
                                "base_offset": .int(reattached.baseOffset),
                                "existing_base_offset": .int(duplicate.existingEntry.baseOffset),
                            ])
                            liveKeys.insert(ratingKey)
                            continue
                        }
                    } else {
                        self.rangeInflight[task.taskIdentifier] = reattached
                    }
                    adoptedRangeKeys.insert(ratingKey)
                } else {
                    self.inflight[task.taskIdentifier] = (ratingKey, destination)
                }
                liveKeys.insert(ratingKey)
            }
            // Also count tasks already tracked (e.g. started this launch) as live.
            for entry in self.inflight.values { liveKeys.insert(entry.ratingKey) }
            for entry in self.rangeInflight.values { liveKeys.insert(entry.ratingKey) }
            self.lock.unlock()
            for taskIdentifier in rangeTaskIdentifiersToCancel {
                self.cancelURLSessionTask(identifier: taskIdentifier)
            }
            for ratingKey in adoptedRangeKeys {
                self.store.setStatus(ratingKey: ratingKey, .downloading)
            }
            // Sweep chunk stashes orphaned by a hard kill between the synchronous stash-rename and
            // `applyFinishedChunk` running. Any stash not owned by a still-live task is dead — its
            // chunk was never appended, so the durable partial re-fetches it on resume. visionOS only
            // clears `tmp/` under pressure, so reclaim them here (cheap, alongside reattach).
            self.sweepOrphanedChunkStashes(liveTaskIdentifiers: Set(tasks.map(\.taskIdentifier)))
            self.sweepOrphanedNetworkTemps(liveTaskCount: tasks.count, reason: "reattach")
            onReattached?(liveKeys)
            self.onChange?()
        }
    }

    /// Delete `vp-range-chunk-*` temps in `tmp/` whose owning task is no longer live (see #169 LOW 5).
    private func sweepOrphanedChunkStashes(liveTaskIdentifiers: Set<Int>) {
        let tmp = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("vp-range-chunk-") {
            let idString = url.lastPathComponent.dropFirst("vp-range-chunk-".count)
            if let id = Int(idString), liveTaskIdentifiers.contains(id) { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func sweepOrphanedNetworkTemps(liveTaskCount: Int, reason: String) {
        let candidates = cfNetworkTempDirectories()
            .flatMap { directory in cfNetworkTempFiles(in: directory).map { (directory, $0) } }
        let candidateBytes = candidates.reduce(0) { $0 + (fileSize(at: $1.1) ?? 0) }
        guard !candidates.isEmpty else { return }
        guard liveTaskCount == 0 else {
            AppDiagnostics.record(.downloads, "downloads.cfnetwork_temp_cleanup_skipped", fields: [
                "reason": .label(reason),
                "live_task_count": .int(liveTaskCount),
                "candidate_count": .int(candidates.count),
                "candidate_bytes": .int(candidateBytes),
            ])
            return
        }

        var deletedCount = 0
        var deletedBytes = 0
        var failedCount = 0
        for (_, url) in candidates {
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
            "reason": .label(reason),
            "candidate_count": .int(candidates.count),
            "deleted_count": .int(deletedCount),
            "failed_count": .int(failedCount),
            "deleted_bytes": .int(deletedBytes),
        ])
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
            let library = appSupport.deletingLastPathComponent()
            directories.append(library.appendingPathComponent(Self.nsurlsessiondRelativeDownloadCache, isDirectory: true))
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
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.cfNetworkTempPrefix), name.hasSuffix(Self.cfNetworkTempSuffix) else {
                return false
            }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    /// Best-effort match of a resumed background task back to a known download record.
    ///
    /// Prefer the task description we set at creation time. Fall back to URL-shape heuristics
    /// for older tasks: the original request URL may carry the item's metadata key as the `path`
    /// query param (`/library/metadata/<ratingKey>`) or a Jellyfin `/Items`/`/Videos` path. Plex
    /// `/library/parts/...` downloads do not include the source ratingKey, which is why the
    /// explicit task description is required for reliable force-quit/relaunch reattach.
    private static func ratingKey(for task: URLSessionTask, knownKeys: Set<String>) -> String? {
        if let taskDescription = task.taskDescription, knownKeys.contains(taskDescription) {
            return taskDescription
        }
        guard let url = task.originalRequest?.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let candidates: [String]
        if let path = comps.queryItems?.first(where: { $0.name == "path" })?.value {
            candidates = [(path as NSString).lastPathComponent]
        } else {
            let parts = comps.path.split(separator: "/").map(String.init)
            if let items = parts.firstIndex(of: "Items"), parts.indices.contains(items + 1) {
                candidates = [parts[items + 1]]
            } else if let videos = parts.firstIndex(of: "Videos"), parts.indices.contains(videos + 1) {
                candidates = [parts[videos + 1]]
            } else {
                candidates = []
            }
        }
        let expanded = candidates.flatMap { [$0, "jellyfin:\($0)"] }
        return expanded.first { knownKeys.contains($0) }
    }

    /// Force the lazy background session to be created (and thus its delegate bound),
    /// so the OS can deliver `urlSessionDidFinishEvents` after a relaunch.
    func ensureSessionReady() {
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
                "free_bytes": .bytes(Int(free)),
            ])
            throw DownloadManager.DownloadError.storageFull
        }
        if byteRangeCheckpoint {
            store.setSourcePartSizeIfMissing(ratingKey: ratingKey, expectedBytes)
        }
        // A fresh user-initiated start/resume clears any prior cancel/pause halt for this row (a
        // mid-chain chunk continuation calls `startRangeChunk` directly and deliberately does not),
        // and resets the validator-change restart bound so a user-driven retry starts with a clean count.
        lock.lock()
        haltedRangeKeys.remove(ratingKey)
        gracefulRangePauseKeys.remove(ratingKey)
        if resetRangeRestartCounters {
            staticRangeRetryBudget.reset(downloadID: ratingKey)
        }
        lock.unlock()
        if byteRangeCheckpoint {
            try startRangeChunk(ratingKey: ratingKey, with: request, to: destination,
                                expectedBytes: expectedBytes,
                                resetsRetryCount: true)
            return
        }

        let task = urlSession.downloadTask(with: request)
        task.taskDescription = ratingKey
        lock.lock()
        retryCounts[ratingKey] = 0
        lastProgressNotify = nil
        loggedProgressMilestones[task.taskIdentifier] = []
        lastRangeProgressDiagnostic.removeValue(forKey: task.taskIdentifier)
        inflight[task.taskIdentifier] = (ratingKey, destination)
        lock.unlock()
        let urlShape = DiagnosticRedactor.urlShape(request.url)
        downloadLog.info("start ratingKey=\(ratingKey, privacy: .public) url_shape=\(urlShape, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.transfer_start", fields: [
            "download_id": .identifier(ratingKey),
            "url_shape": .urlShape(request.url),
            "expected_bytes": .bytes(expectedBytes),
            "has_expected_bytes": .bool(expectedBytes != nil),
        ])
        task.resume()
    }

    /// Start one static byte-range background `downloadTask` (#169).
    ///
    /// The destination IS the durable partial file; its current size is the checkpoint. While active
    /// we use bounded checkpoint chunks. When the app is likely going off-head/background, future
    /// starts use background-owned bounded checkpoint chunks so `nsurlsessiond` owns each transfer
    /// segment without parking all remaining bytes in one non-durable temp file.
    /// `didFinishDownloadingTo` appends the finished segment into the partial and either finalizes
    /// or starts the next segment. A server that ignores Range (HTTP 200) sends the whole
    /// resource and is handled at finalize by replacing the partial honestly; if it honors Range with
    /// 206, progress never jumps backwards.
    @discardableResult
    private func startRangeChunk(ratingKey: String, with request: URLRequest, to destination: URL,
                                 expectedBytes: Int?,
                                 resetsRetryCount: Bool,
                                 holdBackgroundCompletionForFirstProgress: Bool = false,
                                 segmentKindOverride: RangeTransferSegmentKind? = nil,
                                 segmentReasonOverride: String? = nil) throws -> Int {
        guard !isRangeHalted(ratingKey: ratingKey) else {
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
                store.updateProgress(ratingKey: ratingKey, bytes: 0, progress: 0)
            }
        } else {
            fileManager.createFile(atPath: destination.path, contents: nil)
        }
        store.setSourcePartSizeIfMissing(ratingKey: ratingKey, expectedBytes)
        if let expectedBytes, offset >= expectedBytes, expectedBytes > 0 {
            finalizeRangeWhole(entry: RangeTransfer(
                ratingKey: ratingKey,
                request: request,
                destination: destination,
                expectedBytes: expectedBytes,
                baseOffset: offset,
                responseStatus: nil,
                chunkBytesWritten: 0,
                segmentKind: segmentKindOverride ?? .boundedCheckpoint,
                segmentReason: segmentReasonOverride))
            return -1
        }

        // #169 HIGH 1: starting the file over (offset 0, fresh or truncated) invalidates any prior
        // resource validator; the first chunk captures a new one. Subsequent chunks (offset > 0) send
        // `If-Range` so a cooperating server (Emby/Jellyfin, probed) downgrades a changed resource to a
        // whole-file 200 (`replaceWhole`). Plex IGNORES `If-Range` (probed), so the load-bearing defense
        // is the per-chunk validator-equality check in `applyFinishedChunk`, which restarts from 0 on a
        // mismatch; `If-Range` is the cheap belt-and-suspenders that short-circuits the cooperating ones.
        let preference = rangeSegmentPreference(
            holdBackgroundCompletionForFirstProgress: holdBackgroundCompletionForFirstProgress
        )
        let segmentKind = segmentKindOverride ?? preference.kind
        let segmentReason = segmentReasonOverride ?? preference.reason
        let candidate = RangeTransfer(
            ratingKey: ratingKey,
            request: request,
            destination: destination,
            expectedBytes: expectedBytes,
            baseOffset: offset,
            responseStatus: nil,
            chunkBytesWritten: 0,
            segmentKind: segmentKind,
            segmentReason: segmentReason)
        lock.lock()
        if let duplicate = duplicateRangeTaskDecision(for: candidate), !duplicate.shouldReplaceExisting {
            let superseded = supersedeRangeTasksLocked(
                ratingKey: ratingKey,
                keeping: duplicate.existingTaskIdentifier
            )
            lock.unlock()
            for identifier in superseded {
                cancelURLSessionTask(identifier: identifier)
            }
            store.setStatus(ratingKey: ratingKey, .downloading)
            onChange?()
            AppDiagnostics.record(.downloads, "downloads.range_duplicate_start_suppressed", fields: [
                "download_id": .identifier(ratingKey),
                "existing_task_id": .int(duplicate.existingTaskIdentifier),
                "superseded_task_count": .int(superseded.count),
                "base_offset": .int(candidate.baseOffset),
                "existing_base_offset": .int(duplicate.existingEntry.baseOffset),
                "phase": .label("preflight"),
                "segment_kind": .label(segmentKind.rawValue),
            ])
            return duplicate.existingTaskIdentifier
        }
        lock.unlock()
        if offset == 0 {
            store.clearRangeValidator(ratingKey: ratingKey)
        }
        let segmentPlan = rangeChunkPlanner.segmentPlan(offset: offset,
                                                       expectedBytes: expectedBytes,
                                                       kind: segmentKind)
        var ranged = request
        if let rangeHeader = segmentPlan.rangeHeaderValue {
            ranged.setValue(rangeHeader, forHTTPHeaderField: "Range")
            if let validator = store.rangeValidator(ratingKey: ratingKey) {
                ranged.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        }
        let task = urlSession.downloadTask(with: ranged)
        task.taskDescription = ratingKey
        var existingRangeTasksToCancel: [Int] = []
        lock.lock()
        if haltedRangeKeys.contains(ratingKey) {
            lock.unlock()
            task.cancel()
            AppDiagnostics.record(.downloads, "downloads.range_start_suppressed", fields: [
                "download_id": .identifier(ratingKey),
                "phase": .label("register_halted"),
                "task_id": .int(task.taskIdentifier),
                "segment_kind": .label(segmentKind.rawValue),
            ])
            throw CancellationError()
        }
        if let duplicate = duplicateRangeTaskDecision(for: candidate) {
            if duplicate.shouldReplaceExisting {
                existingRangeTasksToCancel = supersedeRangeTasksLocked(ratingKey: ratingKey)
            } else {
                let superseded = supersedeRangeTasksLocked(
                    ratingKey: ratingKey,
                    keeping: duplicate.existingTaskIdentifier
                )
                lock.unlock()
                task.cancel()
                for identifier in superseded {
                    cancelURLSessionTask(identifier: identifier)
                }
                store.setStatus(ratingKey: ratingKey, .downloading)
                onChange?()
                AppDiagnostics.record(.downloads, "downloads.range_duplicate_start_suppressed", fields: [
                    "download_id": .identifier(ratingKey),
                    "task_id": .int(task.taskIdentifier),
                    "existing_task_id": .int(duplicate.existingTaskIdentifier),
                    "superseded_task_count": .int(superseded.count + 1),
                    "base_offset": .int(candidate.baseOffset),
                    "existing_base_offset": .int(duplicate.existingEntry.baseOffset),
                    "phase": .label("register"),
                    "segment_kind": .label(segmentKind.rawValue),
                ])
                return duplicate.existingTaskIdentifier
            }
        }
        if resetsRetryCount {
            retryCounts[ratingKey] = 0
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
                "segment_kind": .label(segmentKind.rawValue),
            ])
        }
        if offset > 0, let expectedBytes, expectedBytes > 0 {
            store.updateProgress(ratingKey: ratingKey,
                                 bytes: offset,
                                 progress: min(1, Double(offset) / Double(expectedBytes)))
        }
        let urlShape = DiagnosticRedactor.urlShape(ranged.url)
        downloadLog.info("range-chunk-start ratingKey=\(ratingKey, privacy: .public) offset=\(offset, privacy: .public) url_shape=\(urlShape, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.range_start", fields: [
            "download_id": .identifier(ratingKey),
            "task_id": .int(task.taskIdentifier),
            "segment_kind": .label(segmentKind.rawValue),
            "segment_reason": .label(segmentReason ?? "foreground"),
            "offset_bytes": .bytes(offset),
            "offset_exact": .int(offset),
            "has_offset": .bool(offset > 0),
            "expected_bytes": .bytes(expectedBytes),
            "expected_exact": .int(expectedBytes ?? -1),
            "chunk_size": .int(segmentKind == .backgroundCheckpoint ? Self.backgroundRangeChunkSize : Self.rangeChunkSize),
            "planned_segment_bytes": .bytes(segmentPlan.expectedSegmentBytes),
            "url_shape": .urlShape(ranged.url),
        ])
        if segmentKind == .backgroundCheckpoint {
            AppDiagnostics.record(.downloads, "downloads.range_background_checkpoint_start", fields: [
                "download_id": .identifier(ratingKey),
                "task_id": .int(task.taskIdentifier),
                "segment_reason": .label(segmentReason ?? "unknown"),
                "offset_bytes": .bytes(offset),
                "offset_exact": .int(offset),
                "expected_exact": .int(expectedBytes ?? -1),
                "planned_segment_bytes": .bytes(segmentPlan.expectedSegmentBytes),
            ])
        }
        if segmentKind == .continuousRemainder {
            AppDiagnostics.record(.downloads, "downloads.range_remainder_start", fields: [
                "download_id": .identifier(ratingKey),
                "task_id": .int(task.taskIdentifier),
                "segment_reason": .label(segmentReason ?? "unknown"),
                "offset_bytes": .bytes(offset),
                "offset_exact": .int(offset),
                "expected_exact": .int(expectedBytes ?? -1),
                "planned_segment_bytes": .bytes(segmentPlan.expectedSegmentBytes),
            ])
        }
        if holdBackgroundCompletionForFirstProgress {
            beginRangeBackgroundHandoffGrace(taskIdentifier: task.taskIdentifier, ratingKey: ratingKey)
        }
        task.resume()
        return task.taskIdentifier
    }

    /// Recover the final-size estimate for a row adopted on relaunch (#169). `progress` was computed
    /// as `bytes / expected`, so invert it; nil when we have no usable signal (the planner then
    /// degrades to a single open-ended chunk and resolves completion via short-read / 416).
    private static func derivedExpectedBytes(_ record: DownloadRecord) -> Int? {
        guard record.bytes > 0, record.progress > 0.0001 else { return nil }
        let expected = Int((Double(record.bytes) / min(record.progress, 1.0)).rounded())
        return expected > 0 ? expected : nil
    }

    private func isRangeHalted(ratingKey: String) -> Bool {
        lock.lock()
        let halted = haltedRangeKeys.contains(ratingKey)
        lock.unlock()
        return halted
    }

    /// `startRangeChunk` deliberately throws `CancellationError` when a user pause/delete races an
    /// internal continuation/retry. That is not a transfer failure: pause/delete owns the visible row
    /// transition, and the internal path must not overwrite it with `.failed` or a new red error.
    private func shouldSuppressRangeStartFailure(ratingKey: String,
                                                 error: Error,
                                                 context: String) -> Bool {
        let halted = isRangeHalted(ratingKey: ratingKey)
        guard halted || error is CancellationError else { return false }
        AppDiagnostics.record(.downloads, "downloads.range_start_cancelled", fields: [
            "download_id": .identifier(ratingKey),
            "context": .label(context),
            "halted": .bool(halted),
            "error": .error(error),
        ])
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
        guard !resumeData.isEmpty else { return false }
        let task = urlSession.downloadTask(withResumeData: resumeData)
        task.taskDescription = ratingKey
        lock.lock()
        retryCounts[ratingKey] = 0
        lastProgressNotify = nil
        loggedProgressMilestones[task.taskIdentifier] = []
        lastRangeProgressDiagnostic.removeValue(forKey: task.taskIdentifier)
        inflight[task.taskIdentifier] = (ratingKey, destination)
        lock.unlock()
        downloadLog.info("resume ratingKey=\(ratingKey, privacy: .public) bytes=\(resumeData.count, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.transfer_resume", fields: [
            "download_id": .identifier(ratingKey),
            "resume_blob_bytes": .bytes(resumeData.count),
        ])
        task.resume()
        return true
    }

    private func pauseStillApplies(ratingKey: String) -> Bool {
        guard let status = store.records.first(where: { $0.ratingKey == ratingKey })?.status,
              status == .queued || status == .downloading else { return false }
        lock.lock()
        let hasReplacement = inflight.values.contains { $0.ratingKey == ratingKey }
            || rangeInflight.values.contains { $0.ratingKey == ratingKey }
        lock.unlock()
        // If the user already resumed/retried and a replacement task is tracked, a delayed cancel
        // callback from the old task must not flip the new active row back to Paused.
        return !hasReplacement
    }

    /// Pause any in-flight transfer for a ratingKey. Prefer URLSession resume data for static
    /// byte-range-safe lanes; for forward-only transcode/remux streams, this still becomes a safe
    /// user pause (no auto-retry until Resume), but Resume restarts cleanly.
    func pause(ratingKey: String) {
        AppDiagnostics.record(.downloads, "downloads.pause_requested", fields: [
            "download_id": .identifier(ratingKey),
        ])

        lock.lock()
        let ids = Set(inflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
        let rangeIds = Set(rangeInflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
        inflight = inflight.filter { $0.value.ratingKey != ratingKey }
        if rangeIds.isEmpty {
            // No live Range task to drain; halt the chunk chain so a between-chunks continuation
            // cannot start behind the pause.
            haltedRangeKeys.insert(ratingKey)
        } else {
            // A Range task is live. Prefer a graceful checkpoint pause: let a bounded chunk append
            // and then halt before the next chunk. If it turns out to be a continuous remainder,
            // `pauseRangeTask` converts this to a hard halt/cancel below.
            gracefulRangePauseKeys.insert(ratingKey)
        }
        lock.unlock()

        // #169: opaque and range tasks share one session now — enumerate it once and dispatch each
        // matched task by lane (range entries are removed as `pauseRangeTask` matches them).
        urlSession.getAllTasks { tasks in
            var matched = false
            for task in tasks {
                if rangeIds.contains(task.taskIdentifier) {
                    matched = true
                    self.pauseRangeTask(task, ratingKey: ratingKey)
                } else if ids.contains(task.taskIdentifier) {
                    matched = true
                    if let downloadTask = task as? URLSessionDownloadTask {
                        downloadTask.cancel { resumeData in
                            let resumeBytes = resumeData?.count ?? 0
                            let supportsResume = self.store.supportsPersistedResumeData(ratingKey: ratingKey)
                            AppDiagnostics.record(.downloads, "downloads.pause_resume_data", fields: [
                                "download_id": .identifier(ratingKey),
                                "resume_data_present": .bool(resumeBytes > 0),
                                "resume_blob_bytes": .bytes(resumeBytes),
                                "supports_resume": .bool(supportsResume),
                                "task_type": .label("backgroundDownloadTask"),
                            ])
                            guard self.pauseStillApplies(ratingKey: ratingKey) else { return }
                            if let resumeData, !resumeData.isEmpty, supportsResume {
                                self.store.setResumeData(ratingKey: ratingKey, resumeData)
                            }
                            self.markPausedAfterUserPause(ratingKey: ratingKey)
                        }
                    } else {
                        task.cancel()
                        self.markPausedAfterUserPause(ratingKey: ratingKey)
                    }
                }
            }

            if !matched {
                // No live task owned this row (paused in the gap between chunks, or a relaunch race).
                // Drop any stale range tracking; the durable partial keeps the row resumable.
                let removedRangeEntries = self.removeRangeTransfers(taskIdentifiers: rangeIds)
                let expectedBytes = removedRangeEntries.first?.expectedBytes
                self.clearGracefulRangePause(ratingKey: ratingKey)
                self.store.resetStaticRangeProgressToDurableCheckpoint(
                    ratingKey: ratingKey,
                    expectedBytes: expectedBytes
                )
                AppDiagnostics.record(.downloads, "downloads.pause_no_matching_task", fields: [
                    "download_id": .identifier(ratingKey),
                    "background_task_ids": .int(ids.count),
                    "range_task_ids": .int(rangeIds.count),
                ])
                if self.pauseStillApplies(ratingKey: ratingKey) {
                    self.store.setStatus(ratingKey: ratingKey, .paused)
                    self.onChange?()
                }
            }
        }
    }

    private func pauseRangeTask(_ task: URLSessionTask, ratingKey: String) {
        lock.lock()
        if let entry = rangeInflight[task.taskIdentifier],
           RangeTransferHTTPPolicy.isDurableCheckpointSegment(entry.segmentKind) {
            gracefulRangePauseKeys.insert(ratingKey)
            lock.unlock()
            AppDiagnostics.record(.downloads, "downloads.range_pause_after_checkpoint", fields: [
                "download_id": .identifier(ratingKey),
                "task_id": .int(task.taskIdentifier),
                "base_offset": .int(entry.baseOffset),
                "chunk_bytes": .int(entry.chunkBytesWritten),
                "expected_bytes": .bytes(entry.expectedBytes),
            ])
            return
        }
        let entry = rangeInflight.removeValue(forKey: task.taskIdentifier)
        gracefulRangePauseKeys.remove(ratingKey)
        haltedRangeKeys.insert(ratingKey)
        lock.unlock()
        endRangeBackgroundHandoffGrace(taskIdentifier: task.taskIdentifier,
                                       ratingKey: ratingKey,
                                       reason: "paused")
        task.cancel()

        let partialFilePresent = entry.map { fileManager.fileExists(atPath: $0.destination.path) } ?? false
        let bytes = store.resetStaticRangeProgressToDurableCheckpoint(
            ratingKey: ratingKey,
            expectedBytes: entry?.expectedBytes
        )
        AppDiagnostics.record(.downloads, "downloads.range_checkpoint_paused", fields: [
            "download_id": .identifier(ratingKey),
            "bytes": .bytes(bytes),
            "expected_bytes": .bytes(entry?.expectedBytes),
            "partial_file_present": .bool(partialFilePresent),
            "task_type": .label("rangeDownloadTask"),
            "segment_kind": .label(entry?.segmentKind.rawValue ?? "unknown"),
        ])
        markPausedAfterUserPause(ratingKey: ratingKey)
    }

    private func clearGracefulRangePause(ratingKey: String) {
        lock.lock()
        gracefulRangePauseKeys.remove(ratingKey)
        lock.unlock()
    }

    private func consumeGracefulRangePause(ratingKey: String) -> Bool {
        lock.lock()
        let requested = gracefulRangePauseKeys.remove(ratingKey) != nil
        if requested {
            haltedRangeKeys.insert(ratingKey)
        }
        lock.unlock()
        return requested
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

    private func markPausedAfterUserPause(ratingKey: String) {
        guard pauseStillApplies(ratingKey: ratingKey) else { return }
        store.setStatus(ratingKey: ratingKey, .paused)
        onError?(ratingKey, .interruptedResumable)
        onChange?()
    }

    /// Cancel any in-flight transfer for a ratingKey.
    func cancel(ratingKey: String) {
        AppDiagnostics.record(.downloads, "downloads.cancel_requested", fields: [
            "download_id": .identifier(ratingKey),
        ])
        lock.lock()
        let ids = Set(inflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
        let rangeIds = Set(rangeInflight.filter { $0.value.ratingKey == ratingKey }.map(\.key))
        inflight = inflight.filter { $0.value.ratingKey != ratingKey }
        rangeInflight = rangeInflight.filter { $0.value.ratingKey != ratingKey }
        // Halt the chunk chain so a chunk completing after this snapshot can't append/resurrect the
        // file the caller is about to delete, nor start a fresh chunk our cancel won't see.
        haltedRangeKeys.insert(ratingKey)
        gracefulRangePauseKeys.remove(ratingKey)
        lock.unlock()
        for taskIdentifier in rangeIds {
            endRangeBackgroundHandoffGrace(taskIdentifier: taskIdentifier,
                                           ratingKey: ratingKey,
                                           reason: "cancelled")
        }

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
        lock.lock()
        let rangeEntry = rangeInflight[downloadTask.taskIdentifier]
        let entry = rangeEntry == nil ? inflight[downloadTask.taskIdentifier] : nil
        let firstCallback = (rangeEntry != nil || entry != nil)
            && loggedExpectation.insert(downloadTask.taskIdentifier).inserted
        lock.unlock()

        if let rangeEntry {
            // #169: a Range chunk's bytes accumulate in the OS temp; live progress is the durable
            // partial already on disk (`baseOffset`) plus this chunk's bytes so far, against the
            // FILE's expected size. The chunk's own `totalBytesExpectedToWrite` is just this slice.
            let chunkBytesWritten = Int(totalBytesWritten)
            lock.lock()
            let halted = haltedRangeKeys.contains(rangeEntry.ratingKey)
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
                    "chunk_bytes": .int(chunkBytesWritten),
                ])
                return
            }
            let durableBytes = fileSize(at: rangeEntry.destination) ?? 0
            if durableBytes > rangeEntry.baseOffset {
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
                    "chunk_bytes": .int(chunkBytesWritten),
                    "total_bytes": .int(rangeEntry.baseOffset + chunkBytesWritten),
                    "reason": .label("durable_checkpoint_ahead"),
                ])
                return
            }
            lock.lock()
            if let newerTaskIdentifier = newerRangeTaskIdentifier(for: rangeEntry,
                                                                   currentTaskIdentifier: downloadTask.taskIdentifier,
                                                                   currentChunkBytes: chunkBytesWritten) {
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
                    "chunk_bytes": .int(chunkBytesWritten),
                    "total_bytes": .int(rangeEntry.baseOffset + chunkBytesWritten),
                ])
                return
            }
            lock.unlock()

            let total = rangeEntry.baseOffset + chunkBytesWritten
            let responseExpectedBytes = RangeTransferHTTPPolicy.contentRangeTotal(from: downloadTask.response as? HTTPURLResponse)
            let effectiveExpectedBytes = responseExpectedBytes ?? rangeEntry.expectedBytes
            if responseExpectedBytes != nil {
                store.setSourcePartSize(ratingKey: rangeEntry.ratingKey, effectiveExpectedBytes)
            } else {
                store.setSourcePartSizeIfMissing(ratingKey: rangeEntry.ratingKey, effectiveExpectedBytes)
            }
            // A Range chunk's in-flight bytes live in an OS temp file until
            // `didFinishDownloadingTo` lets us append them to the durable partial. Keep the visible
            // row/aggregate "downloaded" total pinned to the last real checkpoint; detailed
            // diagnostics still report optimistic `total_bytes`. This prevents Pause/Pause All from
            // appearing to lose bytes that were never actually resumable.
            let checkpointBytes = durableBytes
            let progress = (effectiveExpectedBytes ?? 0) > 0
                ? min(1, Double(checkpointBytes) / Double(effectiveExpectedBytes!))
                : 0
            lock.lock()
            let gracefulPausePending = gracefulRangePauseKeys.contains(rangeEntry.ratingKey)
            if var live = rangeInflight[downloadTask.taskIdentifier] {
                live.chunkBytesWritten = chunkBytesWritten
                rangeInflight[downloadTask.taskIdentifier] = live
            }
            retryCounts[rangeEntry.ratingKey] = 0
            lock.unlock()
            if !gracefulPausePending {
                store.updateProgress(ratingKey: rangeEntry.ratingKey, bytes: checkpointBytes, progress: progress)
            }
            onRangeLiveProgress?(rangeEntry.ratingKey, total, effectiveExpectedBytes)
            recordRangeProgressIfNeeded(taskIdentifier: downloadTask.taskIdentifier,
                                        entry: rangeEntry,
                                        chunkBytes: Int(totalBytesWritten),
                                        totalBytes: total,
                                        expectedBytes: effectiveExpectedBytes,
                                        progress: progress,
                                        firstCallback: firstCallback)
            notifyProgressChangeIfNeeded(ratingKey: rangeEntry.ratingKey, progress: progress)
            return
        }

        guard let entry else { return }
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
        store.updateProgress(ratingKey: entry.ratingKey,
                             bytes: Int(totalBytesWritten),
                             progress: progress)
        notifyProgressChangeIfNeeded(ratingKey: entry.ratingKey, progress: progress)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        let superseded = supersededRangeTaskIdentifiers.remove(downloadTask.taskIdentifier) != nil
        let rangeEntry = superseded ? nil : rangeInflight[downloadTask.taskIdentifier]
        let entry = (rangeEntry == nil && !superseded) ? inflight[downloadTask.taskIdentifier] : nil
        let newerTaskIdentifier = rangeEntry.flatMap {
            newerRangeTaskIdentifier(for: $0,
                                     currentTaskIdentifier: downloadTask.taskIdentifier,
                                     currentChunkBytes: max(0, Int(downloadTask.countOfBytesReceived)))
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
                "chunk_bytes": .int(max(0, Int(downloadTask.countOfBytesReceived))),
            ])
            return
        }
        if superseded {
            AppDiagnostics.record(.downloads, "downloads.range_superseded_finish_ignored", fields: [
                "task_id": .int(downloadTask.taskIdentifier),
            ])
            return
        }
        // #169: a finished Range chunk folds into the durable partial and either starts the next
        // chunk or finalizes the whole file — never a straight temp→destination move.
        if let rangeEntry {
            finishRangeChunk(rangeEntry, taskIdentifier: downloadTask.taskIdentifier,
                             response: downloadTask.response, location: location)
            return
        }
        guard let entry else { return }

        // Helper: a finished transfer that isn't actually a usable video must NOT be
        // left in place as "complete" (D1). Record a `.failed` row + surface why, and
        // delete the bad file so a retry starts clean.
        func fail(_ reason: String) {
            downloadLog.error("invalid-download ratingKey=\(entry.ratingKey, privacy: .public) reason=\(reason, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "reason": .text(reason),
            ])
            try? fileManager.removeItem(at: entry.destination)
            clearRetryCount(ratingKey: entry.ratingKey)
            store.setStatus(ratingKey: entry.ratingKey, .failed)
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
                let bodyBytes = (try? Data(contentsOf: location))?.count
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
            try? fileManager.removeItem(at: entry.destination)
            try fileManager.moveItem(at: location, to: entry.destination)
        } catch {
            AppDiagnostics.record(.downloads, "downloads.move_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "error": .error(error),
            ])
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer")))
            onChange?()
            return
        }

        // 3. Size observation — tiny bodies used to be rejected categorically here. That caught
        // error pages, but it also made valid short clips/trailers impossible to download. HTTP
        // status + MIME catches obvious server errors above; let the AVFoundation probe below be
        // the source of truth for small-but-valid media.
        let bytes = (try? fileManager.attributesOfItem(atPath: entry.destination.path)[.size] as? Int)
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
        publishTransferFinalizing(ratingKey: entry.ratingKey, bytes: bytes)
        let destination = entry.destination
        let ratingKey = entry.ratingKey

        // GH #135: the fixup + #98 retrying probe + truncation guard + complete/unverified decision
        // are shared with the byte-range pipeline via `finalizeTransferredFile` so a static download
        // is validated identically no matter how its bytes arrived (this opaque path historically
        // ran them; the range path skipped them — #127 black-screen / H1–H3).
        beginPendingBackgroundCompletionOperation()
        Task { [self] in
            defer { endPendingBackgroundCompletionOperation() }
            await finalizeTransferredFile(ratingKey: ratingKey,
                                          destination: destination,
                                          bytes: bytes,
                                          validationLabel: "local_playback")
        }
    }

    /// Fold a finished Range chunk into the durable partial and either start the next chunk or
    /// finalize the whole file (#169). Runs in the download delegate, off the main actor. The chunk's
    /// tracking is removed here so the trailing `didCompleteWithError(nil)` is a no-op.
    private func finishRangeChunk(_ entry: RangeTransfer,
                                  taskIdentifier: Int,
                                  response: URLResponse?,
                                  location: URL) {
        lock.lock()
        rangeInflight.removeValue(forKey: taskIdentifier)
        loggedProgressMilestones.removeValue(forKey: taskIdentifier)
        lastRangeProgressDiagnostic.removeValue(forKey: taskIdentifier)
        let halted = haltedRangeKeys.contains(entry.ratingKey)
        lock.unlock()

        // The row was cancelled or paused while this chunk was finishing. A hard cancel/delete must
        // still discard the temp (the caller may be deleting the partial), but a user/system PAUSE
        // should preserve a just-finished chunk: otherwise the delegate can log
        // `range_chunk_finished`, then the async append sees the pause halt and silently throws away
        // tens of MB/GB of completed work. That is the restart-from-0-ish race seen after relaunch.
        if StaticRangeFinishedChunkPolicy.shouldDiscardBeforeStash(
            isHalted: halted,
            persistedStatusPaused: shouldPreserveHaltedFinishedRangeChunk(ratingKey: entry.ratingKey)
        ) {
            endRangeBackgroundHandoffGrace(taskIdentifier: taskIdentifier,
                                           ratingKey: entry.ratingKey,
                                           reason: "halted")
            AppDiagnostics.record(.downloads, "downloads.range_chunk_halted", fields: [
                "download_id": .identifier(entry.ratingKey),
                "offset_bytes": .bytes(entry.baseOffset),
                "segment_kind": .label(entry.segmentKind.rawValue),
            ])
            return
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        AppDiagnostics.record(.downloads, "downloads.range_chunk_finished", fields: [
            "download_id": .identifier(entry.ratingKey),
            "http_status": .int(status),
            "offset_bytes": .bytes(entry.baseOffset),
            "segment_kind": .label(entry.segmentKind.rawValue),
            "segment_reason": .label(entry.segmentReason ?? "unknown"),
        ])
        if entry.segmentKind == .continuousRemainder {
            AppDiagnostics.record(.downloads, "downloads.range_remainder_finished", fields: [
                "download_id": .identifier(entry.ratingKey),
                "http_status": .int(status),
                "offset_bytes": .bytes(entry.baseOffset),
                "segment_reason": .label(entry.segmentReason ?? "unknown"),
            ])
        }

        let write = rangeChunkPlanner.writeDecision(httpStatus: status, offset: entry.baseOffset)
        switch write {
        case .failServer(let code):
            endRangeBackgroundHandoffGrace(taskIdentifier: taskIdentifier,
                                           ratingKey: entry.ratingKey,
                                           reason: "server_failure")
            // The chunk body (an error page) is in the OS temp, NEVER appended into the durable
            // partial, so the partial's completed chunks stay intact and resumable.
            let durableBytes = store.resetStaticRangeProgressToDurableCheckpoint(
                ratingKey: entry.ratingKey,
                expectedBytes: entry.expectedBytes
            )
            AppDiagnostics.record(.downloads, "downloads.range_failed", fields: [
                "download_id": .identifier(entry.ratingKey),
                "segment_kind": .label(entry.segmentKind.rawValue),
                "status_code": .int(code),
                "bytes": .bytes(durableBytes),
            ])
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .transferFailed("Server returned HTTP \(code)."))
            onChange?()

        case .alreadyComplete:
            // HTTP 416: only "already complete" if the durable partial matches the server's
            // reported total. If the server says more bytes exist, keep requesting from the real
            // checkpoint instead of validating a truncated partial.
            let durableBytes = fileSize(at: entry.destination) ?? entry.baseOffset
            let contentRangeTotal = RangeTransferHTTPPolicy.contentRangeTotal(from: http)
            if let contentRangeTotal {
                store.setSourcePartSize(ratingKey: entry.ratingKey, contentRangeTotal)
            }
            let effectiveEntry = entry.replacingExpectedBytes(contentRangeTotal ?? entry.expectedBytes)
            if let contentRangeTotal, durableBytes != contentRangeTotal {
                AppDiagnostics.record(.downloads, "downloads.range_416_mismatch", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "segment_kind": .label(entry.segmentKind.rawValue),
                    "durable_bytes": .bytes(durableBytes),
                    "server_total_bytes": .bytes(contentRangeTotal),
                ])
                if durableBytes < contentRangeTotal {
                    continueRangeAfterChunk(entry: effectiveEntry, partialSize: durableBytes)
                } else {
                    restartRangeFromChangedResource(entry: effectiveEntry)
                }
                endRangeBackgroundHandoffGrace(taskIdentifier: taskIdentifier,
                                               ratingKey: entry.ratingKey,
                                               reason: "already_complete_mismatch")
                return
            }
            finalizeRangeWhole(entry: effectiveEntry)
            endRangeBackgroundHandoffGrace(taskIdentifier: taskIdentifier,
                                           ratingKey: entry.ratingKey,
                                           reason: "already_complete")

        case .append, .replaceWhole:
            // The 64 MB append/replace must not block the serial delegate queue. Synchronously stash
            // the OS temp (a same-volume rename, O(1)) so it survives past this delegate's return,
            // capture the response headers we still need (#169 HIGH 1), then do the heavy IO + chunk
            // decision off-queue.
            let stash = chunkStashURL(taskIdentifier: taskIdentifier)
            do {
                try? fileManager.removeItem(at: stash)
                try fileManager.moveItem(at: location, to: stash)
            } catch {
                endRangeBackgroundHandoffGrace(taskIdentifier: taskIdentifier,
                                               ratingKey: entry.ratingKey,
                                               reason: "move_failed")
                failRangeMove(entry: entry, error: error)
                return
            }
            let validator = RangeTransferHTTPPolicy.rangeValidator(from: http)
            let contentRangeStart = RangeTransferHTTPPolicy.contentRangeStart(from: http)
            let contentRangeTotal = RangeTransferHTTPPolicy.contentRangeTotal(from: http)
            beginPendingBackgroundCompletionOperation()
            endRangeBackgroundHandoffGrace(taskIdentifier: taskIdentifier,
                                           ratingKey: entry.ratingKey,
                                           reason: "finished")
            rangeIOQueue.async { [self] in
                defer { endPendingBackgroundCompletionOperation() }
                applyFinishedChunk(entry: entry, write: write, stash: stash,
                                   validator: validator, contentRangeStart: contentRangeStart,
                                   contentRangeTotal: contentRangeTotal)
            }
        }
    }

    /// Off-queue (on `rangeIOQueue`) tail of `finishRangeChunk`: fold the stashed chunk into the
    /// durable partial and either finalize or start the next chunk. Validates the resource hasn't
    /// shifted under us before appending (#169 HIGH 1).
    private func applyFinishedChunk(entry: RangeTransfer, write: RangeChunkWrite, stash: URL,
                                    validator: String?, contentRangeStart: Int?,
                                    contentRangeTotal: Int?) {
        if let contentRangeTotal {
            store.setSourcePartSize(ratingKey: entry.ratingKey, contentRangeTotal)
        }
        let effectiveExpectedBytes = contentRangeTotal ?? entry.expectedBytes
        let entry = entry.replacingExpectedBytes(effectiveExpectedBytes)
        // A cancel/pause may have landed during the delegate→IO hop.
        lock.lock(); let halted = haltedRangeKeys.contains(entry.ratingKey); lock.unlock()
        let persistedStatusPaused = shouldPreserveHaltedFinishedRangeChunk(ratingKey: entry.ratingKey)
        let pauseAfterCheckpoint: Bool
        if RangeTransferHTTPPolicy.isDurableCheckpointSegment(entry.segmentKind) {
            pauseAfterCheckpoint = consumeGracefulRangePause(ratingKey: entry.ratingKey)
        } else {
            // If a continuous remainder happens to finish before the async pause/cancel callback
            // reaches it, completion is better than parking a full file as paused.
            clearGracefulRangePause(ratingKey: entry.ratingKey)
            pauseAfterCheckpoint = false
        }
        let finishedChunkDisposition = StaticRangeFinishedChunkPolicy.disposition(
            isHalted: halted,
            persistedStatusPaused: persistedStatusPaused,
            segmentKind: entry.segmentKind,
            gracefulPauseRequested: pauseAfterCheckpoint
        )
        if finishedChunkDisposition == .discardTemp {
            let stashBytes = fileSize(at: stash)
            try? fileManager.removeItem(at: stash)
            AppDiagnostics.record(.downloads, "downloads.range_halted_chunk_discarded", fields: [
                "download_id": .identifier(entry.ratingKey),
                "segment_kind": .label(entry.segmentKind.rawValue),
                "base_offset": .int(entry.baseOffset),
                "chunk_bytes": .int(stashBytes ?? -1),
            ])
            return
        }
        let durableBytesBeforeWrite = fileSize(at: entry.destination) ?? 0
        if durableBytesBeforeWrite > entry.baseOffset {
            let stashBytes = fileSize(at: stash)
            try? fileManager.removeItem(at: stash)
            AppDiagnostics.record(.downloads, "downloads.range_stale_chunk_ignored", fields: [
                "download_id": .identifier(entry.ratingKey),
                "segment_kind": .label(entry.segmentKind.rawValue),
                "base_offset": .int(entry.baseOffset),
                "durable_bytes": .int(durableBytesBeforeWrite),
                "chunk_bytes": .int(stashBytes ?? -1),
                "reason": .label("durable_checkpoint_ahead"),
            ])
            onChange?()
            return
        }

        switch write {
        case .replaceWhole:
            // HTTP 200: the server sent the whole CURRENT resource — replace the partial honestly
            // rather than appending real bytes after a stale prefix.
            do {
                try? fileManager.removeItem(at: entry.destination)
                try fileManager.moveItem(at: stash, to: entry.destination)
            } catch {
                try? fileManager.removeItem(at: stash)
                failRangeMove(entry: entry, error: error)
                return
            }
            if let validator { store.setRangeValidator(ratingKey: entry.ratingKey, validator) }
            if finishedChunkDisposition == .writeThenPause {
                let bytes = fileSize(at: entry.destination) ?? 0
                store.updateProgress(ratingKey: entry.ratingKey,
                                     bytes: bytes,
                                     progress: (entry.expectedBytes ?? 0) > 0
                                        ? min(1, Double(bytes) / Double(entry.expectedBytes!)) : 0)
                AppDiagnostics.record(.downloads, "downloads.range_halted_chunk_preserved", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "segment_kind": .label(entry.segmentKind.rawValue),
                    "base_offset": .int(entry.baseOffset),
                    "partial_bytes": .int(bytes),
                    "write": .label("replaceWhole"),
                    "pause_after_checkpoint": .bool(pauseAfterCheckpoint),
                ])
                store.setStatus(ratingKey: entry.ratingKey, .paused)
                onChange?()
                return
            }
            finalizeRangeWhole(entry: entry)

        case .append:
            let durableBytesBeforeAppend = durableBytesBeforeWrite
            if durableBytesBeforeAppend < entry.baseOffset {
                try? fileManager.removeItem(at: stash)
                AppDiagnostics.record(.downloads, "downloads.range_checkpoint_gap", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "segment_kind": .label(entry.segmentKind.rawValue),
                    "base_offset": .int(entry.baseOffset),
                    "durable_bytes": .int(durableBytesBeforeAppend),
                    "server_offset": .int(contentRangeStart ?? -1),
                ])
                if retryRangeOffsetMismatch(entry: entry,
                                            durableBytes: durableBytesBeforeAppend,
                                            serverOffset: contentRangeStart) {
                    return
                }
                store.setStatus(ratingKey: entry.ratingKey, .failed)
                onError?(entry.ratingKey, .transferFailed("Download checkpoint no longer matches the finished byte range."))
                onChange?()
                return
            }
            // #169 HIGH 1, primary defense: Plex (the main backend) IGNORES `If-Range` — it returns a
            // 206 from the SAME offset even for a non-matching validator (probed live, deterministic),
            // so we cannot rely on the server downgrading a changed resource to 200. Instead COMPARE
            // the chunk's validator against the one pinned on the first chunk; a definite mismatch means
            // the resource changed underneath us. The body is a middle slice from `baseOffset` (not the
            // whole file), so we can neither append (splices new bytes after a stale prefix → the exact
            // corruption HIGH 1 targets) nor `replaceWhole` — we discard the stale partial and restart
            // from 0. Only act on a present-and-different validator: a nil/absent one (transient header
            // omission) must not trigger a restart loop. Emby/JF still also get the `If-Range` 200 path.
            if entry.baseOffset > 0,
               let stored = store.rangeValidator(ratingKey: entry.ratingKey),
               let current = validator, current != stored {
                restartRangeFromChangedResource(entry: entry)
                try? fileManager.removeItem(at: stash)
                return
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
            if misaligned, RangeTransferHTTPPolicy.isCompleteInternallyResumedRangeChunk(
                baseOffset: entry.baseOffset,
                contentRangeStart: contentRangeStart,
                stashBytes: stashBytesBeforeAppend,
                expectedSegmentBytes: expectedRangeSegmentBytes(entry: entry)
            ) {
                AppDiagnostics.record(.downloads, "downloads.range_internal_resume_adopted", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "expected_offset": .bytes(entry.baseOffset),
                    "expected_offset_exact": .int(entry.baseOffset),
                    "server_offset": .bytes(contentRangeStart),
                    "server_offset_exact": .int(contentRangeStart ?? -1),
                    "stash_bytes": .bytes(stashBytesBeforeAppend),
                    "stash_bytes_exact": .int(stashBytesBeforeAppend ?? -1),
                    "segment_kind": .label(entry.segmentKind.rawValue),
                    "expected_segment_bytes": .int(expectedRangeSegmentBytes(entry: entry) ?? -1),
                ])
            } else if misaligned {
                try? fileManager.removeItem(at: stash)
                let durableBytes = store.resetStaticRangeProgressToDurableCheckpoint(
                    ratingKey: entry.ratingKey,
                    expectedBytes: entry.expectedBytes
                )
                AppDiagnostics.record(.downloads, "downloads.range_offset_mismatch", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "segment_kind": .label(entry.segmentKind.rawValue),
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
                store.setStatus(ratingKey: entry.ratingKey, .failed)
                onError?(entry.ratingKey, .transferFailed("Server returned a misaligned byte range."))
                onChange?()
                return
            }
            let chunkBytes: Int
            do {
                chunkBytes = try appendFile(at: stash, onto: entry.destination)
            } catch {
                try? fileManager.removeItem(at: stash)
                failRangeMove(entry: entry, error: error)
                return
            }
            try? fileManager.removeItem(at: stash)
            // Forward progress: this chunk's validator matched, so the resource is stable again — clear
            // the consecutive validator-change restart counter (#169 HIGH 1 livelock bound).
            lock.lock()
            staticRangeRetryBudget.reset(downloadID: entry.ratingKey)
            lock.unlock()
            // Pin the resource on the FIRST successful chunk so the rest send `If-Range`.
            if let validator, store.rangeValidator(ratingKey: entry.ratingKey) == nil {
                store.setRangeValidator(ratingKey: entry.ratingKey, validator)
            } else if validator == nil, entry.baseOffset == 0 {
                // No usable strong validator: subsequent chunks can't send `If-Range`, so a resource
                // that changes mid-download would be appended unprotected. Record it so the
                // unprotected case is observable rather than silent (#169 MEDIUM 1).
                AppDiagnostics.record(.downloads, "downloads.range_validator_absent", fields: [
                    "download_id": .identifier(entry.ratingKey),
                ])
            }
            let partialSize = fileSize(at: entry.destination) ?? (entry.baseOffset + chunkBytes)
            store.updateProgress(ratingKey: entry.ratingKey,
                                 bytes: partialSize,
                                 progress: (entry.expectedBytes ?? 0) > 0
                                    ? min(1, Double(partialSize) / Double(entry.expectedBytes!)) : 0)
            AppDiagnostics.record(.downloads, "downloads.range_chunk_appended", fields: [
                "download_id": .identifier(entry.ratingKey),
                "segment_kind": .label(entry.segmentKind.rawValue),
                "base_offset": .int(entry.baseOffset),
                "chunk_bytes": .int(chunkBytes),
                "partial_bytes": .int(partialSize),
                "expected_exact": .int(entry.expectedBytes ?? -1),
            ])

            if finishedChunkDisposition == .writeThenPause {
                AppDiagnostics.record(.downloads, "downloads.range_halted_chunk_preserved", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "segment_kind": .label(entry.segmentKind.rawValue),
                    "base_offset": .int(entry.baseOffset),
                    "chunk_bytes": .int(chunkBytes),
                    "partial_bytes": .int(partialSize),
                    "write": .label("append"),
                    "pause_after_checkpoint": .bool(pauseAfterCheckpoint),
                ])
                // `updateProgress` promotes paused rows to `.downloading` because a normal append is
                // live work. This append, however, is the tail of a pause race: preserve the bytes but
                // do not start the next chunk behind the user's/system's pause.
                store.setStatus(ratingKey: entry.ratingKey, .paused)
                onChange?()
                return
            }

            switch rangeChunkPlanner.nextStep(partialSize: partialSize,
                                              expectedBytes: entry.expectedBytes,
                                              chunkBytes: chunkBytes,
                                              kind: entry.segmentKind) {
            case .complete:
                finalizeRangeWhole(entry: entry)
            case .stalled:
                AppDiagnostics.record(.downloads, "downloads.range_incomplete", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "segment_kind": .label(entry.segmentKind.rawValue),
                    "bytes": .bytes(partialSize),
                    "expected_bytes": .bytes(entry.expectedBytes),
                ])
                store.setStatus(ratingKey: entry.ratingKey, .failed)
                onError?(entry.ratingKey, .transferFailed("Download stalled with no progress."))
                onChange?()
            case .continueFrom:
                continueRangeAfterChunk(entry: entry, partialSize: partialSize)
            }

        case .failServer, .alreadyComplete:
            break // resolved inline in finishRangeChunk; never offloaded
        }
    }

    private func shouldPreserveHaltedFinishedRangeChunk(ratingKey: String) -> Bool {
        store.status(for: ratingKey) == .paused
    }

    private func chunkStashURL(taskIdentifier: Int) -> URL {
        // The OS background temp and our temporaryDirectory share the app-container volume, so the
        // stash move is an O(1) rename. Unique per task id (unique within a session) and deleted
        // after the append/replace consumes it.
        fileManager.temporaryDirectory.appendingPathComponent("vp-range-chunk-\(taskIdentifier)")
    }

    private func expectedRangeSegmentBytes(entry: RangeTransfer) -> Int? {
        rangeChunkPlanner.expectedSegmentBytes(offset: entry.baseOffset,
                                               expectedBytes: entry.expectedBytes,
                                               kind: entry.segmentKind)
    }

    /// Start the next Range chunk if we still hold the request (same launch); otherwise persist a
    /// system-resume intent so DownloadManager rebuilds the request and continues from the durable
    /// partial (a relaunch-adopted chunk has no in-memory request — its auth headers can't be
    /// reconstructed).
    private func continueRangeAfterChunk(entry: RangeTransfer, partialSize: Int) {
        // Defense in depth alongside the `finishRangeChunk` halt gate: never start a chunk behind a
        // concurrent cancel/pause.
        lock.lock(); let halted = haltedRangeKeys.contains(entry.ratingKey); lock.unlock()
        if halted { return }
        guard let request = entry.request else {
            AppDiagnostics.record(.downloads, "downloads.range_chunk_relaunch_pause", fields: [
                "download_id": .identifier(entry.ratingKey),
                "segment_kind": .label(entry.segmentKind.rawValue),
                "bytes": .bytes(partialSize),
            ])
            // Persist active system-resume intent before the in-memory callback. If the app is killed
            // again before DownloadManager rebuilds the authenticated request, launch reconciliation
            // can derive that this non-user-paused row should continue from the durable checkpoint.
            store.setStatus(ratingKey: entry.ratingKey, .queued)
            onRangeRequestNeeded?(entry.ratingKey, .adoptedChunkFinished)
            return
        }
        do {
            let holdBackgroundCompletion = hasPendingBackgroundCompletionHandler()
            try startRangeChunk(ratingKey: entry.ratingKey, with: request, to: entry.destination,
                                expectedBytes: entry.expectedBytes, resetsRetryCount: false,
                                holdBackgroundCompletionForFirstProgress: holdBackgroundCompletion)
        } catch {
            if shouldSuppressRangeStartFailure(ratingKey: entry.ratingKey,
                                               error: error,
                                               context: "continue_chunk") {
                onChange?()
                return
            }
            store.setStatus(ratingKey: entry.ratingKey, .paused)
            onError?(entry.ratingKey, .interruptedResumable)
            onChange?()
        }
    }

    /// A misaligned 206 body has NOT been appended, so the durable partial is still safe. Treat it
    /// like a transient chunk failure first: discard the bad temp and re-request the SAME checkpoint
    /// a few times before surfacing a terminal error. This covers server/proxy/background-daemon
    /// oddities observed on Emby where a later chunk can occasionally come back with an absent or
    /// unexpected `Content-Range`; failing immediately strands a valid multi-GB checkpoint even
    /// though a clean retry can continue without corruption.
    private func retryRangeOffsetMismatch(entry: RangeTransfer, durableBytes: Int, serverOffset: Int?) -> Bool {
        lock.lock()
        let halted = haltedRangeKeys.contains(entry.ratingKey)
        let retryAttempt = staticRangeRetryBudget.recordOffsetMismatch(downloadID: entry.ratingKey)
        lock.unlock()

        if halted { return true }

        guard !retryAttempt.isExhausted else {
            lock.lock(); staticRangeRetryBudget.resetOffsetMismatch(downloadID: entry.ratingKey); lock.unlock()
            AppDiagnostics.record(.downloads, "downloads.range_offset_retry_exhausted", fields: [
                "download_id": .identifier(entry.ratingKey),
                "segment_kind": .label(entry.segmentKind.rawValue),
                "attempt": .int(retryAttempt.attempt - 1),
                "expected_offset": .bytes(entry.baseOffset),
                "expected_offset_exact": .int(entry.baseOffset),
                "server_offset": .bytes(serverOffset),
                "server_offset_exact": .int(serverOffset ?? -1),
                "bytes": .bytes(durableBytes),
                "bytes_exact": .int(durableBytes),
            ])
            return false
        }

        AppDiagnostics.record(.downloads, "downloads.range_offset_retry", fields: [
            "download_id": .identifier(entry.ratingKey),
            "segment_kind": .label(entry.segmentKind.rawValue),
            "attempt": .int(retryAttempt.attempt),
            "expected_offset": .bytes(entry.baseOffset),
            "expected_offset_exact": .int(entry.baseOffset),
            "server_offset": .bytes(serverOffset),
            "server_offset_exact": .int(serverOffset ?? -1),
            "bytes": .bytes(durableBytes),
            "bytes_exact": .int(durableBytes),
        ])

        guard let request = entry.request else {
            // Relaunch-adopted chunk: the bad temp is gone and the durable partial remains the
            // checkpoint, but this object lacks auth headers. Persist an active continuation intent
            // so DownloadManager rebuilds the backend-owned request and resumes automatically.
            store.setStatus(ratingKey: entry.ratingKey, .queued)
            onRangeRequestNeeded?(entry.ratingKey, .adoptedChunkFailed)
            onChange?()
            return true
        }

        do {
            let holdBackgroundCompletion = hasPendingBackgroundCompletionHandler()
            try startRangeChunk(ratingKey: entry.ratingKey,
                                with: request,
                                to: entry.destination,
                                expectedBytes: entry.expectedBytes,
                                resetsRetryCount: false,
                                holdBackgroundCompletionForFirstProgress: holdBackgroundCompletion)
            onChange?()
            return true
        } catch {
            if shouldSuppressRangeStartFailure(ratingKey: entry.ratingKey,
                                               error: error,
                                               context: "offset_retry") {
                onChange?()
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

    /// The pinned resource validator changed mid-download (#169 HIGH 1, Plex path): the durable partial
    /// is now a stale prefix and the just-fetched chunk is bytes from a different resource. Throw both
    /// away and restart from offset 0 so the partial is rebuilt against the current resource — the only
    /// honest recovery when the server won't downgrade a changed resource to a whole-file 200.
    private func restartRangeFromChangedResource(entry: RangeTransfer) {
        lock.lock()
        let halted = haltedRangeKeys.contains(entry.ratingKey)
        let retryAttempt = staticRangeRetryBudget.recordValidatorChange(downloadID: entry.ratingKey)
        lock.unlock()
        AppDiagnostics.record(.downloads, "downloads.range_validator_changed", fields: [
            "download_id": .identifier(entry.ratingKey),
            "segment_kind": .label(entry.segmentKind.rawValue),
            "bytes": .bytes(entry.baseOffset),
            "restart_count": .int(retryAttempt.attempt),
        ])
        try? fileManager.removeItem(at: entry.destination)
        store.clearRangeValidator(ratingKey: entry.ratingKey)
        store.updateProgress(ratingKey: entry.ratingKey, bytes: 0, progress: 0)
        if halted { return }
        // Bound the loop: a validator that keeps changing per-response (mechanism certain, e.g. a
        // PlexOptimize Part still being written, or a load-balanced/proxied ETag) would otherwise spin
        // forever re-downloading from 0 with zero forward progress. After N consecutive restarts with
        // no successful append, fail clearly instead of livelocking.
        if retryAttempt.isExhausted {
            lock.lock()
            staticRangeRetryBudget.reset(downloadID: entry.ratingKey)
            lock.unlock()
            AppDiagnostics.record(.downloads, "downloads.range_validator_unstable", fields: [
                "download_id": .identifier(entry.ratingKey),
                "restart_count": .int(retryAttempt.attempt),
            ])
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .transferFailed("The source file kept changing during download."))
            onChange?()
            return
        }
        guard let request = entry.request else {
            // Relaunch-adopted chunk: no in-memory request to rebuild auth headers, and the stale
            // partial has already been discarded. Persist active restart intent before the in-memory
            // callback so a second app kill still auto-restarts from byte 0 on the next launch.
            store.setStatus(ratingKey: entry.ratingKey, .queued)
            onRangeRequestNeeded?(entry.ratingKey, .validatorChanged)
            return
        }
        do {
            // The partial was just deleted, so `startRangeChunk` derives offset 0 and pins a fresh
            // validator on the new first chunk.
            let holdBackgroundCompletion = hasPendingBackgroundCompletionHandler()
            try startRangeChunk(ratingKey: entry.ratingKey, with: request, to: entry.destination,
                                expectedBytes: entry.expectedBytes, resetsRetryCount: false,
                                holdBackgroundCompletionForFirstProgress: holdBackgroundCompletion)
        } catch {
            if shouldSuppressRangeStartFailure(ratingKey: entry.ratingKey,
                                               error: error,
                                               context: "validator_restart") {
                onChange?()
                return
            }
            store.setStatus(ratingKey: entry.ratingKey, .paused)
            onError?(entry.ratingKey, .interruptedResumable)
            onChange?()
        }
    }


    /// Recover a completed static byte-range file that survived a process/resource kill after the
    /// final chunk was appended but before `finalizeTransferredFile` wrote `.complete`/`.unverified`.
    /// This is the relaunch/manual-resume counterpart to `finalizeRangeWhole(entry:)`: keep the row
    /// at 100% + "Verifying download…" and run the normal local fixup/probe/truncation pipeline
    /// instead of trying to request another Range after EOF.
    @discardableResult
    func finalizeCompletedStaticRangeFile(ratingKey: String, validationLabel: String) -> Bool {
        guard let record = store.records.first(where: { $0.ratingKey == ratingKey }) else { return false }
        let bytes = fileSize(at: record.localURL) ?? record.bytes
        guard bytes > 0 else { return false }

        AppDiagnostics.record(.downloads, "downloads.range_finalize_recovered", fields: [
            "download_id": .identifier(ratingKey),
            "bytes": .bytes(bytes),
            "validation": .label(validationLabel),
        ])
        beginPendingBackgroundCompletionOperation()
        publishTransferFinalizing(ratingKey: ratingKey, bytes: bytes)
        let destination = record.localURL
        Task { [self] in
            defer { endPendingBackgroundCompletionOperation() }
            await finalizeTransferredFile(ratingKey: ratingKey,
                                          destination: destination,
                                          bytes: bytes,
                                          validationLabel: validationLabel)
        }
        return true
    }

    /// The durable partial now holds the whole file: validate it through the SAME finalize pipeline as
    /// the opaque lane (HEVC `hvc1` fixup, #98 retrying probe, truncation guard, complete/unverified).
    private func finalizeRangeWhole(entry: RangeTransfer) {
        beginPendingBackgroundCompletionOperation()
        let bytes = fileSize(at: entry.destination) ?? entry.totalBytes
        publishTransferFinalizing(ratingKey: entry.ratingKey, bytes: bytes)
        let destination = entry.destination
        let ratingKey = entry.ratingKey
        Task { [self] in
            defer { endPendingBackgroundCompletionOperation() }
            await finalizeTransferredFile(ratingKey: ratingKey,
                                          destination: destination,
                                          bytes: bytes,
                                          validationLabel: "range_checkpoint")
        }
    }

    /// Shared handoff from byte transfer to local finalization for both URLSession pipelines.
    ///
    /// Keep the persisted progress at exact 100% so the bar reflects that the network/file transfer
    /// finished, then let the UI derive the explicit "Verifying download…" display state from
    /// `.downloading + progress == 1.0` until `finalizeTransferredFile` writes the terminal status.
    private func publishTransferFinalizing(ratingKey: String, bytes: Int) {
        store.updateProgress(ratingKey: ratingKey, bytes: bytes, progress: 1.0)
        onChange?()
    }

    private func failRangeMove(entry: RangeTransfer, error: Error) {
        let durableBytes = store.resetStaticRangeProgressToDurableCheckpoint(
            ratingKey: entry.ratingKey,
            expectedBytes: entry.expectedBytes
        )
        AppDiagnostics.record(.downloads, "downloads.move_failed", fields: [
            "download_id": .identifier(entry.ratingKey),
            "error": .error(error),
            "bytes": .bytes(durableBytes),
        ])
        store.setStatus(ratingKey: entry.ratingKey, .failed)
        onError?(entry.ratingKey, .transferFailed(
            DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer")))
        onChange?()
    }

    /// Append `source` onto the end of `destination` in bounded blocks (never loading a whole chunk
    /// into memory). Returns the number of bytes appended.
    private func appendFile(at source: URL, onto destination: URL) throws -> Int {
        // Append-only: the durable partial is created at `start` and must already exist. If it is
        // gone, a concurrent cancel/pause deleted it out from under us (the bounded HIGH 2 race) —
        // refuse rather than re-create an orphan partial with no index row. The caller surfaces this
        // as a move failure; the halt gate then stops the chain.
        guard fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
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
    /// `downloadTask` and the chunked byte-range `downloadTask`). Runs the `hev1`→`hvc1` HEVC tag
    /// fixup, the GH #98 retrying playability probe, the duration truncation guard, and records the
    /// unified `.complete` / `.failed` (truncated) / `.unverified` (probe miss) outcome. GH #135:
    /// the range pipeline historically re-implemented a thinner, drifted version of this (no fixup,
    /// no truncation guard, probe miss → `.failed`); funnel both here so the decisions can't diverge.
    private func finalizeTransferredFile(ratingKey: String,
                                         destination: URL,
                                         bytes: Int,
                                         validationLabel: String) async {
        let shouldFinalize = finalizationStateQueue.sync { () -> Bool in
            guard !finalizingRatingKeys.contains(ratingKey) else { return false }
            finalizingRatingKeys.insert(ratingKey)
            return true
        }
        guard shouldFinalize else {
            AppDiagnostics.record(.downloads, "downloads.finalize_duplicate_ignored", fields: [
                "download_id": .identifier(ratingKey),
                "bytes": .bytes(bytes),
                "validation": .label(validationLabel),
            ])
            return
        }
        defer {
            finalizationStateQueue.sync {
                _ = finalizingRatingKeys.remove(ratingKey)
            }
        }

        let finalizeStarted = Date()
        AppDiagnostics.record(.downloads, "downloads.finalize_start", fields: [
            "download_id": .identifier(ratingKey),
            "bytes": .bytes(bytes),
            "validation": .label(validationLabel),
        ])

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

        // GH #98: the post-download playability probe is an INTERMITTENT false-negative — on a device
        // busy right after a heavy transcode+download, AVFoundation can transiently fail to
        // open/advance a COMPLETE file that a later attempt on the same bytes plays fine. Retry with
        // progressively longer timeouts before deciding.
        await Self.playbackValidationLimiter.wait()
        defer { Task { await Self.playbackValidationLimiter.signal() } }
        var validation = await Self.validateLocalPlayback(destination)
        if !validation.played {
            // #187: keep headset-idle finalization bounded. Multiple long AVPlayer probes in
            // parallel are a plausible source of the observed idle gray/freeze/crash while MB-sized
            // files sit at "Verifying download…". Serialize probes and give one longer retry before
            // preserving the file as `.unverified` for later playback instead of repeatedly burning
            // foreground resources.
            for extraTimeout in [15.0] {
                downloadLog.notice("playback-probe retry ratingKey=\(ratingKey, privacy: .public) reason=\(validation.reason, privacy: .public) nextTimeout=\(extraTimeout, privacy: .public)")
                try? await Task.sleep(for: .seconds(2))
                validation = await Self.validateLocalPlayback(destination, timeoutSecondsOverride: extraTimeout)
                if validation.played { break }
            }
        }

        // Truncation guard (only meaningful when both durations are known): a transcode that aborts
        // early — or a static download the server cut short while still returning 2xx — can play its
        // first fraction of a second and pass the probe. A decoded duration far under the source's is
        // truncated, not complete. Legitimate short clips compare against their own short duration.
        let expectedDurationMs = store.records.first { $0.ratingKey == ratingKey }?.metadata?.duration
        let outcome = DownloadCompletionValidation.outcome(played: validation.played,
                                                           probeReason: validation.reason,
                                                           expectedDurationMs: expectedDurationMs,
                                                           actualDurationMs: validation.durationMs)
        let finalizationDurationMs = max(0, Int(Date().timeIntervalSince(finalizeStarted) * 1000))
        switch outcome {
        case .truncated(let actualDurationMs, let expectedMs):
            downloadLog.error("truncated-download ratingKey=\(ratingKey, privacy: .public) expectedMs=\(expectedMs, privacy: .public) actualMs=\(actualDurationMs, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.validation_failed", fields: [
                "download_id": .identifier(ratingKey),
                "reason": .label("truncated_duration"),
                "expected_duration_ms": .int(expectedMs),
                "actual_duration_ms": .int(actualDurationMs),
            ])
            try? fileManager.removeItem(at: destination)
            clearRetryCount(ratingKey: ratingKey)
            store.setStatus(ratingKey: ratingKey, .failed)
            onError?(ratingKey, .invalidDownload("Downloaded file is truncated (\(actualDurationMs / 1000)s of \(expectedMs / 1000)s)."))
            recordFinalizeFinished(ratingKey: ratingKey,
                                   result: "failed_truncated",
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
            clearRetryCount(ratingKey: ratingKey)
            store.updateProgress(ratingKey: ratingKey, bytes: bytes, progress: 1)
            store.setStatus(ratingKey: ratingKey, .complete)
            recordFinalizeFinished(ratingKey: ratingKey,
                                   result: "complete",
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
            clearRetryCount(ratingKey: ratingKey)
            store.setStatus(ratingKey: ratingKey, .unverified)
            recordFinalizeFinished(ratingKey: ratingKey,
                                   result: "unverified_\(reason)",
                                   validationLabel: validationLabel,
                                   durationMs: finalizationDurationMs,
                                   bytes: bytes)
        }
        onChange?()
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
    private static func validateLocalPlayback(_ url: URL, timeoutSecondsOverride: Double? = nil)
        async -> (played: Bool, reason: String, durationMs: Int?, detail: String?) {
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

        // Avoid unbounded async asset-key loads here. This method already runs under the serialized
        // finalization limiter, so a hung `asset.load(.isPlayable/.duration)` can block every later
        // completed download in "Verifying download…" and was one of the remaining #187 overnight
        // gray-freeze suspects. Let AVPlayerItem readiness/failure drive the same bounded loop instead.
        var durationMs: Int?
        let timeoutSeconds = timeoutSecondsOverride ?? OfflinePlaybackValidationPolicy.make(durationMs: nil).timeoutSeconds
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeoutSeconds * 1000)))
        var sawReady = false
        while ContinuousClock.now < deadline {
            switch item.status {
            case .failed:
                return (false, "item_failed", durationMs,
                        item.error.map { DiagnosticRedactor.safeErrorSummary($0) })
            case .readyToPlay:
                sawReady = true
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
            try? await Task.sleep(for: .milliseconds(policy.pollIntervalMilliseconds))
        }
        return (false, sawReady ? "no_playback_progress" : "timeout_not_ready", durationMs, nil)
    }

    private static func durationMilliseconds(from time: CMTime) -> Int? {
        guard time.seconds.isFinite, time.seconds > 0 else { return nil }
        return Int(time.seconds * 1000)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // #169: opaque and range tasks now share ONE session, so the task id uniquely identifies its
        // lane (no independent id spaces). A range chunk's SUCCESS path is fully handled in
        // `finishRangeChunk` (which removes the entry), so a range entry still present here means the
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
            guard let error else { return } // success already handled in finishRangeChunk
            clearGracefulRangePause(ratingKey: rangeEntry.ratingKey)
            endRangeBackgroundHandoffGrace(taskIdentifier: task.taskIdentifier,
                                           ratingKey: rangeEntry.ratingKey,
                                           reason: "error")
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                downloadLog.info("range-cancelled ratingKey=\(rangeEntry.ratingKey, privacy: .public) bytes=\(rangeEntry.totalBytes, privacy: .public)")
                AppDiagnostics.record(.downloads, "downloads.range_cancelled", fields: [
                    "download_id": .identifier(rangeEntry.ratingKey),
                    "segment_kind": .label(rangeEntry.segmentKind.rawValue),
                    "bytes": .bytes(rangeEntry.totalBytes),
                ])
                return
            }
            if retryTransientRangeFailure(nsError, task: task, entry: rangeEntry) {
                return
            }
            // A non-transient interruption (commonly a long headset-off that outlived the OS's own
            // retry, or connectivity loss) leaves the durable partial's COMPLETED chunks intact — the
            // failed chunk's bytes were in the OS temp, never appended — so surface a resumable pause
            // rather than a failure. The partial IS the checkpoint; Resume re-requests only the
            // in-flight chunk from its current size.
            let summary = DiagnosticRedactor.safeErrorSummary(error)
            let durableBytes = store.resetStaticRangeProgressToDurableCheckpoint(
                ratingKey: rangeEntry.ratingKey,
                expectedBytes: rangeEntry.expectedBytes
            )
            downloadLog.error("range-paused ratingKey=\(rangeEntry.ratingKey, privacy: .public) error=\(summary, privacy: .public) bytes=\(durableBytes, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.range_paused", fields: [
                "download_id": .identifier(rangeEntry.ratingKey),
                "segment_kind": .label(rangeEntry.segmentKind.rawValue),
                "error": .error(error),
                "base_offset": .int(rangeEntry.baseOffset),
                "optimistic_temp_bytes": .bytes(rangeEntry.chunkBytesWritten),
                "bytes": .bytes(durableBytes),
            ])
            if rangeEntry.request == nil {
                // Adopted failed chunks were active system work, not user pauses. Persist queued
                // intent before the callback so backend restore can be missed/terminated safely.
                store.setStatus(ratingKey: rangeEntry.ratingKey, .queued)
                onRangeRequestNeeded?(rangeEntry.ratingKey, .adoptedChunkFailed)
                return
            }
            store.setStatus(ratingKey: rangeEntry.ratingKey, .paused)
            onError?(rangeEntry.ratingKey, .interruptedResumable)
            onChange?()
            return
        }

        guard let entry, let error else { return }
        let nsError = error as NSError
        // A cancel is not a failure. Any other error keeps a `.failed` row (D3) with a
        // surfaced reason, rather than silently erasing it so the UI can offer retry.
        if nsError.code != NSURLErrorCancelled {
            if retryTransientFailure(nsError, task: task, entry: entry) {
                return
            }
            // #95: a recoverable interruption (commonly a long headset-off, which can produce an
            // error OUTSIDE the narrow transient set yet still hand back resume data) should be
            // treated as PAUSED-and-resumable, not failed. Branch on the PRESENCE of resume data
            // rather than the error code, persist the blob so a manual Resume — even after a
            // relaunch — continues from the offset, and surface a non-red "will resume" state.
            // The partial bytes are retained (reconcile keeps a `.paused` row's file).
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               !resumeData.isEmpty {
                guard store.supportsPersistedResumeData(ratingKey: entry.ratingKey) else {
                    let summary = DiagnosticRedactor.safeErrorSummary(error)
                    downloadLog.error("transfer-nonresumable ratingKey=\(entry.ratingKey, privacy: .public) error=\(summary, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public) resumeData=true")
                    AppDiagnostics.record(.downloads, "downloads.transfer_nonresumable", fields: [
                        "download_id": .identifier(entry.ratingKey),
                        "error": .error(error),
                        "bytes_received": .bytes(Int(task.countOfBytesReceived)),
                        "resume_data_present": .bool(true),
                    ])
                    clearRetryCount(ratingKey: entry.ratingKey)
                    store.setStatus(ratingKey: entry.ratingKey, .failed)
                    onError?(entry.ratingKey, .transferFailed("Download interrupted; this transcoded stream can’t resume from its byte offset. Retry will restart from the beginning."))
                    onChange?()
                    return
                }
                let summary = DiagnosticRedactor.safeErrorSummary(error)
                downloadLog.error("transfer-paused ratingKey=\(entry.ratingKey, privacy: .public) error=\(summary, privacy: .public) bytesReceived=\(task.countOfBytesReceived, privacy: .public)")
                AppDiagnostics.record(.downloads, "downloads.transfer_paused", fields: [
                    "download_id": .identifier(entry.ratingKey),
                    "error": .error(error),
                    "bytes_received": .bytes(Int(task.countOfBytesReceived)),
                ])
                store.setResumeData(ratingKey: entry.ratingKey, resumeData)
                clearRetryCount(ratingKey: entry.ratingKey)
                store.setStatus(ratingKey: entry.ratingKey, .paused)
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
            clearRetryCount(ratingKey: entry.ratingKey)
            store.setStatus(ratingKey: entry.ratingKey, .failed)
            onError?(entry.ratingKey, .transferFailed(
                DiagnosticRedactor.safeUserFacingErrorMessage(error, operation: "Transfer")))
        } else {
            clearRetryCount(ratingKey: entry.ratingKey)
            downloadLog.info("cancelled ratingKey=\(entry.ratingKey, privacy: .public)")
            AppDiagnostics.record(.downloads, "downloads.cancelled", fields: [
                "download_id": .identifier(entry.ratingKey),
            ])
        }
        onChange?()
    }

    private func recordRangeProgressIfNeeded(taskIdentifier: Int,
                                             entry: RangeTransfer,
                                             chunkBytes: Int,
                                             totalBytes: Int,
                                             expectedBytes: Int?,
                                             progress: Double,
                                             firstCallback: Bool) {
        let now = Date()
        var shouldRecord = firstCallback
        lock.lock()
        if let last = lastRangeProgressDiagnostic[taskIdentifier] {
            let elapsed = now.timeIntervalSince(last.time)
            let byteDelta = totalBytes - last.bytes
            shouldRecord = shouldRecord || elapsed >= 10 || byteDelta >= Self.rangeChunkSize
        } else {
            shouldRecord = true
        }
        if shouldRecord {
            lastRangeProgressDiagnostic[taskIdentifier] = (now, totalBytes)
        }
        lock.unlock()

        if firstCallback || chunkBytes > 0 {
            endRangeBackgroundHandoffGrace(taskIdentifier: taskIdentifier,
                                           ratingKey: entry.ratingKey,
                                           reason: "first_progress")
        }

        guard shouldRecord else { return }
        AppDiagnostics.record(.downloads, "downloads.range_progress", fields: [
            "download_id": .identifier(entry.ratingKey),
            "task_id": .int(taskIdentifier),
            "segment_kind": .label(entry.segmentKind.rawValue),
            "base_offset": .int(entry.baseOffset),
            "chunk_bytes": .int(chunkBytes),
            "total_bytes": .int(totalBytes),
            "expected_exact": .int(expectedBytes ?? -1),
            "progress_percent": .int(Int((progress * 100).rounded(.down))),
        ])
    }

    private func notifyProgressChangeIfNeeded(ratingKey _: String, progress: Double) {
        let now = Date()
        lock.lock()
        let last = lastProgressNotify
        let shouldNotify = (last.map { now.timeIntervalSince($0) >= progressNotifyInterval } ?? true)
            || progress >= 1.0
        if shouldNotify { lastProgressNotify = now }
        lock.unlock()
        if shouldNotify { onChange?() }
    }

    private func clearRetryCount(ratingKey: String) {
        lock.lock()
        retryCounts.removeValue(forKey: ratingKey)
        lastProgressNotify = nil
        lock.unlock()
    }

    /// Resume transient transfer drops before surfacing a failed row. Plex/static-file
    /// downloads can start successfully and then lose the TCP stream mid-body (`-1005`);
    /// URLSession gives us resume data in that case, so failing immediately throws away
    /// exactly the recovery mechanism the OS provides.
    private func retryTransientFailure(_ error: NSError,
                                       task: URLSessionTask,
                                       entry: (ratingKey: String, destination: URL)) -> Bool {
        guard error.domain == NSURLErrorDomain,
              Self.transientDownloadErrorCodes.contains(error.code),
              let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
              !resumeData.isEmpty else { return false }
        // #95: JF/Emby optimized downloads are live transcode streams; do not offset-resume them
        // even if URLSession hands back a blob. Let the caller surface a restart-required failure
        // instead of silently trying a 200-full-restart/416-prone resume.
        guard store.supportsPersistedResumeData(ratingKey: entry.ratingKey) else { return false }

        lock.lock()
        let nextAttempt = (retryCounts[entry.ratingKey] ?? 0) + 1
        guard nextAttempt <= maxTransientRetries else {
            lock.unlock()
            return false
        }
        retryCounts[entry.ratingKey] = nextAttempt
        lock.unlock()

        let retryTask = urlSession.downloadTask(withResumeData: resumeData)
        retryTask.taskDescription = entry.ratingKey
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
        guard error.domain == NSURLErrorDomain,
              Self.transientDownloadErrorCodes.contains(error.code) else { return false }
        // No in-memory request (a relaunch-adopted chunk) means we can't reissue here; fall through
        // to the resumable-pause path so DownloadManager rebuilds the request and resumes.
        guard let request = entry.request else { return false }

        lock.lock()
        let nextAttempt = (retryCounts[entry.ratingKey] ?? 0) + 1
        guard nextAttempt <= maxTransientRetries else {
            lock.unlock()
            return false
        }
        retryCounts[entry.ratingKey] = nextAttempt
        lock.unlock()

        let durableBytes = store.resetStaticRangeProgressToDurableCheckpoint(
            ratingKey: entry.ratingKey,
            expectedBytes: entry.expectedBytes
        )
        downloadLog.error("range-retry ratingKey=\(entry.ratingKey, privacy: .public) attempt=\(nextAttempt, privacy: .public) code=\(error.code, privacy: .public) bytes=\(durableBytes, privacy: .public)")
        AppDiagnostics.record(.downloads, "downloads.range_retry", fields: [
            "download_id": .identifier(entry.ratingKey),
            "segment_kind": .label(entry.segmentKind.rawValue),
            "attempt": .int(nextAttempt),
            "error": .error(error),
            "bytes": .bytes(durableBytes),
        ])

        do {
            let holdBackgroundCompletion = hasPendingBackgroundCompletionHandler()
            try startRangeChunk(ratingKey: entry.ratingKey,
                                with: request,
                                to: entry.destination,
                                expectedBytes: entry.expectedBytes,
                                resetsRetryCount: false,
                                holdBackgroundCompletionForFirstProgress: holdBackgroundCompletion)
            onChange?()
            return true
        } catch {
            if shouldSuppressRangeStartFailure(ratingKey: entry.ratingKey,
                                               error: error,
                                               context: "transient_retry") {
                onChange?()
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

    private static let transientDownloadErrorCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed
    ]

    /// Called when the background session has delivered all events queued while the
    /// app was suspended/terminated (after a relaunch). We invoke the system-supplied
    /// completion handler the app delegate stashed, so the OS knows our UI is current
    /// and snapshots a fresh app preview. Must run on the main queue.
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        lock.lock()
        let rangeEntry = rangeInflight[task.taskIdentifier]
        let entry = rangeEntry == nil ? inflight[task.taskIdentifier] : nil
        lock.unlock()
        AppDiagnostics.record(.downloads, "downloads.task_waiting_for_connectivity", fields: [
            "download_id": .identifier(rangeEntry?.ratingKey ?? entry?.ratingKey),
            "task_id": .int(task.taskIdentifier),
            "task_type": .label(rangeEntry == nil ? "downloadTask" : "rangeDownloadTask"),
            "segment_kind": .label(rangeEntry?.segmentKind.rawValue ?? "n/a"),
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
/// Test-only URLProtocol used by the download probe to simulate a real mid-body network loss
/// without mutating host networking. It proxies the original request with a URLSession whose
/// protocol list excludes this class, streams bytes through to the client, then fails once with
/// `NSURLErrorNetworkConnectionLost` after the configured threshold.
private final class DebugRangeDropURLProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private static let handledKey = "VisionPlayDebugRangeDropHandled"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuredDropAfterBytes: Int = 0
    nonisolated(unsafe) private static var didDrop = false

    private var upstreamTask: URLSessionDataTask?
    private var session: URLSession?
    private var delivered = 0

    static func configure(dropAfterBytes: Int) {
        lock.lock()
        configuredDropAfterBytes = dropAfterBytes
        didDrop = false
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil,
              request.url?.scheme == "http" || request.url?.scheme == "https" else { return false }
        lock.lock()
        let enabled = configuredDropAfterBytes > 0 && !didDrop
        lock.unlock()
        return enabled
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        Self.lock.lock()
        let threshold = Self.configuredDropAfterBytes
        let shouldDropAlready = Self.didDrop
        Self.lock.unlock()

        guard threshold > 0, !shouldDropAlready else {
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
        let alreadyDropped = Self.didDrop
        if !alreadyDropped { Self.didDrop = true }
        Self.lock.unlock()
        guard !alreadyDropped else { return }
        dataTask.cancel()
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: nil)
        client?.urlProtocol(self, didFailWithError: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
#endif
