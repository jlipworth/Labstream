#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// P2 commit 3 manager pins: legacy tombstone migration and its receipt barrier, and the Emby
/// 24-hour expiry journaling its abandonment before the row gives up its recovery identity.
@MainActor
@Suite("Cleanup runner manager integration", .serialized)
struct CleanupRunnerManagerTests {
    @Test("Legacy tombstones migrate into the journal; unconvertible ones are kept as evidence")
    func tombstonesMigrateWithStableIdentity() async throws {
        let directory = try makeDirectory("migrate")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        guard case .committed(let convertible) = store.addEmbyConvertCleanupTombstone(
                ratingKey: "emby:item", metadata: crashWindowMetadata(ratingKey: "emby:item")),
              case .committed(let unconvertible) = store.addEmbyConvertCleanupTombstone(
                ratingKey: "emby:legacy", metadata: OfflineMetadata(
                    ratingKey: "emby:legacy", title: "Legacy", type: "movie", backendKind: .emby))
        else { Issue.record("Expected tombstones"); return }
        let (manager, journal, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })

        manager.teardownOrphanedEncodersOnLaunch()

        guard case .loaded(let intents) = journal.load() else {
            Issue.record("Expected a readable journal"); return
        }
        let migrated = try #require(intents.first { $0.id == convertible.id })
        #expect(migrated.attemptKey.attemptID.rawValue
            == DownloadManager.legacyTombstoneAttemptPrefix + convertible.id.uuidString)
        #expect(migrated.provenance == .abandonment(originAttempt: migrated.attemptKey))
        guard case .embyConvert(.ambiguousCreate) = migrated.operation else {
            Issue.record("Expected the ambiguous-create authority"); return
        }
        guard case .loaded(let remaining) = store.loadEmbyConvertCleanupTombstones() else {
            Issue.record("Expected readable tombstones"); return
        }
        #expect(remaining.map(\.id) == [unconvertible.id])
    }

    @Test("A migrated intent stays blocked while its source tombstone still exists")
    func migrationReceiptBlocksReplay() async throws {
        let directory = try makeDirectory("receipt")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        guard case .committed(let tombstone) = store.addEmbyConvertCleanupTombstone(
            ratingKey: "emby:item", metadata: crashWindowMetadata(ratingKey: "emby:item"))
        else { Issue.record("Expected a tombstone"); return }
        let (manager, journal, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })
        manager.teardownOrphanedEncodersOnLaunch()
        guard case .loaded(let intents) = journal.load(),
              let migrated = intents.first(where: { $0.id == tombstone.id }) else {
            Issue.record("Expected the migrated intent"); return
        }
        #expect(!manager.cleanupIntentIsBlocked(migrated))

        // Simulate a removal that did not become durable: the tombstone is still on disk.
        #expect(store.addEmbyConvertCleanupTombstone(tombstone) == .committed(tombstone))
        #expect(manager.cleanupIntentIsBlocked(migrated))
    }

    @Test("Expiry journals its abandonment before clearing the recovery identity")
    func expiryJournalsFirst() async throws {
        let directory = try makeDirectory("expiry")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        let key = try seedExpiredPreparingRow(in: store)
        let (manager, journal, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })
        signInEmby(manager.appModel)

        manager.resumePendingServerPrepDownloads(allowWhileQueuePaused: true)

        guard case .loaded(let intents) = journal.load() else {
            Issue.record("Expected a readable journal"); return
        }
        let expired = try #require(intents.first)
        #expect(expired.provenance == .abandonment(originAttempt: key))
        guard case .embyConvert(.ambiguousCreate) = expired.operation else {
            Issue.record("Expected the ambiguous-create authority"); return
        }
        #expect(store.record(for: key)?.status == .failed)
        #expect(store.metadata(for: key.ratingKey)?.hasEmbyConvertCrashWindowIdentity == false)
    }

    @Test("When the expiry intent cannot be journaled, the row keeps its identity")
    func expiryJournalFailureKeepsIdentity() async throws {
        let directory = try makeDirectory("expiry-fail")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        let key = try seedExpiredPreparingRow(in: store)
        let failingJournal = DownloadCleanupIntentJournal(
            directory: directory.appendingPathComponent("failing-journal", isDirectory: true),
            persistence: .init(
                read: { _ in nil },
                encode: { try JSONEncoder().encode($0) },
                commit: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
        let (manager, _, session) = makeManager(
            store: store, directory: directory, journal: failingJournal)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })
        signInEmby(manager.appModel)

        manager.resumePendingServerPrepDownloads(allowWhileQueuePaused: true)

        #expect(store.record(for: key)?.status == .preparing)
        #expect(store.metadata(for: key.ratingKey)?.hasEmbyConvertCrashWindowIdentity == true)
    }

    // MARK: - Fixtures

    private func crashWindowMetadata(
        ratingKey: String, startedAt: Double = 123
    ) -> OfflineMetadata {
        let fingerprint = EmbyConvertRecoveryPolicy.Fingerprint(
            itemId: "item", quality: "Custom", profile: "profile", bitrate: 4_000_000,
            userId: "user-1")
        return OfflineMetadata(
            ratingKey: ratingKey, title: "Convert", type: "movie",
            backendKind: .emby, backendBaseURLString: "https://emby.example",
            backendServerID: "server-1", backendUserID: "user-1",
            downloadLane: .optimize, resumeMode: .serverPrepThenStatic,
            embyConvertJobBaselineIDs: [1, 2],
            embyConvertRecoveryFingerprint: fingerprint,
            embyConvertRecoveryStartedAtEpochSeconds: startedAt,
            embyConvertRecoveryPhase: .dispatchAmbiguous)
    }

    private func seedExpiredPreparingRow(in store: DownloadStore) throws -> DownloadAttemptKey {
        let key = DownloadAttemptKey(
            ratingKey: "emby:expired", attemptID: DownloadAttemptID(uuid: UUID()))
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Convert",
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"),
            status: .preparing, metadata: crashWindowMetadata(ratingKey: key.ratingKey))
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        return key
    }

    private func signInEmby(_ appModel: AppModel) {
        appModel.embyServerBaseURL = URL(string: "https://emby.example")!
        appModel.embyAccessToken = "token"
        appModel.embyUserID = "user-1"
        appModel.embyServerID = "server-1"
    }

    private func makeManager(
        store: DownloadStore,
        directory: URL,
        journal: DownloadCleanupIntentJournal? = nil
    ) -> (DownloadManager, DownloadCleanupIntentJournal, BackgroundDownloadSession) {
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        let journal = journal ?? DownloadCleanupIntentJournal(
            directory: store.durableCleanupAuthorityDirectory)
        let manager = DownloadManager(
            appModel: AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "cleanup-runner-\(UUID().uuidString)"), activeBackend: .emby),
            store: store, session: session, cleanupIntentJournal: journal,
            registerForBackgroundEvents: false)
        return (manager, journal, session)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-runner-\(label)-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
