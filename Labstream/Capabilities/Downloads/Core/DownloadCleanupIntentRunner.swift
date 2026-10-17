import Foundation
import PMSKit

/// The single executor of journaled server cleanup (downloads overhaul P2.6).
///
/// Producers only journal intents and `kick` the runner; nothing else calls a server cleanup
/// endpoint for journaled work. Each pass loads the journal off the main actor, classifies legacy
/// entries once, applies `CleanupIntentEligibilityPolicy`, and executes eligible intents with at
/// most two in flight and one run per intent at a time. Unsuccessful runs back off per intent, and
/// the runner schedules its own wake-up for the earliest deadline, so progress never depends on
/// row refreshes or a backend that has no active downloads.
@MainActor
final class DownloadCleanupIntentRunner {
    enum ExecutionOutcome: Sendable, Equatable {
        /// The server work is gone (or provably nothing to do) and the journal entry was removed.
        case retired
        /// Not runnable now for a reason that a later trigger resolves (another row claims the
        /// resource, or its row is still settling). No backoff.
        case waiting
        /// Transport, session, or persistence uncertainty: retry with backoff.
        case failed
        /// A Plex response that cannot act yet; retry no sooner than the delay.
        case retained(minimumDelaySeconds: Double)
    }

    struct Dependencies {
        var load: @Sendable () -> DownloadCleanupIntentJournal.LoadResult
        /// Durably replace the entry with the same id (legacy provenance classification).
        var replace: @Sendable (DurableDownloadCleanupIntent) -> Bool
        var rowState: @MainActor (DurableDownloadCleanupIntent)
            -> CleanupIntentEligibilityPolicy.RowState
        /// Migration receipts: legacy tombstones and quarantine imports not yet retired.
        var isBlocked: @MainActor (DurableDownloadCleanupIntent) -> Bool
        var hasMatchingSession: @MainActor (DurableDownloadCleanupIntent) -> Bool
        var execute: @MainActor (DurableDownloadCleanupIntent) async -> ExecutionOutcome
        var now: @Sendable () -> Date = { Date() }
        var backoffSeconds: @Sendable (Int) -> Double = CleanupIntentRetryPolicy.backoffSeconds(afterFailures:)
        var diagnostic: @MainActor (String, [String: DiagnosticFieldValue]) -> Void = { _, _ in }
    }

    static let maxConcurrentRuns = 2 // Matches the two workers in `pass()`.
    /// Retry interval after the journal itself could not be read.
    static let loadFailureRetrySeconds: Double = 30
    /// Local-only re-examination of intents that are waiting on row state, ownership, or a
    /// migration receipt. Nothing is ever left without a wake-up, even if its trigger is lost.
    static let waitingRecheckSeconds: Double = 120

    private let dependencies: Dependencies
    private var isEnabled = false
    private var isRunning = false
    private var rerunRequested = false
    private var inFlight: Set<UUID> = []
    private var failureCounts: [UUID: Int] = [:]
    private var notBefore: [UUID: Date] = [:]
    private var loadRetryAt: Date?
    private var waitingRecheckAt: Date?
    private var pending: [DurableDownloadCleanupIntent] = []
    private var wakeTask: Task<Void, Never>?
    private var passCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Opens the runner once launch migration barriers have completed.
    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        kick(reason: "enabled")
    }

    /// Coalesced trigger: a kick during a pass schedules exactly one more pass.
    func kick(reason: String) {
        guard isEnabled else { return }
        if isRunning {
            rerunRequested = true
            return
        }
        isRunning = true
        Task { await self.runPasses() }
    }

    /// A session or auth change can make a backed-off intent runnable immediately.
    func resetBackoff(reason: String) {
        failureCounts.removeAll()
        notBefore.removeAll()
        loadRetryAt = nil
        kick(reason: reason)
    }

    /// Test seam: resolves after the current (or next) pass sequence finishes.
    func waitUntilIdle() async {
        guard isRunning else { return }
        await withCheckedContinuation { passCompletionWaiters.append($0) }
    }

    var nextWakeForTesting: Date? { earliestDeadline() }

    // MARK: - Passes

    private func runPasses() async {
        repeat {
            rerunRequested = false
            await pass()
        } while rerunRequested
        isRunning = false
        scheduleWake()
        let waiters = passCompletionWaiters
        passCompletionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func pass() async {
        let load = dependencies.load
        let result = await Task.detached { load() }.value
        let now = dependencies.now()
        guard case .loaded(let intents) = result else {
            loadRetryAt = now.addingTimeInterval(Self.loadFailureRetrySeconds)
            dependencies.diagnostic("downloads.cleanup_runner_load_failed", [:])
            return
        }
        loadRetryAt = nil
        var hasWaiting = false
        let liveIDs = Set(intents.map(\.id))
        failureCounts = failureCounts.filter { liveIDs.contains($0.key) }
        notBefore = notBefore.filter { liveIDs.contains($0.key) }

        var runnable: [DurableDownloadCleanupIntent] = []
        for candidate in intents {
            guard !inFlight.contains(candidate.id) else { continue }
            guard !dependencies.isBlocked(candidate) else {
                hasWaiting = true
                continue
            }
            if let due = notBefore[candidate.id], due > now { continue }
            var intent = candidate
            let rowState = dependencies.rowState(intent)
            if intent.provenance == nil {
                guard let classified = CleanupIntentEligibilityPolicy.legacyProvenance(for: rowState),
                      let updated = intent.with(provenance: classified) else {
                    hasWaiting = true
                    continue
                }
                let replace = dependencies.replace
                guard await Task.detached(operation: { replace(updated) }).value else {
                    recordFailure(intent.id, now: now)
                    continue
                }
                intent = updated
            }
            guard CleanupIntentEligibilityPolicy.decision(
                provenance: intent.provenance, rowState: rowState) == .run else {
                hasWaiting = true
                continue
            }
            guard dependencies.hasMatchingSession(intent) else {
                // No live credential for the persisted server/user: keep it and retry later.
                recordFailure(intent.id, now: now)
                continue
            }
            runnable.append(intent)
        }
        waitingRecheckAt = hasWaiting
            ? now.addingTimeInterval(Self.waitingRecheckSeconds) : nil
        guard !runnable.isEmpty else { return }

        pending = runnable
        // `maxConcurrentRuns` workers share one queue; an idle worker returns immediately.
        async let first: Void = drainPending()
        async let second: Void = drainPending()
        _ = await (first, second)
    }

    private func drainPending() async {
        while !pending.isEmpty {
            let intent = pending.removeFirst()
            guard inFlight.insert(intent.id).inserted else { continue }
            let outcome = await dependencies.execute(intent)
            inFlight.remove(intent.id)
            let now = dependencies.now()
            switch outcome {
            case .retired:
                failureCounts.removeValue(forKey: intent.id)
                notBefore.removeValue(forKey: intent.id)
            case .waiting:
                failureCounts.removeValue(forKey: intent.id)
                notBefore[intent.id] = now.addingTimeInterval(Self.waitingRecheckSeconds)
            case .failed:
                recordFailure(intent.id, now: now)
            case .retained(let minimumDelay):
                recordFailure(intent.id, now: now, minimumDelaySeconds: minimumDelay)
            }
        }
    }

    private func recordFailure(_ id: UUID, now: Date, minimumDelaySeconds: Double = 0) {
        let failures = (failureCounts[id] ?? 0) + 1
        failureCounts[id] = failures
        let delay = max(dependencies.backoffSeconds(failures), minimumDelaySeconds)
        notBefore[id] = now.addingTimeInterval(delay)
    }

    // MARK: - Self-scheduled wake-up

    private func earliestDeadline() -> Date? {
        ([loadRetryAt, waitingRecheckAt].compactMap { $0 } + Array(notBefore.values)).min()
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        guard let deadline = earliestDeadline() else {
            wakeTask = nil
            return
        }
        let delay = max(0, deadline.timeIntervalSince(dependencies.now()))
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.kick(reason: "backoff_elapsed")
        }
    }
}
