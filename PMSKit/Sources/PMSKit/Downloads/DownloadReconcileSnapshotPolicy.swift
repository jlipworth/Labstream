import Foundation

/// What reconcile knew about one row when its caller took the snapshot it reconciles.
public struct DownloadReconcileRowObservation: Sendable, Equatable {
    public let attemptID: DownloadAttemptID?
    /// The store's per-row mutation generation: it advances on every write to the row.
    public let mutationGeneration: UInt64

    public init(attemptID: DownloadAttemptID?, mutationGeneration: UInt64) {
        self.attemptID = attemptID
        self.mutationGeneration = mutationGeneration
    }
}

/// Which rows a reconcile pass may judge (the review of Admission-A1, #475).
///
/// Reconcile runs after an asynchronous task listing. Its caller decides which rows it covers
/// before that listing, and reconcile reads each row's state after it. At launch nothing
/// changes a row in between: admission is closed until reconcile has finished. In the
/// foreground admission is open. The caller leaves out forward-only rows a granted start may
/// own, but that exclusion is as old as the snapshot: a paused row the user resumes during the
/// listing is granted and becomes `admitted` before its task exists, and reconcile then read
/// that newer row and requeued it under its supervised start.
///
/// So a foreground snapshot carries each row's attempt and mutation generation, and reconcile
/// judges a row only while both still match. A row that changed since the snapshot was changed
/// by someone who knows more than the snapshot does (a start, a pause, a callback), and the
/// next pass sees it. The check uses the generation, not the lifecycle, so a row that left a
/// state and came back to it is skipped as well.
public enum DownloadReconcileSnapshotPolicy {
    /// `observations` is nil for launch reconcile, which judges every row of its snapshot.
    /// Otherwise a row is judged only if it was observed and is unchanged since.
    public static func judgesRow(ratingKey: String,
                                 observations: [String: DownloadReconcileRowObservation]?,
                                 current: DownloadReconcileRowObservation) -> Bool {
        guard let observations else { return true }
        return observations[ratingKey] == current
    }
}
