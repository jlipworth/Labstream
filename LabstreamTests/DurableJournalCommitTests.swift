#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

/// B18 pins: cleanup journals use the index's full commit protocol, and a visible-but-unsynced
/// value is never reported as durable authority.
@Suite("Durable cleanup journal commits", .downloadTestFiles)
struct DurableJournalCommitTests {
    @Test("A directory-sync failure after rename is recommitted once, then reported committed")
    func directorySyncFailureRecommitsOnce() throws {
        try withTemporaryDirectory { directory in
            let syncs = Mutex(0)
            let committer = DownloadIndexFileCommitter(durability: .init(
                fullSync: { _ in nil },
                directorySync: { _ in
                    syncs.withLock { value in value += 1; return value } == 1 ? EIO : nil
                }))
            let journal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: persistence(commit: { try committer.commit($0, to: $1) }))
            let value = try intent("attempt-sync")

            #expect(journal.add(value) == .committed(value))
            #expect(syncs.withLock { $0 } == 2)
            let restored = try loaded(directory)
            #expect(restored == [value])
        }
    }

    @Test("A directory sync that keeps failing is never reported committed")
    func persistentDirectorySyncFailureFails() throws {
        try withTemporaryDirectory { directory in
            let committer = DownloadIndexFileCommitter(durability: .init(
                fullSync: { _ in nil }, directorySync: { _ in EIO }))
            let journal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: persistence(
                    commit: { try committer.commit($0, to: $1) },
                    syncDirectory: { try committer.syncContainingDirectory(of: $0) }))
            let value = try intent("attempt-unsynced")

            guard case .failed(let failure) = journal.add(value) else {
                Issue.record("Expected an unsynced rename to fail"); return
            }
            #expect(failure.stage == .commit)
            // The visible value is not trusted either: ensure must sync it, and that still fails.
            guard case .failed = journal.ensure(value) else {
                Issue.record("Expected ensure of a visible-but-unsynced value to fail"); return
            }
        }
    }

    @Test("A pre-rename failure is not retried and leaves the canonical queue unchanged")
    func preRenameFailureIsNotRetried() throws {
        try withTemporaryDirectory { directory in
            let first = try intent("attempt-first")
            #expect(DownloadCleanupIntentJournal(directory: directory).add(first) == .committed(first))
            let canonical = directory.appendingPathComponent("download-cleanup-intents.json")
            let previous = try Data(contentsOf: canonical)
            let commits = Mutex(0)
            let committer = DownloadIndexFileCommitter(stageHook: { stage in
                if stage == .beforeReplace {
                    commits.withLock { $0 += 1 }
                    throw InjectedJournalFailure()
                }
            })
            let journal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: persistence(commit: { try committer.commit($0, to: $1) }))

            guard case .failed = journal.add(try intent("attempt-second")) else {
                Issue.record("Expected pre-rename failure"); return
            }
            #expect(commits.withLock { $0 } == 1)
            let current = try Data(contentsOf: canonical)
            #expect(current == previous)
        }
    }

    @Test("A protection-unavailable read is unreadable, never an empty queue")
    func protectedDataUnavailableIsUnreadable() throws {
        try withTemporaryDirectory { directory in
            let journal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: .init(
                    read: { _ in throw CocoaError(.fileReadNoPermission) },
                    encode: { try JSONEncoder().encode($0) },
                    commit: { _, _ in Issue.record("An unreadable queue must never be rewritten") }))
            guard case .failed(let failure) = journal.load() else {
                Issue.record("Expected unreadable"); return
            }
            #expect(failure.stage == .read)
            guard case .failed = journal.ensure(try intent("attempt-locked")) else {
                Issue.record("Expected ensure to fail closed"); return
            }
        }
    }

    @Test("Backup exclusion covers an existing authority directory and survives every rewrite")
    func backupExclusionSurvivesRewrites() throws {
        try withTemporaryDirectory { directory in
            let journal = DownloadCleanupIntentJournal(directory: directory)
            let directoryExcluded = try isExcludedFromBackup(directory)
            #expect(directoryExcluded)
            let first = try intent("attempt-one")
            let second = try intent("attempt-two")
            #expect(journal.add(first) == .committed(first))
            #expect(journal.add(second) == .committed(second))
            let canonical = directory.appendingPathComponent("download-cleanup-intents.json")
            let fileExcluded = try isExcludedFromBackup(canonical)
            #expect(fileExcluded)
            #expect(journal.remove(
                id: first.id, attemptKey: first.attemptKey, operation: first.operation)
                == .committed(removed: true))
            let rewrittenExcluded = try isExcludedFromBackup(canonical)
            #expect(rewrittenExcluded)
        }
    }

    // MARK: - Fixtures

    private func persistence(
        commit: @escaping @Sendable (Data, URL) throws -> Void,
        syncDirectory: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) -> DownloadCleanupIntentJournal.Persistence {
        .init(
            read: { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            },
            encode: { try JSONEncoder().encode($0) },
            commit: commit,
            syncDirectory: syncDirectory)
    }

    private func intent(_ attempt: String) throws -> DurableDownloadCleanupIntent {
        let attemptID = try #require(DownloadAttemptID(rawValue: attempt))
        let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://media.example")!, serverID: "server-1", userID: "user-1"))
        return try #require(DurableDownloadCleanupIntent(
            id: UUID(),
            attemptKey: DownloadAttemptKey(ratingKey: "jellyfin:item", attemptID: attemptID),
            backend: .jellyfin,
            server: server,
            operation: .activeEncoding(playSessionID: "session-\(attempt)")))
    }

    private func loaded(_ directory: URL) throws -> [DurableDownloadCleanupIntent] {
        guard case .loaded(let values) = DownloadCleanupIntentJournal(directory: directory).load()
        else { throw InjectedJournalFailure() }
        return values
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = DownloadTestFiles.temporaryDirectory
            .appendingPathComponent("durable-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try body(directory)
    }
}

private struct InjectedJournalFailure: Error {}
#endif
