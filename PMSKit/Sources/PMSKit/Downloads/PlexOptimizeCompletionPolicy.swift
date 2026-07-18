import Foundation

/// Terminal-state interpretation for Plex's type-42 background-processing queue.
///
/// Plex can report an optimize item complete before the new `Media`/`Part` is visible from the
/// library metadata endpoint. That indexing gap is normal, but a completed queue item must not be
/// treated exactly like an indefinitely-running transcode. Give metadata a bounded grace period,
/// then surface a retryable failure if the rendered part still cannot be identified.
public enum PlexOptimizeCompletionPolicy {
    public static let metadataIndexingGraceSeconds: TimeInterval = 120

    public enum Outcome: Equatable, Sendable {
        case active
        case succeeded
        case failed
    }

    public enum MissingPartAction: Equatable, Sendable {
        case keepPolling
        case failMissingOutput
    }

    public static func outcome(state: String?, successfulCount: Int?, failedCount: Int?) -> Outcome {
        let normalized = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isComplete = ["complete", "completed", "successful", "success"].contains(normalized)
        guard isComplete else { return .active }
        if (failedCount ?? 0) > 0 && (successfulCount ?? 0) == 0 { return .failed }
        return .succeeded
    }

    public static func missingPartAction(outcome: Outcome,
                                         firstSuccessObservedAt: TimeInterval?,
                                         now: TimeInterval) -> MissingPartAction {
        guard outcome == .succeeded, let firstSuccessObservedAt else { return .keepPolling }
        let elapsed = max(0, now - firstSuccessObservedAt)
        return elapsed >= metadataIndexingGraceSeconds ? .failMissingOutput : .keepPolling
    }
}
