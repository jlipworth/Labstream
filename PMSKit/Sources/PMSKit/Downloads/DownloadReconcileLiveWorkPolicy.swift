import Foundation

/// Reconcile's live-task fact for one row (RangeTrain-R2, #476).
///
/// Reattach hands reconcile the rating keys whose URLSession task it found. That set is a
/// snapshot taken on the delegate queue; reconcile uses it later on a store worker. A finished
/// body the session stashed and queued for its append (or publication) has no task any more, and
/// a task the daemon redelivers after the snapshot was never in it. So reconcile also asks the
/// session what it owns at the moment it decides, under the row's mutation generation.
public enum DownloadReconcileLiveWorkPolicy {
    /// Only an active row is asked about. A paused row with session work must stay paused:
    /// counting that work as a live task would promote it (F2, #473). A finalizing or finished
    /// row is judged by its body, and a failed or planned row is left alone by reconcile.
    public static func consultsSessionOwnedWork(lifecycle: DownloadLifecycle) -> Bool {
        lifecycle == .admitted || lifecycle == .transferring
    }

    /// `sessionOwnsWork` is evaluated only when the snapshot does not already answer, and only
    /// for a row `consultsSessionOwnedWork` admits.
    public static func hasLiveTask(inReattachSnapshot: Bool,
                                   lifecycle: DownloadLifecycle,
                                   sessionOwnsWork: () -> Bool) -> Bool {
        if inReattachSnapshot { return true }
        return consultsSessionOwnedWork(lifecycle: lifecycle) && sessionOwnsWork()
    }
}
