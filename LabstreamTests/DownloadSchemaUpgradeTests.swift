#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// P3b pins: a v4 index stays v4 on disk until the upgrade stamps it, every snapshot after the
/// stamp is v5, and the stamp fills `migratedUnknown` only where no reason exists.
@Suite("Download schema upgrade", .serialized)
struct DownloadSchemaUpgradeTests {
    @Test("A new index is written as v5 and needs no upgrade")
    func freshIndexIsCurrent() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            _ = try seed("plex:new", status: .complete, in: store)
            #expect(!store.requiresSchemaUpgrade)
            #expect(try schemaVersion(directory) == 5)
        }
    }

    @Test("A v4 index keeps writing v4 until the stamp, then every snapshot is v5")
    func v4StaysV4UntilStamped() async throws {
        try await withAsyncDirectory { directory in
            let first = DownloadStore(baseDirectory: directory)
            _ = try seed("plex:a", status: .complete, in: first)
            try rewriteEnvelope(directory) { $0["schemaVersion"] = 4 }

            let store = DownloadStore(baseDirectory: directory)
            #expect(store.requiresSchemaUpgrade)
            // An ordinary write before the stamp keeps the loaded version.
            _ = try seed("plex:b", status: .complete, in: store)
            #expect(try schemaVersion(directory) == 4)

            let ticket = store.stampSchemaV5()
            guard case .committed = await store.flushPersistence(through: ticket, timeout: 5) else {
                Issue.record("Expected the stamp to commit"); return
            }
            #expect(try schemaVersion(directory) == 5)
            #expect(!store.requiresSchemaUpgrade)
            _ = try seed("plex:c", status: .complete, in: store)
            #expect(try schemaVersion(directory) == 5)

            let reloaded = DownloadStore(baseDirectory: directory)
            #expect(!reloaded.requiresSchemaUpgrade)
            #expect(reloaded.record(for: "plex:a")?.status == .complete)
        }
    }

    @Test("The stamp fills migratedUnknown only for unverified rows without a reason")
    func stampFillsMissingUnverifiedReasons() async throws {
        try await withAsyncDirectory { directory in
            let first = DownloadStore(baseDirectory: directory)
            let bare = try seed("plex:bare", status: .unverified, in: first)
            let reasoned = try seed("plex:reasoned", status: .downloading, in: first)
            _ = first.submitLifecycleEvent(.bodyAtWorking, for: reasoned,
                                           facts: DownloadRowFacts(route: .staticRange))
            let source = try #require(first.truncationSourceKey(for: reasoned))
            _ = first.submitLifecycleEvent(
                .finalizeOutcome(id: "miss", outcome: .unverified(reason: "probe_timeout"),
                                 source: source), for: reasoned)
            _ = first.submitLifecycleEvent(.promotionCommitted(.unverified), for: reasoned,
                                           facts: DownloadRowFacts(route: .staticRange))
            guard case .committed = await first.flushPersistence(timeout: 5) else {
                Issue.record("Expected the seed to commit"); return
            }
            try rewriteEnvelope(directory) { $0["schemaVersion"] = 4 }

            let store = DownloadStore(baseDirectory: directory)
            let ticket = store.stampSchemaV5()
            _ = await store.flushPersistence(through: ticket, timeout: 5)
            #expect(store.lifecycleState(for: bare)?.history.unverifiedReason == .migratedUnknown)
            if store.lifecycleState(for: reasoned)?.lifecycle == .unverified {
                #expect(store.lifecycleState(for: reasoned)?.history.unverifiedReason
                        == .probeMiss("probe_timeout"))
            }
        }
    }

    @Test("A row-deletion barrier or a capsule admits no work; a healthy owner does")
    func deletingRowsAdmitNoWork() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let healthy = try seed("plex:ok", status: .downloading, in: store)
            #expect(store.attemptAdmitsWork(healthy))

            let capsule = try seed("plex:capsule", status: .downloading, in: store)
            let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
                baseURL: URL(string: "https://emby.example")!,
                serverID: "server-1", userID: "user-1"))
            let cleanup = try #require(DurableDownloadCleanupIntent(
                id: UUID(), attemptKey: capsule, backend: .emby, server: server,
                operation: .activeEncoding(playSessionID: "session-1")))
            #expect(store.markDeletionPending(for: capsule, cleanupIntents: [cleanup]) == .applied)
            #expect(store.ownsAttempt(capsule), "a capsule keeps row and file authority")
            #expect(!store.attemptAdmitsWork(capsule))

            let barriered = try seed("plex:barrier", status: .downloading, in: store)
            guard case .accepted = store.submitRemove(for: barriered) else {
                Issue.record("Expected the removal to be accepted"); return
            }
            #expect(!store.attemptAdmitsWork(barriered))
        }
    }

    @Test("Start-chain admission accepts fresh starts and A-to-B replacement, never a deleting row")
    func startChainAdmissionIsPhaseAware() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let minted = DownloadAttemptID(uuid: UUID())
            // Fresh start: the key is empty before the seed.
            #expect(store.startChainAdmits(ratingKey: "plex:fresh", attemptID: minted,
                                           expectedPreviousOwner: nil))

            // Replacement: before the seed the expected previous owner holds the key...
            let previous = try seed("plex:replace", status: .failed, in: store)
            let next = DownloadAttemptID(uuid: UUID())
            #expect(store.startChainAdmits(ratingKey: "plex:replace", attemptID: next,
                                           expectedPreviousOwner: previous.attemptID))
            // ...but an unexpected owner is refused.
            #expect(!store.startChainAdmits(ratingKey: "plex:replace", attemptID: next,
                                            expectedPreviousOwner: DownloadAttemptID(uuid: UUID())))
            // After the seed the exact attempt must admit work.
            let seeded = DownloadAttemptKey(ratingKey: "plex:replace", attemptID: next)
            #expect(store.createAttemptOwnedRecord(
                DownloadRecord(ratingKey: "plex:replace", attemptID: next, title: "Item",
                               localURL: URL(fileURLWithPath: "/dev/null"), status: .queued,
                               metadata: OfflineMetadata(ratingKey: "plex:replace",
                                                         title: "Item", type: "movie")),
                attemptID: next, replacing: previous.attemptID) == .committed(seeded))
            #expect(store.startChainAdmits(ratingKey: "plex:replace", attemptID: next,
                                           expectedPreviousOwner: previous.attemptID))

            // A previous owner that is being deleted never seeds a replacement.
            let deleting = try seed("plex:deleting", status: .failed, in: store)
            guard case .accepted = store.submitRemove(for: deleting) else {
                Issue.record("Expected the removal to be accepted"); return
            }
            #expect(!store.startChainAdmits(ratingKey: "plex:deleting",
                                            attemptID: DownloadAttemptID(uuid: UUID()),
                                            expectedPreviousOwner: deleting.attemptID))
        }
    }

    @Test("Deletion matches an OS task by the full key, never by attempt ID alone")
    func deletionMatchesTasksByFullKey() {
        let shared = DownloadAttemptID(rawValue: "legacy-shared-id")!
        let mine = DownloadAttemptKey(ratingKey: "plex:mine", attemptID: shared)
        let other = DownloadAttemptKey(ratingKey: "plex:other", attemptID: shared)
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/a")!)
        defer { task.cancel() }
        task.taskDescription = DownloadAttemptMarker.taskDescription(
            ratingKey: mine.ratingKey, attemptID: mine.attemptID)
        #expect(BackgroundDownloadSession.taskCarries(mine, task))
        #expect(!BackgroundDownloadSession.taskCarries(other, task))
        let segment = URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/b")!)
        defer { segment.cancel() }
        segment.taskDescription = StaticRangeSegmentMarker.taskDescription(
            ratingKey: mine.ratingKey, offset: 0, attemptID: mine.attemptID)
        #expect(BackgroundDownloadSession.taskCarries(mine, segment))
        #expect(!BackgroundDownloadSession.taskCarries(other, segment))
    }

    @Test("A season plan never re-plans a row that is being deleted")
    func seasonPlanRefusesDeletingRetryRow() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let retry = try seed("plex:season-retry", status: .failed, in: store)
            guard case .accepted = store.submitRemove(for: retry) else {
                Issue.record("Expected the removal to be accepted"); return
            }
            let inserted = DownloadRecord(
                ratingKey: "plex:season-new", attemptID: .generated(), title: "New",
                localURL: directory.appendingPathComponent("new.mp4"), status: .queued,
                metadata: OfflineMetadata(ratingKey: "plex:season-new", title: "New",
                                          type: "episode", seasonPlannerPendingAdmission: true))
            #expect(store.applySeasonPlanAtomically(
                newRecords: [inserted], retryAttempts: [retry]) == .staleInput)
            #expect(store.record(for: "plex:season-new") == nil, "the transaction stays atomic")
        }
    }

    @Test("Upgrade candidates: keep finished and paused static; skip rows already being deleted")
    func upgradeCandidateMatrix() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let complete = try seed("plex:complete", status: .complete, in: store)
            let pausedStatic = try seed("plex:paused-static", status: .paused,
                                        mode: .staticByteRange, in: store)
            let pausedLive = try seed("jellyfin:paused-live", status: .paused,
                                      mode: .liveForwardOnly, in: store)
            let failed = try seed("plex:failed", status: .failed, in: store)
            let barriered = try seed("plex:barriered", status: .failed, in: store)
            guard case .accepted = store.submitRemove(for: barriered) else {
                Issue.record("Expected the removal to be accepted"); return
            }
            let candidates = Set(store.schemaUpgradeCandidates())
            #expect(candidates == [pausedLive, failed])
            #expect(!candidates.contains(complete) && !candidates.contains(pausedStatic))
        }
    }

    @Test("A crash after barriers commit but before the stamp reclassifies what remains")
    func crashBeforeStampReclassifies() async throws {
        try await withAsyncDirectory { directory in
            let first = DownloadStore(baseDirectory: directory)
            let failed = try seed("plex:failed", status: .failed, in: first)
            let queued = try seed("plex:queued", status: .queued, in: first)
            guard case .committed = await first.flushPersistence(timeout: 5) else {
                Issue.record("Expected the seed to commit"); return
            }
            try rewriteEnvelope(directory) { $0["schemaVersion"] = 4 }

            // The pass barriers one row, the barrier commits as v4, then the process dies.
            let interrupted = DownloadStore(baseDirectory: directory)
            #expect(interrupted.requiresSchemaUpgrade)
            guard case .accepted = interrupted.submitRemove(for: failed) else {
                Issue.record("Expected the removal to be accepted"); return
            }
            _ = await interrupted.flushPersistence(timeout: 5)
            #expect(try schemaVersion(directory) == 4)

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.requiresSchemaUpgrade)
            #expect(Set(relaunched.schemaUpgradeCandidates()) == [queued],
                    "a barriered row is finished by v4 recovery, not re-counted")
        }
    }

    @Test("A pre-P3a v4 row without lifecycle fields is classified structurally")
    func prePhaseThreeRowsClassifyStructurally() throws {
        try withDirectory { directory in
            let first = DownloadStore(baseDirectory: directory)
            let paused = try seed("jellyfin:legacy", status: .paused, mode: .liveForwardOnly,
                                  in: first)
            try rewriteEnvelope(directory) { envelope in
                envelope["schemaVersion"] = 4
                if var rows = envelope["rows"] as? [[String: Any]] {
                    for index in rows.indices {
                        rows[index].removeValue(forKey: "lifecycle")
                        rows[index].removeValue(forKey: "history")
                    }
                    envelope["rows"] = rows
                }
            }
            let store = DownloadStore(baseDirectory: directory)
            #expect(store.requiresSchemaUpgrade)
            #expect(store.schemaUpgradeCandidates() == [paused])
        }
    }

    // MARK: - Fixtures

    private func seed(_ ratingKey: String, status: DownloadStatus,
                      in store: DownloadStore) throws -> DownloadAttemptKey {
        try seed(ratingKey, status: status, mode: .staticByteRange, in: store)
    }

    private func seed(_ ratingKey: String, status: DownloadStatus, mode: DownloadResumeMode,
                      in store: DownloadStore) throws -> DownloadAttemptKey {
        let id = DownloadAttemptID(uuid: UUID())
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: id)
        let url = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        let terminal = status == .complete || status == .unverified
        if terminal { try Data([1]).write(to: url) }
        let record = DownloadRecord(
            ratingKey: ratingKey, attemptID: id, title: "Item", localURL: url,
            bytes: terminal ? 1 : 0, progress: terminal ? 1 : 0, status: status,
            metadata: {
                var metadata = OfflineMetadata(ratingKey: ratingKey, title: "Item", type: "movie")
                metadata.resumeMode = mode
                return metadata
            }())
        #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
        return key
    }

    private func schemaVersion(_ directory: URL) throws -> Int? {
        let data = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["schemaVersion"] as? Int
    }

    private func rewriteEnvelope(_ directory: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let url = directory.appendingPathComponent("index.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func withAsyncDirectory(_ body: (URL) async throws -> Void) async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-upgrade-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try await body(directory)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-upgrade-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(directory)
    }
}
#endif
