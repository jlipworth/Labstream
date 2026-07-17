import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Download cleanup/index ordering")
struct DownloadCleanupOrderingTests {
    @Test func journalFailureDurablyReservesExactIntentAndRejectsReplacement() throws {
        try withDirectory { directory in
            let key = attemptKey("attempt-A")
            let store = DownloadStore(baseDirectory: directory)
            #expect(createRecord(store: store, key: key, persistedSession: nil))
            let candidate = try intent(key: key, session: "transient-session-A")
            let failedJournal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: failingJournalPersistence())

            guard case .deletionPending(let reserved, _) =
                    DownloadCleanupOrdering.prepareForDestructiveDeletion(
                        candidates: [candidate], key: key,
                        journal: failedJournal, store: store) else {
                Issue.record("Expected durable index fallback"); return
            }
            #expect(reserved == key)

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.isDeletionPending(for: key))
            #expect(relaunched.deletionPendingCleanupIntents(for: key) == [candidate])
            let replacement = attemptKey("attempt-B")
            guard case .rejectedOwnership(_, let actual, let reason) = relaunched
                .createAttemptOwnedRecord(
                    record(for: replacement), attemptID: replacement.attemptID,
                    replacing: key.attemptID) else {
                Issue.record("Deletion reservation must reject replacement B"); return
            }
            #expect(actual == key)
            #expect(reason == .deletionPending)
        }
    }

    @Test func partialJournalCommitKeepsAllOperationsInIndexThenRetriesWithoutDuplicates() throws {
        try withDirectory { directory in
            let key = attemptKey("attempt-A")
            let store = DownloadStore(baseDirectory: directory)
            #expect(createRecord(store: store, key: key, persistedSession: "session-A"))
            let active = try intent(key: key, session: "session-A")
            let convert = try convertIntent(key: key, jobID: 42)
            let controller = JournalWriteController(failOnWrite: 2)
            let partialJournal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: controller.persistence)

            guard case .deletionPending =
                    DownloadCleanupOrdering.prepareForDestructiveDeletion(
                        candidates: [active, convert], key: key,
                        journal: partialJournal, store: store) else {
                Issue.record("Expected partial journal failure to reserve index authority"); return
            }
            #expect(try loadedJournal(directory) == [active])
            let relaunched = DownloadStore(baseDirectory: directory)
            let pending = try #require(relaunched.deletionPendingCleanupIntents(for: key))
            #expect(pending == [active, convert])

            let healthy = DownloadCleanupIntentJournal(directory: directory)
            guard case .ready(let durable) =
                    DownloadCleanupOrdering.prepareForDestructiveDeletion(
                        candidates: pending, key: key,
                        journal: healthy, store: relaunched) else {
                Issue.record("Expected retry to migrate every operation"); return
            }
            #expect(durable == [active, convert])
            #expect(try loadedJournal(directory) == [active, convert])
            #expect(relaunched.remove(for: key) == .staleOrMissing)
            #expect(relaunched.completePendingDeletion(for: key) == .applied)
            #expect(DownloadStore(baseDirectory: directory).record(for: key.ratingKey) == nil)
        }
    }

    @Test func indexFailureLeavesOriginalDurableRowAndCleanupMetadataRetryable() throws {
        try withDirectory { directory in
            let writer = IndexWriteController(failOnWrite: 2)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writer.write(data, to: url) })
            let key = attemptKey("attempt-A")
            #expect(createRecord(store: store, key: key, persistedSession: "session-A"))
            let candidate = try intent(key: key, session: "session-A")
            let failedJournal = DownloadCleanupIntentJournal(
                directory: directory,
                persistence: failingJournalPersistence())

            guard case .indexPersistenceFailed(let failedKey, _) =
                    DownloadCleanupOrdering.prepareForDestructiveDeletion(
                        candidates: [candidate], key: key,
                        journal: failedJournal, store: store) else {
                Issue.record("Expected index failure to stop deletion"); return
            }
            #expect(failedKey == key)

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(!relaunched.isDeletionPending(for: key))
            #expect(relaunched.record(for: key.ratingKey)?.metadata?.playSessionID == "session-A")
            #expect(relaunched.record(for: key.ratingKey) != nil)
        }
    }

    @Test func pendingDeletionHaltPreservesHeldManifestAndBodyUntilJournaledDeletion() throws {
        try withDirectory { directory in
            let key = attemptKey("attempt-A")
            let store = DownloadStore(baseDirectory: directory)
            #expect(createRecord(store: store, key: key, persistedSession: "session-A"))
            let mediaURL = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
            try Data("partial-media".utf8).write(to: mediaURL)
            let heldRelativePath = "held-pending-A.body"
            let heldURL = directory.appendingPathComponent(heldRelativePath)
            try Data("ahead-range".utf8).write(to: heldURL)
            let manifest = OfflineHeldRangeSegment(
                offset: 64, length: 11, relativePath: heldRelativePath)
            guard case .accepted = store.persistHeldRangeSegment(for: key, segment: manifest) else {
                Issue.record("Expected held manifest persistence"); return
            }
            let candidate = try intent(key: key, session: "session-A")
            let failedJournal = DownloadCleanupIntentJournal(
                directory: directory, persistence: failingJournalPersistence())
            guard case .deletionPending =
                    DownloadCleanupOrdering.prepareForDestructiveDeletion(
                        candidates: [candidate], key: key,
                        journal: failedJournal, store: store) else {
                Issue.record("Expected deletion-pending reservation"); return
            }

            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            session.haltForPendingDeletion(ratingKey: key.ratingKey)

            #expect(store.metadata(for: key.ratingKey)?.heldRangeSegments == [manifest])
            #expect(FileManager.default.fileExists(atPath: heldURL.path))
            #expect(FileManager.default.fileExists(atPath: mediaURL.path))

            let healthy = DownloadCleanupIntentJournal(directory: directory)
            guard case .ready = DownloadCleanupOrdering.prepareForDestructiveDeletion(
                candidates: [candidate], key: key, journal: healthy, store: store) else {
                Issue.record("Expected pending authority to reach journal"); return
            }
            session.cancel(ratingKey: key.ratingKey)
            #expect(store.completePendingDeletion(for: key) == .applied)
            #expect(!FileManager.default.fileExists(atPath: heldURL.path))
            #expect(!FileManager.default.fileExists(atPath: mediaURL.path))
        }
    }

    @Test func legacyRatingKeyRemovalCannotBypassDeletionReservation() throws {
        try withDirectory { directory in
            let key = attemptKey("attempt-A")
            let store = DownloadStore(baseDirectory: directory)
            #expect(createRecord(store: store, key: key, persistedSession: "session-A"))
            let mediaURL = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
            try Data("owned-media".utf8).write(to: mediaURL)
            let candidate = try intent(key: key, session: "session-A")
            #expect(store.markDeletionPending(for: key, cleanupIntents: [candidate]) == .applied)

            store.remove(ratingKey: key.ratingKey)

            #expect(store.isDeletionPending(for: key))
            #expect(store.deletionPendingCleanupIntents(for: key) == [candidate])
            #expect(FileManager.default.fileExists(atPath: mediaURL.path))
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.isDeletionPending(for: key))
        }
    }

    @Test func embeddedPendingIntentsRecoverWithoutRowMetadata() throws {
        try withDirectory { directory in
            let key = attemptKey("attempt-A")
            let store = DownloadStore(baseDirectory: directory)
            let row = DownloadRecord(
                ratingKey: key.ratingKey,
                attemptID: key.attemptID,
                title: "Legacy item",
                localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"),
                status: .failed,
                metadata: nil)
            #expect(store.createAttemptOwnedRecord(row, attemptID: key.attemptID) == .committed(key))
            let candidate = try intent(key: key, session: "transient-session-A")
            let failedJournal = DownloadCleanupIntentJournal(
                directory: directory, persistence: failingJournalPersistence())
            guard case .deletionPending = DownloadCleanupOrdering.prepareForDestructiveDeletion(
                candidates: [candidate], key: key, journal: failedJournal, store: store) else {
                Issue.record("Expected embedded pending authority"); return
            }

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.record(for: key.ratingKey)?.metadata == nil)
            let embedded = try #require(relaunched.deletionPendingCleanupIntents(for: key))
            guard case .ready(let durable) = DownloadCleanupOrdering.prepareForDestructiveDeletion(
                candidates: embedded,
                key: key,
                journal: DownloadCleanupIntentJournal(directory: directory),
                store: relaunched) else {
                Issue.record("Expected metadata-free recovery from embedded intents"); return
            }
            #expect(durable == [candidate])
            #expect(relaunched.completePendingDeletion(for: key) == .applied)
        }
    }

    @Test @MainActor
    func relaunchWithJournalStillFailingPreservesAllArtifactsAndAdmitsNoRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-cleanup-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = attemptKey("attempt-A")
        let initial = DownloadStore(baseDirectory: directory)
        let mediaURL = initial.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
        let row = DownloadRecord(
            ratingKey: key.ratingKey,
            attemptID: key.attemptID,
            title: "Pending range",
            localURL: mediaURL,
            bytes: 13,
            progress: 0.25,
            status: .downloading,
            metadata: OfflineMetadata(
                ratingKey: key.ratingKey,
                title: "Pending range",
                type: "movie",
                sourcePartSize: 52,
                backendKind: .emby,
                backendBaseURLString: "https://emby.example",
                backendServerID: "server-1",
                backendUserID: "user-1",
                playSessionID: "session-A",
                resumeMode: .staticByteRange))
        #expect(initial.createAttemptOwnedRecord(row, attemptID: key.attemptID) == .committed(key))
        try Data("published-main".utf8).write(to: mediaURL)
        let workingURL = try #require(initial.attemptWorkingFileURL(for: key))
        try Data("durable-partial".utf8).write(to: workingURL)
        #expect(initial.setResumeData(
            for: key, Data("resume-blob".utf8), displayBytes: 13) == .applied)
        let resumeRelative = try #require(initial.metadata(for: key.ratingKey)?.resumeDataRelativePath)
        let resumeURL = directory.appendingPathComponent(resumeRelative)
        let held = OfflineHeldRangeSegment(
            offset: 26, length: 10, relativePath: "held-relaunch-A.body")
        let heldURL = directory.appendingPathComponent(held.relativePath)
        try Data("ahead-body".utf8).write(to: heldURL)
        guard case .accepted = initial.persistHeldRangeSegment(for: key, segment: held) else {
            Issue.record("Expected held manifest persistence"); return
        }
        let candidate = try intent(key: key, session: "session-A")
        #expect(initial.markDeletionPending(for: key, cleanupIntents: [candidate]) == .applied)

        let relaunched = DownloadStore(baseDirectory: directory)
        let session = BackgroundDownloadSession(store: relaunched, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let failedJournal = DownloadCleanupIntentJournal(
            directory: directory, persistence: failingJournalPersistence())
        let manager = DownloadManager(
            appModel: AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "pending-relaunch"), activeBackend: .emby),
            store: relaunched,
            session: session,
            cleanupIntentJournal: failedJournal,
            registerForBackgroundEvents: false)

        for _ in 0..<100 {
            if manager.startupRecoveryState == .ready,
               manager.lastError[key.ratingKey] != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(manager.startupRecoveryState == .ready)
        #expect(relaunched.isDeletionPending(for: key))
        #expect(relaunched.record(for: key)?.status == .downloading)
        #expect(relaunched.metadata(for: key.ratingKey)?.heldRangeSegments == [held])
        #expect(FileManager.default.fileExists(atPath: mediaURL.path))
        #expect(FileManager.default.fileExists(atPath: workingURL.path))
        #expect(FileManager.default.fileExists(atPath: heldURL.path))
        #expect(FileManager.default.fileExists(atPath: resumeURL.path))
        #expect(manager.activeJobs.isEmpty)
        #expect(manager.downloadWorkRegistry.snapshot().totalCount == 0)
        let sessionSnapshot = session.diagnosticSnapshot()
        #expect(sessionSnapshot.opaqueInflightCount == 0)
        #expect(sessionSnapshot.rangeInflightCount == 0)
        #expect(sessionSnapshot.finalizingRatingKeyCount == 0)
    }

    @Test @MainActor
    func journalFailureCancelsHeldJellyfinKeepaliveWithoutClearingCleanupAuthority() async throws {
        let directory = try makeTemporaryDirectory("keepalive")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = DownloadAttemptKey(
            ratingKey: "jellyfin:item",
            attemptID: DownloadAttemptID(rawValue: "attempt-A")!)
        let store = DownloadStore(baseDirectory: directory)
        let mediaURL = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
        let metadata = OfflineMetadata(
            ratingKey: key.ratingKey, title: "Keepalive", type: "movie",
            backendKind: .jellyfin, backendBaseURLString: "https://jellyfin.example",
            backendServerID: "server-1", backendUserID: "user-1",
            playSessionID: "session-A", downloadLane: .optimize,
            resumeMode: .liveForwardOnly)
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Keepalive",
            localURL: mediaURL, status: .downloading, metadata: metadata)
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        try Data("main".utf8).write(to: mediaURL)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let manager = DownloadManager(
            appModel: AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "pending-keepalive"), activeBackend: .jellyfin),
            store: store,
            session: session,
            cleanupIntentJournal: DownloadCleanupIntentJournal(
                directory: directory, persistence: failingJournalPersistence()),
            registerForBackgroundEvents: false)
        #expect(await waitUntil { manager.startupRecoveryState == .ready })

        let held = HeldManagerTask()
        manager.registerKeepaliveTaskForTesting(held.task(), for: key, backend: .jellyfin)
        #expect(await waitUntil { held.started })
        manager.delete(ratingKey: key.ratingKey)

        #expect(await waitUntil { held.cancelled })
        #expect(store.isDeletionPending(for: key))
        #expect(store.metadata(for: key.ratingKey)?.playSessionID == "session-A")
        let pending = try #require(store.deletionPendingCleanupIntents(for: key))
        #expect(pending.map(\.operation) == [.activeEncoding(playSessionID: "session-A")])
        #expect(FileManager.default.fileExists(atPath: mediaURL.path))
    }

    @Test @MainActor
    func journalFailureCancelsHeldEmbyConvertControlWithoutClearingJobAuthority() async throws {
        let directory = try makeTemporaryDirectory("emby-poll")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = attemptKey("attempt-A")
        let store = DownloadStore(baseDirectory: directory)
        let mediaURL = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
        let metadata = OfflineMetadata(
            ratingKey: key.ratingKey, title: "Convert", type: "movie",
            backendKind: .emby, backendBaseURLString: "https://emby.example",
            backendServerID: "server-1", backendUserID: "user-1",
            downloadLane: .optimize, resumeMode: .serverPrepThenStatic,
            embyConvertJobID: 42)
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Convert",
            localURL: mediaURL, status: .preparing, metadata: metadata)
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let manager = DownloadManager(
            appModel: AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "pending-emby-poll"), activeBackend: .emby),
            store: store,
            session: session,
            cleanupIntentJournal: DownloadCleanupIntentJournal(
                directory: directory, persistence: failingJournalPersistence()),
            registerForBackgroundEvents: false)
        #expect(await waitUntil { manager.startupRecoveryState == .ready })
        manager.activeJobs.insert(key.ratingKey)
        manager.inFlightAttempts.acquire(key)
        let convertAttempt = manager.beginEmbyConvertAttempt(for: key)
        #expect(manager.embyConvertAttemptIsCurrent(
            ratingKey: key.ratingKey, attemptID: convertAttempt, jobId: 42))
        let held = HeldManagerTask()
        manager.registerServerPrepPollerTask(held.task(), for: key)
        #expect(await waitUntil { held.started })

        manager.delete(ratingKey: key.ratingKey)

        #expect(await waitUntil { held.cancelled })
        #expect(store.isDeletionPending(for: key))
        #expect(store.metadata(for: key.ratingKey)?.embyConvertJobID == 42)
        #expect(!manager.embyConvertAttemptIsCurrent(
            ratingKey: key.ratingKey, attemptID: convertAttempt, jobId: 42))
        let pending = try #require(store.deletionPendingCleanupIntents(for: key))
        #expect(pending.map(\.operation) == [.embyConvert(.knownJob(jobID: 42))])
    }

    // D8: a delete() that loses the server encoder identity (makeActiveEncodingCleanupIntent
    // returns nil) still deletes locally and discloses the leak. That disclosure is ABOUT the
    // deletion succeeding, so it must survive the success path's `lastError = nil` clear.
    @Test @MainActor
    func deleteDisclosesActiveEncodingLeakThatSurvivesSuccessfulRemoval() async throws {
        let directory = try makeTemporaryDirectory("leak-active")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = attemptKey("attempt-A")
        let store = DownloadStore(baseDirectory: directory)
        let mediaURL = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
        // backendUserID nil makes the cleanup intent unbuildable → the fail-open leak branch.
        let metadata = OfflineMetadata(
            ratingKey: key.ratingKey, title: "Leaky", type: "movie",
            backendKind: .emby, backendBaseURLString: "https://emby.example",
            backendServerID: "server-1", backendUserID: nil,
            playSessionID: "session-A")
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Leaky",
            localURL: mediaURL, status: .complete, metadata: metadata)
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        try Data("main".utf8).write(to: mediaURL)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let manager = DownloadManager(
            appModel: AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "leak-active"), activeBackend: .emby),
            store: store, session: session,
            cleanupIntentJournal: DownloadCleanupIntentJournal(directory: directory),
            registerForBackgroundEvents: false)
        #expect(await waitUntil { manager.startupRecoveryState == .ready })
        #expect(manager.lastError[key.ratingKey] == nil)

        manager.delete(ratingKey: key.ratingKey)

        #expect(await waitUntil { store.record(for: key.ratingKey) == nil })
        // The row is gone but the disclosure must persist past `.removed`, not be cleared to nil.
        #expect(await waitUntil {
            manager.lastError[key.ratingKey] == .transferFailed(
                "Downloaded file deleted; server cleanup identity was unavailable.")
        })
    }

    // D8: same survival guarantee for the Emby convert-job identity branch.
    @Test @MainActor
    func deleteDisclosesEmbyConvertLeakThatSurvivesSuccessfulRemoval() async throws {
        let directory = try makeTemporaryDirectory("leak-convert")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = attemptKey("attempt-A")
        let store = DownloadStore(baseDirectory: directory)
        let mediaURL = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
        // No playSessionID (skips the encoder branch); embyConvertJobID present but backendUserID
        // nil makes the convert intent unbuildable → the convert fail-open leak branch.
        let metadata = OfflineMetadata(
            ratingKey: key.ratingKey, title: "Converting", type: "movie",
            backendKind: .emby, backendBaseURLString: "https://emby.example",
            backendServerID: "server-1", backendUserID: nil,
            embyConvertJobID: 42)
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Converting",
            localURL: mediaURL, status: .complete, metadata: metadata)
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        try Data("main".utf8).write(to: mediaURL)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let manager = DownloadManager(
            appModel: AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "leak-convert"), activeBackend: .emby),
            store: store, session: session,
            cleanupIntentJournal: DownloadCleanupIntentJournal(directory: directory),
            registerForBackgroundEvents: false)
        #expect(await waitUntil { manager.startupRecoveryState == .ready })
        #expect(manager.lastError[key.ratingKey] == nil)

        manager.delete(ratingKey: key.ratingKey)

        #expect(await waitUntil { store.record(for: key.ratingKey) == nil })
        #expect(await waitUntil {
            manager.lastError[key.ratingKey] == .transferFailed(
                "Downloaded file deleted; server conversion cleanup identity was unavailable.")
        })
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 100,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-cleanup-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func attemptKey(_ attempt: String) -> DownloadAttemptKey {
        DownloadAttemptKey(
            ratingKey: "emby:item",
            attemptID: DownloadAttemptID(rawValue: attempt)!)
    }

    private func record(
        for key: DownloadAttemptKey,
        persistedSession: String? = nil,
        localURL: URL = URL(fileURLWithPath: "/tmp/item.mp4")
    ) -> DownloadRecord {
        DownloadRecord(
            ratingKey: key.ratingKey,
            attemptID: key.attemptID,
            title: "Item",
            localURL: localURL,
            status: .failed,
            metadata: OfflineMetadata(
                ratingKey: key.ratingKey,
                title: "Item",
                type: "movie",
                backendKind: .emby,
                backendBaseURLString: "https://emby.example",
                backendServerID: "server-1",
                backendUserID: "user-1",
                playSessionID: persistedSession))
    }

    private func createRecord(
        store: DownloadStore,
        key: DownloadAttemptKey,
        persistedSession: String?
    ) -> Bool {
        let value = record(
            for: key,
            persistedSession: persistedSession,
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"))
        guard case .committed(let actual) = store.createAttemptOwnedRecord(
            value, attemptID: key.attemptID) else { return false }
        return actual == key
    }

    private func intent(
        key: DownloadAttemptKey,
        session: String
    ) throws -> DurableDownloadCleanupIntent {
        try #require(DurableDownloadCleanupIntent(
            id: UUID(uuidString: session == "session-A"
                ? "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
                : "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
            attemptKey: key,
            backend: .emby,
            server: serverIdentity(),
            operation: .activeEncoding(playSessionID: session)))
    }

    private func convertIntent(
        key: DownloadAttemptKey,
        jobID: Int
    ) throws -> DurableDownloadCleanupIntent {
        try #require(DurableDownloadCleanupIntent(
            id: UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!,
            attemptKey: key,
            backend: .emby,
            server: serverIdentity(),
            operation: .embyConvert(.knownJob(jobID: jobID))))
    }

    private func serverIdentity() -> DurableDownloadCleanupIntent.ServerIdentity {
        DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://emby.example")!,
            serverID: "server-1",
            userID: "user-1")!
    }

    private func failingJournalPersistence() -> DownloadCleanupIntentJournal.Persistence {
        .init(
            read: liveRead,
            encode: { try JSONEncoder().encode($0) },
            atomicWrite: { _, _ in throw OrderingFailure() })
    }

    private func loadedJournal(_ directory: URL) throws -> [DurableDownloadCleanupIntent] {
        guard case .loaded(let values) = DownloadCleanupIntentJournal(directory: directory).load()
        else { throw OrderingFailure() }
        return values
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-cleanup-ordering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private var liveRead: @Sendable (URL) throws -> Data? {
        { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
    }
}

private struct OrderingFailure: Error {}

private final class JournalWriteController: @unchecked Sendable {
    private let lock = NSLock()
    private let failOnWrite: Int
    private var writes = 0

    init(failOnWrite: Int) { self.failOnWrite = failOnWrite }

    var persistence: DownloadCleanupIntentJournal.Persistence {
        .init(
            read: { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            },
            encode: { try JSONEncoder().encode($0) },
            atomicWrite: { [self] data, url in
                let shouldFail = lock.withLock {
                    writes += 1
                    return writes == failOnWrite
                }
                if shouldFail { throw OrderingFailure() }
                try data.write(to: url, options: .atomic)
            })
    }
}

private final class IndexWriteController: @unchecked Sendable {
    private let lock = NSLock()
    private let failOnWrite: Int
    private var writes = 0

    init(failOnWrite: Int) { self.failOnWrite = failOnWrite }

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            writes += 1
            return writes == failOnWrite
        }
        if shouldFail { throw OrderingFailure() }
        try data.write(to: url, options: .atomic)
    }
}

private final class HeldManagerTask: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false

    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }

    func task() -> Task<Void, Never> {
        Task { [self] in
            lock.withLock { didStart = true }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                lock.withLock { didCancel = true }
            }
        }
    }
}
