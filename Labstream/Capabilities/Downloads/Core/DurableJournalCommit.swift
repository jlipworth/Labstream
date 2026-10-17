import Foundation

/// Commit rule shared by the standalone cleanup journals (B18).
///
/// A journal write is durable only when the full committer sequence succeeds: temp write, full
/// fsync, rename, then directory fsync. A failure after the rename leaves the new bytes visible
/// but not necessarily durable, so visibility is never accepted as proof. The same bytes are
/// recommitted once; if that also fails the caller reports a commit failure and retries later.
enum DurableJournalCommit {
    static func liveCommit(_ data: Data, _ url: URL) throws {
        try DownloadIndexFileCommitter().commit(data, to: url)
    }

    static func liveSyncDirectory(_ url: URL) throws {
        try DownloadIndexFileCommitter().syncContainingDirectory(of: url)
    }

    /// Returns `nil` once `data` is durably committed at `url`, otherwise the final error.
    static func commit(
        _ data: Data,
        to url: URL,
        using commit: (Data, URL) throws -> Void
    ) -> (any Error)? {
        do {
            try commit(data, url)
            return nil
        } catch let failure as DownloadIndexFileCommitter.CommitFailure
                    where !failure.replacementMayHaveOccurred {
            return failure
        } catch {
            do {
                try commit(data, url)
                return nil
            } catch {
                return error
            }
        }
    }
}
