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
        let convertible = LegacyEmbyTombstoneFixture.make(
            ratingKey: "emby:item", metadata: crashWindowMetadata(ratingKey: "emby:item"))
        let unconvertible = LegacyEmbyTombstoneFixture.make(
            ratingKey: "emby:legacy", metadata: OfflineMetadata(
                ratingKey: "emby:legacy", title: "Legacy", type: "movie", backendKind: .emby))
        try LegacyEmbyTombstoneFixture.write([convertible, unconvertible], to: store)
        let (manager, journal, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })

        manager.teardownOrphanedEncodersOnLaunch()
        await manager.launchSweepJournaling?.value
        await manager.cleanupRunner?.waitUntilIdle()

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
        let tombstone = LegacyEmbyTombstoneFixture.make(
            ratingKey: "emby:item", metadata: crashWindowMetadata(ratingKey: "emby:item"))
        try LegacyEmbyTombstoneFixture.write([tombstone], to: store)
        let (manager, journal, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })
        manager.teardownOrphanedEncodersOnLaunch()
        await manager.launchSweepJournaling?.value
        await manager.cleanupRunner?.waitUntilIdle()
        guard case .loaded(let intents) = journal.load(),
              let migrated = intents.first(where: { $0.id == tombstone.id }) else {
            Issue.record("Expected the migrated intent"); return
        }
        #expect(!(await manager.cleanupIntentIsBlocked(migrated)))

        // Simulate a removal that did not become durable: the tombstone is still on disk.
        try LegacyEmbyTombstoneFixture.write([tombstone], to: store)
        #expect(await manager.cleanupIntentIsBlocked(migrated))
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
        await manager.drainManagerOperationsForTesting()

        #expect(await waitUntil { store.metadata(for: key.ratingKey)?.hasEmbyConvertCrashWindowIdentity == false })
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
        await manager.drainManagerOperationsForTesting()

        #expect(store.record(for: key)?.status == .preparing)
        #expect(store.metadata(for: key.ratingKey)?.hasEmbyConvertCrashWindowIdentity == true)
    }

    @Test("Deleting a paused Plex prep row journals its queue-item cleanup first (D2)")
    func plexPausedPrepDeleteJournals() async throws {
        let directory = try makeDirectory("plex-delete")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        let key = DownloadAttemptKey(ratingKey: "plex:101", attemptID: DownloadAttemptID(uuid: UUID()))
        let metadata = OfflineMetadata(
            ratingKey: key.ratingKey, title: "Item", type: "movie",
            optimizeTargetName: "Medium", optimizeQueueTitle: "Item [Labstream abcd1234]",
            backendKind: .plex, backendBaseURLString: "https://plex.example.internal:32400",
            backendServerID: "machine-1", downloadLane: .optimize,
            resumeMode: .serverPrepThenStatic)
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Item",
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"),
            status: .paused, metadata: metadata)
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        let (manager, journal, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })

        manager.delete(ratingKey: key.ratingKey)
        #expect(await waitUntil { store.record(for: key) == nil })

        guard case .loaded(let intents) = journal.load() else {
            Issue.record("Expected a readable journal"); return
        }
        let intent = try #require(intents.first)
        #expect(intent.operation == .plexOptimize(queueTitle: "Item [Labstream abcd1234]"))
        #expect(intent.provenance == .rowDeletion)
        #expect(intent.plexCreate == .unresolved)
        #expect(intent.server.serverID == "machine-1")
        // The row leaves memory before its terminal commit; that window reads as retiring.
        #expect(await waitUntil { manager.cleanupRowState(for: intent) == .committedAbsent })
    }

    @Test("A superseded encoder stop is journaled from the captured session, with no row")
    func supersededStopJournalsFromCapturedSession() async throws {
        let directory = try makeDirectory("superseded")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        let (manager, journal, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        let key = DownloadAttemptKey(
            ratingKey: "jellyfin:gone", attemptID: DownloadAttemptID(uuid: UUID()))
        let captured = BackendSession(
            kind: .jellyfin, baseURL: URL(string: "https://jellyfin.example")!, token: "token",
            userID: "user-1", serverID: "server-1")

        manager.stopSupersededMediaBrowserEncoder(
            attemptKey: key, ratingKey: key.ratingKey, playSessionID: "minted-1",
            backendKind: .jellyfin, backendSession: captured)

        guard case .loaded(let intents) = journal.load() else {
            Issue.record("Expected a readable journal"); return
        }
        let intent = try #require(intents.first)
        #expect(intent.operation == .activeEncoding(playSessionID: "minted-1"))
        #expect(intent.provenance == .abandonment(originAttempt: key))
        #expect(intent.server.userID == "user-1")
    }

    @Test("A launch-sweep intent reused by delete is eligible to run once the removal commits")
    func terminalReleaseReusedByDeleteRuns() async throws {
        let directory = try makeDirectory("reuse")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        let key = DownloadAttemptKey(
            ratingKey: "jellyfin:done", attemptID: DownloadAttemptID(uuid: UUID()))
        let url = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
        try Data([1]).write(to: url)
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Done", localURL: url,
            bytes: 1, progress: 1, status: .complete,
            metadata: OfflineMetadata(
                ratingKey: key.ratingKey, title: "Done", type: "movie", backendKind: .jellyfin,
                backendBaseURLString: "https://jellyfin.example", backendServerID: "server-1",
                backendUserID: "user-1", playSessionID: "session-A"))
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        let (manager, journal, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })

        // Launch sweep: no Jellyfin session, so the intent is journaled and stays.
        manager.teardownOrphanedEncodersOnLaunch()
        await manager.launchSweepJournaling?.value
        await manager.cleanupRunner?.waitUntilIdle()
        guard case .loaded(let swept) = journal.load(), let release = swept.first else {
            Issue.record("Expected the terminal-release intent"); return
        }
        #expect(release.provenance == .terminalRelease)

        manager.delete(ratingKey: key.ratingKey)
        #expect(await waitUntil { store.record(for: key) == nil })
        #expect(await waitUntil { store.cleanupDisposition(for: key) == .committedAbsent })
        guard case .loaded(let after) = journal.load() else { return }
        #expect(after.map(\.id) == [release.id], "delete reuses the existing intent")
        let reused = try #require(after.first)
        #expect(CleanupIntentEligibilityPolicy.decision(
            provenance: reused.provenance, rowState: manager.cleanupRowState(for: reused)) == .run)
    }

    @Test("Stale-sweep attempt keys are stable per title and never contain it")
    func staleSweepKeys() {
        let title = "Some Title [Labstream 1234abcd]"
        let first = DownloadManager.staleSweepAttemptKey(queueTitle: title)
        #expect(first == DownloadManager.staleSweepAttemptKey(queueTitle: title))
        #expect(first != DownloadManager.staleSweepAttemptKey(queueTitle: title + "x"))
        #expect(!first.attemptID.rawValue.contains("Title"))
    }

    @Test("An abandonment cannot cancel a resource its still-active origin row holds")
    func activeOriginKeepsItsClaim() async throws {
        let directory = try makeDirectory("active-origin")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        let (manager, _, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })
        // Seed after startup reconcile, which would otherwise demote a task-less active row.
        let key = DownloadAttemptKey(
            ratingKey: "jellyfin:live", attemptID: DownloadAttemptID(uuid: UUID()))
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Live",
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"),
            status: .downloading,
            metadata: OfflineMetadata(
                ratingKey: key.ratingKey, title: "Live", type: "movie", backendKind: .jellyfin,
                backendBaseURLString: "https://jellyfin.example", backendServerID: "server-1",
                backendUserID: "user-1", playSessionID: "session-A"))
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        #expect(store.record(for: key)?.status == .downloading)
        // A producer whose journal write looked failed kept the encoder, yet the entry is visible.
        let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://jellyfin.example")!, serverID: "server-1", userID: "user-1"))
        let intent = try #require(DurableDownloadCleanupIntent(
            attemptKey: key, backend: .jellyfin, server: server,
            operation: .activeEncoding(playSessionID: "session-A"),
            provenance: .abandonment(originAttempt: key)))

        let claimers = manager.claimingRecords(for: intent)
        #expect(claimers.map(\.ratingKey) == [key.ratingKey])
        #expect(claimers.first?.metadata?.playSessionID == "session-A")
    }

    @Test("An abandonment cannot cancel a job its failed-but-retryable origin row kept")
    func failedOriginKeepsItsJob() async throws {
        let directory = try makeDirectory("failed-origin")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        let key = DownloadAttemptKey(
            ratingKey: "emby:kept", attemptID: DownloadAttemptID(uuid: UUID()))
        var metadata = crashWindowMetadata(ratingKey: key.ratingKey)
        metadata.clearEmbyConvertRecoveryIdentity()
        metadata.adoptEmbyConvertJobID(42)
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Convert",
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"),
            status: .failed, metadata: metadata)
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        let (manager, _, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })
        signInEmby(manager.appModel)
        // The duplicate-job abandonment write looked failed, so the row kept polling, then
        // parked as failed with its job preserved for Retry. The visible entry must not run.
        let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://emby.example")!, serverID: "server-1", userID: "user-1"))
        let intent = try #require(DurableDownloadCleanupIntent(
            attemptKey: key, backend: .emby, server: server,
            operation: .embyConvert(.knownJob(jobID: 42)),
            provenance: .abandonment(originAttempt: key)))

        #expect(await manager.executeCleanupIntent(intent) == .waiting)
    }

    @Test("An encoder abandonment is not blocked by a paused origin's stale PlaySessionId")
    func pausedOriginDoesNotStrandEncoderStop() async throws {
        let directory = try makeDirectory("paused-origin")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        let key = DownloadAttemptKey(
            ratingKey: "jellyfin:paused", attemptID: DownloadAttemptID(uuid: UUID()))
        // A crash between the abandonment commit and the reference clear left both on disk.
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Paused",
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"),
            status: .paused,
            metadata: OfflineMetadata(
                ratingKey: key.ratingKey, title: "Paused", type: "movie", backendKind: .jellyfin,
                backendBaseURLString: "https://jellyfin.example", backendServerID: "server-1",
                backendUserID: "user-1", playSessionID: "session-A"))
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        let (manager, _, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })
        let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://jellyfin.example")!, serverID: "server-1", userID: "user-1"))
        let intent = try #require(DurableDownloadCleanupIntent(
            attemptKey: key, backend: .jellyfin, server: server,
            operation: .activeEncoding(playSessionID: "session-A"),
            provenance: .abandonment(originAttempt: key)))

        #expect(manager.claimingRecords(for: intent).isEmpty)
    }

    @Test("Ownership claims are scoped to the persisted server and user")
    func claimsAreServerAndUserScoped() throws {
        let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://emby.example")!, serverID: "server-1", userID: "user-1"))
        func metadata(server: String?, user: String?, url: String? = nil) -> OfflineMetadata {
            OfflineMetadata(ratingKey: "emby:x", title: "X", type: "movie", backendKind: .emby,
                            backendBaseURLString: url, backendServerID: server,
                            backendUserID: user)
        }
        #expect(DownloadManager.persistedServer(of: metadata(server: "server-1", user: "user-1"),
                                                matches: server))
        #expect(!DownloadManager.persistedServer(of: metadata(server: "server-2", user: "user-1"),
                                                 matches: server))
        #expect(!DownloadManager.persistedServer(of: metadata(server: "server-1", user: "user-2"),
                                                 matches: server))
        // Rows without persisted identity conservatively claim.
        #expect(DownloadManager.persistedServer(of: metadata(server: nil, user: nil), matches: server))
    }

    @Test("Producer sessions never rebind captured work to another user on the same server")
    func cleanupSessionKeepsCapturedUser() async throws {
        let directory = try makeDirectory("session-user")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = DownloadStore(baseDirectory: directory)
        let (manager, _, session) = makeManager(store: store, directory: directory)
        defer { session.invalidateInjectedSessionForTesting() }
        signInEmby(manager.appModel)
        let server = URL(string: "https://emby.example")!
        let other = manager.cleanupSession(kind: .emby, server: server, token: "old", userID: "user-9")
        #expect(other.userID == "user-9")
        #expect(other.token == "old")
        let same = manager.cleanupSession(kind: .emby, server: server, token: "old", userID: "user-1")
        #expect(same.serverID == "server-1", "the live session is reused for the same user")
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
