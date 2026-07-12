import Foundation

/// Crash-durable sibling-temp publication for resume blobs. The shared low-level committer writes
/// mode 0600, applies auth-artifact protection/backup exclusion, full-syncs file contents, renames
/// atomically, and fsyncs the containing directory before returning.
struct DownloadArtifactFileCommitter: Sendable {
    private let durableCommitter: DownloadIndexFileCommitter

    init(durableCommitter: DownloadIndexFileCommitter = .init()) {
        self.durableCommitter = durableCommitter
    }

    func commit(_ data: Data, to destination: URL) throws {
        try durableCommitter.commit(data, to: destination)
    }
}
