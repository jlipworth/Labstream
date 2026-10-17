#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// P3b upgrade pass: a v4 index keeps complete, unverified and paused static-range rows, removes
/// every other row through Delete before `.ready`, records the notice once, and stamps v5.
@MainActor
@Suite("Manager schema upgrade", .serialized)
struct ManagerSchemaUpgradeTests {
    @Test("A v4 library keeps finished and paused-static rows, removes the rest, and stamps v5")
    func upgradeKeepsPartialsAndRemovesInFlightRows() async throws {
        let directory = try makeDirectory("upgrade")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let seedStore = DownloadStore(baseDirectory: directory)
        let complete = try seed("plex:complete", status: .complete, mode: .staticByteRange,
                                in: seedStore)
        let pausedStatic = try seed("plex:paused-static", status: .paused, mode: .staticByteRange,
                                    in: seedStore)
        let pausedLive = try seed("jellyfin:paused-live", status: .paused, mode: .liveForwardOnly,
                                  in: seedStore)
        let failed = try seed("plex:failed", status: .failed, mode: .staticByteRange,
                              in: seedStore)
        let queued = try seed("plex:queued", status: .queued, mode: .staticByteRange,
                              in: seedStore)
        guard case .committed = await seedStore.flushPersistence(timeout: 5) else {
            Issue.record("Expected the seed to commit"); return
        }
        try rewriteEnvelope(directory) { $0["schemaVersion"] = 4 }

        let store = DownloadStore(baseDirectory: directory)
        #expect(store.requiresSchemaUpgrade)
        let (manager, session) = makeManager(store: store)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await waitUntil { manager.startupRecoveryState == .ready })

        // Kept rows survive; removed rows were handed to Delete before `.ready` was observable.
        #expect(store.record(for: complete) != nil)
        #expect(store.record(for: pausedStatic) != nil)
        for removed in [pausedLive, failed, queued] {
            #expect(!store.attemptAdmitsWork(removed), "handed to Delete before ready")
        }
        #expect(await waitUntil {
            [pausedLive, failed, queued].allSatisfy { store.record(for: $0) == nil }
        })
        #expect(manager.upgradeNotice?.retiredCount == 3)
        #expect(!store.requiresSchemaUpgrade)
        guard case .committed = await store.flushPersistence(timeout: 5) else {
            Issue.record("Expected the stamp to commit"); return
        }
        #expect(try schemaVersion(directory) == 5)

        // A v5 relaunch runs no pass and keeps the notice until it is dismissed.
        let reloaded = DownloadStore(baseDirectory: directory)
        #expect(!reloaded.requiresSchemaUpgrade)
        let authority = store.durableCleanupAuthorityDirectory
        #expect(DownloadUpgradeNotice.load(from: authority)?.retiredCount == 3)
        manager.dismissUpgradeNotice()
        #expect(manager.upgradeNotice == nil)
        #expect(DownloadUpgradeNotice.load(from: authority) == nil)
    }

    @Test("A repeated pass counts each removal once")
    func noticeUnionIsIdempotent() throws {
        let directory = try makeDirectory("notice")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        var notice = DownloadUpgradeNotice()
        notice.retiredAttemptIDs.formUnion(["a", "b"])
        #expect(notice.save(to: directory))
        var again = DownloadUpgradeNotice.load(from: directory) ?? DownloadUpgradeNotice()
        again.retiredAttemptIDs.formUnion(["b"])
        #expect(again.save(to: directory))
        #expect(DownloadUpgradeNotice.load(from: directory)?.retiredCount == 2)
    }

    @Test("A failed durable notice save is carried to the next load; shared legacy IDs count twice")
    func noticeSurvivesFailedSaveAndCountsFullKeys() throws {
        let directory = try makeDirectory("notice-fail")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let defaults = try #require(UserDefaults(suiteName: "notice-\(UUID().uuidString)"))
        let shared = DownloadAttemptID(rawValue: "legacy-shared")!
        var notice = DownloadUpgradeNotice()
        notice.retiredAttemptIDs = [
            DownloadUpgradeNotice.entry(for: DownloadAttemptKey(ratingKey: "plex:a", attemptID: shared)),
            DownloadUpgradeNotice.entry(for: DownloadAttemptKey(ratingKey: "plex:b", attemptID: shared)),
        ]
        #expect(notice.retiredCount == 2)

        // An authority "directory" that is a file makes the durable save fail.
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocked)
        #expect(!notice.save(to: blocked))
        notice.saveFallback(defaults)
        #expect(DownloadUpgradeNotice.load(from: directory, fallback: defaults)?.retiredCount == 2)

        // The next durable save absorbs the fallback.
        let merged = try #require(DownloadUpgradeNotice.load(from: directory, fallback: defaults))
        #expect(merged.save(to: directory))
        DownloadUpgradeNotice.clearFallback(defaults)
        #expect(DownloadUpgradeNotice.load(from: directory, fallback: defaults)?.retiredCount == 2)
    }

    // MARK: - Fixtures

    private func seed(_ ratingKey: String, status: DownloadStatus, mode: DownloadResumeMode,
                      in store: DownloadStore) throws -> DownloadAttemptKey {
        let id = DownloadAttemptID(uuid: UUID())
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: id)
        let url = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        let terminal = status == .complete || status == .unverified
        if terminal { try Data([1]).write(to: url) }
        var metadata = OfflineMetadata(ratingKey: ratingKey, title: "Item", type: "movie")
        metadata.resumeMode = mode
        let record = DownloadRecord(
            ratingKey: ratingKey, attemptID: id, title: "Item", localURL: url,
            bytes: terminal ? 1 : 0, progress: terminal ? 1 : 0, status: status,
            metadata: metadata)
        #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
        return key
    }

    private func schemaVersion(_ directory: URL) throws -> Int? {
        let data = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"]
            as? Int
    }

    private func rewriteEnvelope(_ directory: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let url = directory.appendingPathComponent("index.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func makeManager(store: DownloadStore) -> (DownloadManager, BackgroundDownloadSession) {
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        let appModel = AppModel(identity: PlatformClientIdentity.make(
            clientIdentifier: "schema-upgrade-\(UUID().uuidString)"), activeBackend: .jellyfin)
        appModel.serverBaseURL = nil
        appModel.serverToken = nil
        appModel.jellyfinServerBaseURL = nil
        appModel.jellyfinAccessToken = nil
        appModel.jellyfinUserID = nil
        appModel.embyServerBaseURL = nil
        appModel.embyAccessToken = nil
        appModel.embyUserID = nil
        let manager = DownloadManager(
            appModel: appModel, store: store, session: session,
            cleanupIntentJournal: DownloadCleanupIntentJournal(
                directory: store.durableCleanupAuthorityDirectory),
            registerForBackgroundEvents: false)
        return (manager, session)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-upgrade-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
