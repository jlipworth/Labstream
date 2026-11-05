#if !os(tvOS)
import Foundation
import PMSKit

/// A playback generation is independent of attempt identity: reopening the same attempt revokes
/// older observers AND queued/terminal samples, so a delayed old close cannot overwrite a reopen.
struct OfflinePlaybackSessionGeneration: Hashable, Sendable {
    let rawValue: UUID
}

/// Captured position facts, never a resume/seek-derived proof of actual playback.
struct OfflinePlaybackProgressSample: Equatable, Sendable {
    let positionMs: Int
    let durationMs: Int?
}

/// One launch owns one sink and its exact attempt forever; delayed events never look up a new
/// attempt by rating key. All submission/resolution uses P6's bounded exact-key async contract.
/// Keep at most one resolving position commit and one latest pending sample; duplicate samples
/// coalesce. Persistence timeout/failure is explicit failure, never an acknowledged save.
@MainActor
protocol OfflinePlaybackEventSink: AnyObject {
    var attemptKey: DownloadAttemptKey { get }
    var sessionGeneration: OfflinePlaybackSessionGeneration { get }

    /// Position alone cannot promote an unverified download, even when positive at startup.
    func progress(positionMs: Int, durationMs: Int?)
    /// Only current-item, current-session actual playing may verify eligible probe-miss rows.
    /// A persisted `truncatedRepeated` warning is never erased by playback.
    func playbackObserved()
    /// Revoke observer events immediately, but retain this captured terminal sample until its
    /// exact submission resolves or explicit failure is recorded. A newer session supersedes it.
    func close(finalSample: OfflinePlaybackProgressSample)
}
#endif

#if !os(tvOS)
/// One worker drains a bounded mailbox. Submissions are synchronous in-memory mutations only;
/// their durability is resolved asynchronously through the P6 typed contract.
@MainActor
final class BoundOfflinePlaybackEventSink: OfflinePlaybackEventSink {
    let attemptKey: DownloadAttemptKey
    let sessionGeneration = OfflinePlaybackSessionGeneration(rawValue: UUID())
    private let store: DownloadStore
    private let didResolve: () -> Void
    private let admitsMutation: () -> Bool
    private var accepting = true
    private var superseded = false
    private var observedPending = false
    private var didObserve = false
    private var pending: OfflinePlaybackProgressSample?
    private var lastSubmitted: OfflinePlaybackProgressSample?
    private(set) var lastPersistenceFailure: DownloadStore.PersistenceFlushResult?
    private(set) var lastPersistenceResult: DownloadStore.AttemptMutationResult?
    private(set) var worker: Task<Void, Never>?

    init(attemptKey: DownloadAttemptKey, store: DownloadStore,
         admitsMutation: @escaping () -> Bool, didResolve: @escaping () -> Void) {
        self.attemptKey = attemptKey
        self.store = store
        self.didResolve = didResolve
        self.admitsMutation = admitsMutation
    }

    func progress(positionMs: Int, durationMs: Int?) {
        guard accepting, !superseded else { return }
        enqueue(.init(positionMs: positionMs, durationMs: durationMs))
    }

    func playbackObserved() {
        guard accepting, !superseded, !didObserve else { return }
        didObserve = true
        observedPending = true
        startWorker()
    }

    func close(finalSample: OfflinePlaybackProgressSample) {
        guard accepting, !superseded else { return }
        accepting = false
        enqueue(finalSample)
    }

    func supersede() {
        accepting = false
        superseded = true
        pending = nil
        observedPending = false
    }

    private func enqueue(_ sample: OfflinePlaybackProgressSample) {
        pending = sample == lastSubmitted ? nil : sample
        startWorker()
    }

    private func resolved(_ result: DownloadStore.AttemptMutationResult) {
        lastPersistenceResult = result
        switch result {
        case .applied, .noChange:
            if !superseded { didResolve() }
        case .persistenceFailed(let failure):
            lastPersistenceFailure = failure
            AppDiagnostics.record(.downloads, "downloads.offline_playback_persistence_failed")
        case .staleOrMissing: break
        }
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor in
            while !superseded {
                guard admitsMutation(), store.ownsAttempt(attemptKey) else {
                    pending = nil
                    observedPending = false
                    lastPersistenceResult = .staleOrMissing
                    break
                }
                if observedPending {
                    observedPending = false
                    if case .accepted(_, let ticket) = store.submitLifecycleEvent(.localPlaybackProgressed, for: attemptKey) {
                        resolved(await store.resolve(
                            .accepted(change: .applied, ticket: ticket), deadline: .after(30)))
                    }
                } else if let sample = pending {
                    pending = nil
                    lastSubmitted = sample
                    let submission = store.submitMetadata(for: attemptKey) { metadata in
                        metadata.localPlaybackPositionMs = OfflinePlaybackPositionPolicy.standard.persistedPositionMs(
                            currentMs: sample.positionMs, durationMs: sample.durationMs ?? metadata.duration)
                    }
                    resolved(await store.resolve(submission, deadline: .after(30)))
                } else { break }
            }
            worker = nil
        }
    }
}
#endif
