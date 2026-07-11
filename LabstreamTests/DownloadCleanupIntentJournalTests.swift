import Foundation
import PMSKit
import Testing
@testable import Labstream

struct DownloadCleanupIntentJournalTests {
    @Test func managerFactoryBindsOnlyMediaBrowserAttemptsToPersistedServerAuthority() throws {
        let attemptID = try #require(DownloadAttemptID(rawValue: "attempt-1"))
        let key = DownloadAttemptKey(ratingKey: "jellyfin:item", attemptID: attemptID)
        let metadata = OfflineMetadata(
            ratingKey: key.ratingKey, title: "Item", type: "movie",
            backendKind: .jellyfin,
            backendBaseURLString: "HTTPS://Media.Example/base?token=secret",
            backendServerID: "server-1", backendUserID: "user-1")
        let value = try #require(DownloadManager.makeActiveEncodingCleanupIntent(
            attemptKey: key, metadata: metadata, playSessionID: "play-1"))
        #expect(value.attemptKey == key)
        #expect(value.backend == .jellyfin)
        #expect(value.server.baseURLString == "https://media.example/base")
        #expect(value.operation == .activeEncoding(playSessionID: "play-1"))

        var plex = metadata
        plex.backendKind = .plex
        #expect(DownloadManager.makeActiveEncodingCleanupIntent(
            attemptKey: key, metadata: plex, playSessionID: "play-1") == nil)
        var missingUser = metadata
        missingUser.backendUserID = nil
        #expect(DownloadManager.makeActiveEncodingCleanupIntent(
            attemptKey: key, metadata: missingUser, playSessionID: "play-1") == nil)
    }

    @Test func managerFactoryPrefersKnownConvertJobAndBuildsExactAmbiguousAuthority() throws {
        let attemptID = try #require(DownloadAttemptID(rawValue: "convert-attempt"))
        let key = DownloadAttemptKey(ratingKey: "emby:item", attemptID: attemptID)
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "item", quality: "Custom", profile: "profile", bitrate: 4_000_000,
            userId: "user-1")
        var metadata = OfflineMetadata(
            ratingKey: key.ratingKey, title: "Item", type: "movie",
            backendKind: .emby, backendBaseURLString: "https://emby.example",
            backendServerID: "server-1", backendUserID: "user-1",
            embyConvertJobID: 42, embyConvertJobBaselineIDs: [1, 2],
            embyConvertRecoveryFingerprint: fingerprint,
            embyConvertRecoveryStartedAtEpochSeconds: 123,
            embyConvertRecoveryPhase: .dispatchAmbiguous)

        let known = try #require(DownloadManager.makeEmbyConvertCleanupIntent(
            attemptKey: key, metadata: metadata))
        #expect(known.operation == .embyConvert(.knownJob(jobID: 42)))

        metadata.embyConvertJobID = nil
        let ambiguous = try #require(DownloadManager.makeEmbyConvertCleanupIntent(
            attemptKey: key, metadata: metadata))
        #expect(ambiguous.operation == .embyConvert(.ambiguousCreate(
            baselineJobIDs: [1, 2], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: 123, phase: .dispatchAmbiguous)))

        metadata.embyConvertRecoveryPhase = nil
        #expect(DownloadManager.makeEmbyConvertCleanupIntent(
            attemptKey: key, metadata: metadata) == nil)
    }

    @Test func convertIntentUsesSameExactJournalCompareRemoveContract() throws {
        try withTemporaryDirectory { directory in
            let attemptID = try #require(DownloadAttemptID(rawValue: "convert-attempt"))
            let key = DownloadAttemptKey(ratingKey: "emby:item", attemptID: attemptID)
            let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
                baseURL: URL(string: "https://emby.example")!,
                serverID: "server-1", userID: "user-1"))
            let value = try #require(DurableDownloadCleanupIntent(
                attemptKey: key, backend: .emby, server: server,
                operation: .embyConvert(.knownJob(jobID: 42))))
            let journal = DownloadCleanupIntentJournal(directory: directory)
            #expect(journal.add(value) == .committed(value))
            #expect(journal.remove(
                id: value.id, attemptKey: key,
                operation: .embyConvert(.knownJob(jobID: 7))) == .committed(removed: false))
            #expect(try loaded(journal) == [value])
            #expect(journal.remove(
                id: value.id, attemptKey: key, operation: value.operation)
                == .committed(removed: true))
        }
    }

    @Test func exactAddIsIdempotentAndCompareRemovePreservesSiblings() throws {
        try withTemporaryDirectory { directory in
            let journal = DownloadCleanupIntentJournal(directory: directory)
            let first = try intent(id: UUID(), attempt: "attempt-A", session: "session-A")
            let second = try intent(id: UUID(), attempt: "attempt-B", session: "session-B")
            #expect(try loaded(journal).isEmpty)
            #expect(journal.add(first) == .committed(first))
            #expect(journal.add(first) == .committed(first))
            #expect(journal.add(second) == .committed(second))
            #expect(try loaded(journal) == [first, second])

            #expect(journal.remove(
                id: first.id,
                attemptKey: second.attemptKey,
                operation: first.operation) == .committed(removed: false))
            #expect(journal.remove(
                id: first.id,
                attemptKey: first.attemptKey,
                operation: .activeEncoding(playSessionID: "wrong")) == .committed(removed: false))
            #expect(try loaded(journal) == [first, second])
            #expect(journal.remove(
                id: first.id,
                attemptKey: first.attemptKey,
                operation: first.operation) == .committed(removed: true))
            #expect(try loaded(journal) == [second])
        }
    }

    @Test func duplicateUUIDWithDifferentAuthorityConflictsWithoutChangingQueue() throws {
        try withTemporaryDirectory { directory in
            let journal = DownloadCleanupIntentJournal(directory: directory)
            let id = UUID()
            let first = try intent(id: id, attempt: "attempt-A", session: "session-A")
            let conflict = try intent(id: id, attempt: "attempt-B", session: "session-B")
            #expect(journal.add(first) == .committed(first))
            #expect(journal.add(conflict) == .conflictingID(first))
            #expect(try loaded(journal) == [first])
        }
    }

    @Test func persistedDuplicateUUIDsAreCorruptionEvenWhenValuesAreIdentical() throws {
        try withTemporaryDirectory { directory in
            let value = try intent(id: UUID(), attempt: "attempt-A", session: "session-A")
            let canonical = directory.appendingPathComponent("download-cleanup-intents.json")
            let duplicateBytes = try JSONEncoder().encode([value, value])
            try duplicateBytes.write(to: canonical)
            let journal = DownloadCleanupIntentJournal(directory: directory)

            guard case .failed(let loadFailure) = journal.load() else {
                Issue.record("Expected duplicate UUID queue to fail decoding"); return
            }
            #expect(loadFailure.stage == .decode)
            guard case .failed(let addFailure) = journal.add(value) else {
                Issue.record("Expected add to refuse duplicate UUID queue"); return
            }
            #expect(addFailure.stage == .decode)
            guard case .failed(let removeFailure) = journal.remove(
                id: value.id, attemptKey: value.attemptKey, operation: value.operation) else {
                Issue.record("Expected remove to refuse duplicate UUID queue"); return
            }
            #expect(removeFailure.stage == .decode)
            #expect(try Data(contentsOf: canonical) == duplicateBytes)
        }
    }

    @Test func unreadableAndCorruptQueuesFailClosedWithoutChangingCanonicalBytes() throws {
        try withTemporaryDirectory { directory in
            let canonical = directory.appendingPathComponent("download-cleanup-intents.json")
            let corrupt = Data("not-json".utf8)
            try corrupt.write(to: canonical)
            let corruptJournal = DownloadCleanupIntentJournal(directory: directory)
            let value = try intent(id: UUID(), attempt: "attempt-A", session: "session-A")
            guard case .failed(let loadFailure) = corruptJournal.load() else {
                Issue.record("Expected decode failure"); return
            }
            #expect(loadFailure.stage == .decode)
            guard case .failed(let addFailure) = corruptJournal.add(value) else {
                Issue.record("Expected corrupt add failure"); return
            }
            #expect(addFailure.stage == .decode)
            guard case .failed(let removeFailure) = corruptJournal.remove(
                id: value.id, attemptKey: value.attemptKey, operation: value.operation) else {
                Issue.record("Expected corrupt remove failure"); return
            }
            #expect(removeFailure.stage == .decode)
            #expect(try Data(contentsOf: canonical) == corrupt)

            let unreadable = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: .init(
                    read: { _ in throw InjectedCleanupJournalFailure() },
                    encode: { try JSONEncoder().encode($0) },
                    atomicWrite: { _, _ in Issue.record("Unreadable queue must never be overwritten") }))
            guard case .failed(let readFailure) = unreadable.load() else {
                Issue.record("Expected read failure"); return
            }
            #expect(readFailure.stage == .read)
            guard case .failed(let addReadFailure) = unreadable.add(value) else {
                Issue.record("Expected add read failure"); return
            }
            #expect(addReadFailure.stage == .read)
        }
    }

    @Test func encodeAndPreReplaceFailuresAreObservableAndPreserveCanonicalQueue() throws {
        try withTemporaryDirectory { directory in
            let initial = DownloadCleanupIntentJournal(directory: directory)
            let first = try intent(id: UUID(), attempt: "attempt-A", session: "session-A")
            let second = try intent(id: UUID(), attempt: "attempt-B", session: "session-B")
            #expect(initial.add(first) == .committed(first))
            let canonical = directory.appendingPathComponent("download-cleanup-intents.json")
            let previous = try Data(contentsOf: canonical)

            let encodeFailure = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: .init(
                    read: liveRead,
                    encode: { _ in throw InjectedCleanupJournalFailure() },
                    atomicWrite: { _, _ in Issue.record("Commit must not run after encode failure") }))
            guard case .failed(let encoding) = encodeFailure.add(second) else {
                Issue.record("Expected encode failure"); return
            }
            #expect(encoding.stage == .encode)

            let temp = directory.appendingPathComponent("cleanup-intent.tmp")
            let preReplace = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: .init(
                    read: liveRead,
                    encode: { try JSONEncoder().encode($0) },
                    atomicWrite: { data, _ in
                        try data.write(to: temp)
                        throw InjectedCleanupJournalFailure()
                    }))
            guard case .failed(let commit) = preReplace.add(second) else {
                Issue.record("Expected pre-replace failure"); return
            }
            #expect(commit.stage == .commit)
            #expect(try Data(contentsOf: canonical) == previous)
            #expect(try loaded(DownloadCleanupIntentJournal(directory: directory)) == [first])
        }
    }

    @Test func replaceThenThrowIsProvenForExactAddAndRemove() throws {
        try withTemporaryDirectory { directory in
            let journal = DownloadCleanupIntentJournal(
                directory: directory, persistence: replaceThenThrowPersistence())
            let first = try intent(id: UUID(), attempt: "attempt-A", session: "session-A")
            let second = try intent(id: UUID(), attempt: "attempt-B", session: "session-B")
            #expect(journal.add(first) == .committed(first))
            #expect(journal.add(second) == .committed(second))
            #expect(try loaded(DownloadCleanupIntentJournal(directory: directory)) == [first, second])
            #expect(journal.remove(
                id: first.id,
                attemptKey: first.attemptKey,
                operation: first.operation) == .committed(removed: true))
            #expect(try loaded(DownloadCleanupIntentJournal(directory: directory)) == [second])
        }
    }

    private let liveRead: @Sendable (URL) throws -> Data? = { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func replaceThenThrowPersistence() -> DownloadCleanupIntentJournal.Persistence {
        .init(
            read: liveRead,
            encode: { try JSONEncoder().encode($0) },
            atomicWrite: { data, url in
                try data.write(to: url, options: .atomic)
                throw InjectedCleanupJournalFailure()
            })
    }

    private func intent(id: UUID, attempt: String, session: String) throws
        -> DurableDownloadCleanupIntent {
        let attemptID = try #require(DownloadAttemptID(rawValue: attempt))
        let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://media.example")!,
            serverID: "server-1",
            userID: "user-1"))
        return try #require(DurableDownloadCleanupIntent(
            id: id,
            attemptKey: DownloadAttemptKey(ratingKey: "emby:item", attemptID: attemptID),
            backend: .emby,
            server: server,
            operation: .activeEncoding(playSessionID: session)))
    }

    private func loaded(_ journal: DownloadCleanupIntentJournal) throws
        -> [DurableDownloadCleanupIntent] {
        guard case .loaded(let values) = journal.load() else {
            throw InjectedCleanupJournalFailure()
        }
        return values
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-cleanup-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private struct InjectedCleanupJournalFailure: Error {}
