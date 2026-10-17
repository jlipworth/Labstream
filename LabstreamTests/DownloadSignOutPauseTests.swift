import Foundation
import PMSKit
import Testing
@testable import Labstream

// Setup uses async persistence too: synchronous compatibility writes here starved other
// MainActor fixtures' two-second P6 startup heartbeat under normal parallel testing.
@MainActor
struct DownloadSignOutPauseTests {
    @Test func renderedRowActionsRejectAnOvertakenAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-row-attempt-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadStore(baseDirectory: directory)
        let first = try #require(makeRecord(
            store: store, ratingKey: "plex:item", backend: .plex, attemptSuffix: "first"))
        #expect(await store.createAttemptOwnedRecordAsync(first.record, attemptID: first.key.attemptID)
                == .committed(first.key))

        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "row-action-fence"))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        let manager = DownloadManager(appModel: model, store: store, session: session,
                                      registerForBackgroundEvents: false)
        defer { session.invalidateInjectedSessionForTesting() }

        let replacement = try #require(makeRecord(
            store: store, ratingKey: "plex:item", backend: .plex, attemptSuffix: "replacement"))
        #expect(await store.createAttemptOwnedRecordAsync(
            replacement.record, attemptID: replacement.key.attemptID,
            replacing: first.key.attemptID) == .committed(replacement.key))

        let stale = OfflineDownloadRowActionIdentity(
            ratingKey: first.key.ratingKey, attemptID: first.key.attemptID)
        #expect(manager.currentRecord(for: stale) == nil)
        #expect(!manager.pause(stale))
        #expect(!manager.retry(stale))
        #expect(!manager.delete(stale))
        #expect(store.record(for: replacement.key)?.status == .downloading)

        let current = OfflineDownloadRowActionIdentity(
            ratingKey: replacement.key.ratingKey, attemptID: replacement.key.attemptID)
        #expect(manager.currentRecord(for: current)?.attemptID == replacement.key.attemptID)
        #expect(manager.pause(current))
        await manager.drainManagerOperationsForTesting()
        #expect(store.record(for: replacement.key)?.status == .paused)
    }

    @Test func signingOutPausesOnlyActiveRowsOwnedByThatBackend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-signout-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadStore(baseDirectory: directory)
        let emby = try #require(makeRecord(store: store, ratingKey: "emby:item", backend: .emby))
        let jellyfin = try #require(makeRecord(store: store, ratingKey: "jellyfin:item", backend: .jellyfin))
        let plex = try #require(makeRecord(store: store, ratingKey: "plex:item", backend: .plex))
        #expect(await store.createAttemptOwnedRecordAsync(emby.record, attemptID: emby.key.attemptID) == .committed(emby.key))
        #expect(await store.createAttemptOwnedRecordAsync(jellyfin.record, attemptID: jellyfin.key.attemptID) == .committed(jellyfin.key))
        #expect(await store.createAttemptOwnedRecordAsync(plex.record, attemptID: plex.key.attemptID) == .committed(plex.key))

        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "download-signout"))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        let manager = DownloadManager(appModel: model, store: store, session: session,
                                      registerForBackgroundEvents: false)
        defer { session.invalidateInjectedSessionForTesting() }

        manager.pauseDownloadsForBackendSignOut(.emby)
        await manager.drainManagerOperationsForTesting()

        #expect(store.record(for: emby.key)?.status == .paused)
        #expect(store.record(for: jellyfin.key)?.status == .downloading)
        #expect(store.record(for: plex.key)?.status == .downloading)

        manager.pauseDownloadsForBackendSignOut(.jellyfin)
        await manager.drainManagerOperationsForTesting()

        #expect(store.record(for: jellyfin.key)?.status == .paused)
        #expect(store.record(for: plex.key)?.status == .downloading)
    }

    @Test func coordinatedSignOutPausesEveryBackendWithoutDeletingRecordsOrFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-signout-all-preserve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DownloadStore(baseDirectory: directory)
        let rows = try MediaBackendKind.allCases.map { backend in
            let kind = DownloadBackendKind(rawValue: backend.rawValue)!
            return try #require(makeRecord(
                store: store, ratingKey: "\(backend.rawValue):item", backend: kind))
        }
        for row in rows {
            #expect(await store.createAttemptOwnedRecordAsync(row.record, attemptID: row.key.attemptID)
                    == .committed(row.key))
            try Data("download".utf8).write(to: row.record.localURL)
        }

        let model = AppModel(identity: PlatformClientIdentity.make(
            clientIdentifier: "download-signout-all"))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        let manager = DownloadManager(appModel: model, store: store, session: session,
                                      registerForBackgroundEvents: false)
        defer { session.invalidateInjectedSessionForTesting() }

        MediaBackendKind.allCases.forEach(manager.pauseDownloadsForBackendSignOut)
        await manager.drainManagerOperationsForTesting()

        #expect(store.records.count == rows.count)
        for row in rows {
            #expect(store.record(for: row.key)?.status == .paused)
            #expect(FileManager.default.fileExists(atPath: row.record.localURL.path))
        }
    }

    #if !os(tvOS)
    @Test(arguments: [DownloadBackendKind.emby, .jellyfin], [(false, false), (false, true), (true, false), (true, true)])
    func signOutDoesNotBlockOnEncoderJournal(backend: DownloadBackendKind, outcome: (Bool, Bool)) async throws {
        let (fails, replaces) = outcome
        let hold = P6Hold()
        let completed = TestLockedBox(false)
        let live = DownloadCleanupIntentJournal.Persistence.live
        let f = try await P7PlaybackFixture(status: .paused, cleanupPersistence: .init(
            read: live.read, encode: live.encode, commit: { data, url in
                hold.hit()
                completed.withValue { $0 = true }
                if fails { throw CocoaError(.fileWriteOutOfSpace) }
                try live.commit(data, url)
            }, syncDirectory: live.syncDirectory))
        defer { hold.release.signal() }
        await f.manager.cleanupRunner?.waitUntilIdle()
        f.manager.cleanupRunner = nil
        let model = f.manager.appModel
        if backend == .emby {
            model.embyServerBaseURL = URL(string: "https://media.invalid")!
            model.embyAccessToken = "fixture"
            model.embyUserID = "fixture-user"
            model.embyServerID = "fixture-server"
            f.manager.embyPlaySessionByAttempt[f.key] = "old-session"
        } else {
            model.jellyfinServerBaseURL = URL(string: "https://media.invalid")!
            model.jellyfinAccessToken = "fixture"
            model.jellyfinUserID = "fixture-user"
            model.jellyfinServerID = "fixture-server"
            f.manager.jellyfinPlaySessionByAttempt[f.key] = "old-session"
        }
        _ = await f.store.updateMetadataAsync(for: f.key) {
            $0.backendKind = backend
            $0.backendBaseURLString = "https://media.invalid"
            $0.backendUserID = "fixture-user"
            $0.backendServerID = "fixture-server"
            $0.resumeMode = .liveForwardOnly
            $0.playSessionID = "old-session"
        }
        #expect(await f.manager.applyLifecycleEvent(.retry(.freshAttempt), for: f.key, context: "signout_fixture"))
        f.manager.activeJobs.insert(f.key.ratingKey)
        f.manager.inFlightAttempts.acquire(f.key)
        f.manager.refreshRecords()
        hold.arm()
        f.manager.pauseDownloadsForBackendSignOut(backend)
        _ = await hold.acknowledgement.wait()
        // Reaching MainActor with the physical journal commit still held is the heartbeat proof.
        #expect(!completed.value)
        #expect(f.store.record(for: f.key)?.status == .paused)
        #expect(f.store.record(for: f.key)?.metadata?.playSessionID == "old-session")
        model.embyAccessToken = nil
        model.jellyfinAccessToken = nil
        if replaces {
            // A newer exact handle can be installed while the old journal worker is held.
            _ = await f.store.updateMetadataAsync(for: f.key) { $0.playSessionID = "new-session" }
            if backend == .emby { f.manager.embyPlaySessionByAttempt[f.key] = "new-session" }
            else { f.manager.jellyfinPlaySessionByAttempt[f.key] = "new-session" }
        }
        hold.release.signal()
        await f.manager.drainManagerOperationsForTesting()
        let expected = replaces ? "new-session" : (fails ? "old-session" : nil)
        #expect(f.store.record(for: f.key)?.metadata?.playSessionID == expected)
        let transient = backend == .emby ? f.manager.embyPlaySessionByAttempt[f.key] : f.manager.jellyfinPlaySessionByAttempt[f.key]
        #expect(transient == expected)
        if case .loaded(let intents) = f.manager.cleanupIntentJournal.load() {
            #expect(intents.contains { $0.operation == .activeEncoding(playSessionID: "old-session") } == !fails)
        } else { Issue.record("Expected readable cleanup journal") }
        await f.finish()
    }
    #endif

    private func makeRecord(store: DownloadStore, ratingKey: String,
                            backend: DownloadBackendKind,
                            attemptSuffix: String? = nil) -> (key: DownloadAttemptKey, record: DownloadRecord)? {
        guard let attemptID = DownloadAttemptID(
            rawValue: "attempt-\(attemptSuffix ?? ratingKey)") else { return nil }
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        let record = DownloadRecord(
            ratingKey: ratingKey,
            attemptID: attemptID,
            title: "Test item",
            localURL: store.destinationURL(ratingKey: ratingKey, ext: "mp4"),
            bytes: 10,
            progress: 0.1,
            status: .downloading,
            metadata: OfflineMetadata(
                ratingKey: ratingKey,
                title: "Test item",
                type: "movie",
                sourcePartSize: 100,
                backendKind: backend,
                backendBaseURLString: "https://media.example.invalid",
                backendServerID: "server",
                backendUserID: "user",
                resumeMode: .staticByteRange))
        return (key, record)
    }
}
