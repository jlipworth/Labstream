#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// P3a manager conversion pins: DownloadManager status writes go through reducer events, so the
/// row records why it paused or failed, not only the visible status. No network: every backend
/// lane is signed out, so each path stops at its local decision.
@MainActor
@Suite("Manager lifecycle events", .downloadTestFiles, .serialized)
struct ManagerLifecycleEventTests {
    @Test("A user pause through the manager records the user cause")
    func userPauseRecordsUserCause() async throws {
        let directory = try makeDirectory("user-pause")

        let store = DownloadTestFiles.store(baseDirectory: directory)
        let (manager, session) = makeManager(store: store)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await manager.awaitStartupRecoveryForTesting())
        manager.setQueuePausedForTesting(false)
        // Seed after startup reconcile, which would otherwise fail a task-less active row.
        let key = try seedPlexPrepRow(in: store)
        manager.refreshRecords()

        manager.pause(ratingKey: key.ratingKey)

        let state = try #require(store.lifecycleState(for: key))
        #expect(state.lifecycle == .paused)
        #expect(state.history.pauseCause == .user)
        #expect(store.record(for: key)?.status == .paused)
    }

    @Test("Pause leaves a finalizing body and its finalizer alone")
    func pauseLeavesFinalizingBodyAlone() async throws {
        let directory = try makeDirectory("pause-finalizing")

        let store = DownloadTestFiles.store(baseDirectory: directory)
        let (manager, session) = makeManager(store: store)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await manager.awaitStartupRecoveryForTesting())
        manager.setQueuePausedForTesting(false)
        let key = try seedPlexPrepRow(in: store)
        _ = store.submitLifecycleEvent(.bodyAtWorking, for: key,
                                       facts: DownloadRowFacts(route: .plexPrep))
        #expect(store.lifecycleState(for: key)?.lifecycle == .finalizing)
        let finalizer = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
        defer { finalizer.cancel() }
        let token = manager.downloadWorkRegistry.register(finalizer, for: key, kind: .finalizer)
        defer { _ = manager.downloadWorkRegistry.complete(key: key, token: token) }
        manager.refreshRecords()

        manager.pause(ratingKey: key.ratingKey)

        #expect(store.lifecycleState(for: key)?.lifecycle == .finalizing)
        #expect(!finalizer.isCancelled, "the finalizer publishes the finished body")
        #expect(manager.downloadWorkRegistry.snapshot().attempts
            .first(where: { $0.key == key })?.entries.map(\.kind) == [.finalizer])
    }

    @Test("A queue-paused refresh parks an unattached prep row with the queue cause")
    func queuePausedRefreshRecordsQueueCause() async throws {
        let directory = try makeDirectory("queue-pause")

        let store = DownloadTestFiles.store(baseDirectory: directory)
        let (manager, session) = makeManager(store: store)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await manager.awaitStartupRecoveryForTesting())
        let key = try seedPlexPrepRow(in: store)
        manager.setQueuePausedForTesting(true)
        defer { manager.setQueuePausedForTesting(false) }

        manager.refreshRecords()

        let state = try #require(store.lifecycleState(for: key))
        #expect(state.lifecycle == .paused)
        #expect(state.history.pauseCause == .queuePaused)
    }

    @Test("A retry refused for a signed-out lane records an auth failure")
    func rejectedRetryRecordsAuthFailure() async throws {
        let directory = try makeDirectory("retry-auth")

        let store = DownloadTestFiles.store(baseDirectory: directory)
        let (manager, session) = makeManager(store: store)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await manager.awaitStartupRecoveryForTesting())
        manager.setQueuePausedForTesting(false)
        let key = try seedJellyfinForwardOnlyRow(in: store, seasonPlanned: false)
        #expect(store.lifecycleState(for: key)?.history.lastFailure == nil)
        manager.refreshRecords()

        manager.retry(ratingKey: key.ratingKey)

        #expect(await waitUntil { store.lifecycleState(for: key)?.history.lastFailure == .auth })
        #expect(store.lifecycleState(for: key)?.lifecycle == .failed)
        #expect(manager.lastError[key.ratingKey] == .notAuthenticated)
    }

    /// P4: a failed season row the planner queued waits as a failed row with a retry request.
    /// Admission runs its Retry; with the lane signed out that is a definitive refusal, which
    /// fails it as auth and ends the request (no re-admission loop).
    @Test("Admitting a waiting retry row runs Retry; a refusal fails it as auth and stops waiting")
    func plannedSeasonRowAdmissionRunsRetry() async throws {
        let directory = try makeDirectory("season-planned")

        let store = DownloadTestFiles.store(baseDirectory: directory)
        let (manager, session) = makeManager(store: store)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await manager.awaitStartupRecoveryForTesting())
        manager.setQueuePausedForTesting(false)
        let key = try seedJellyfinForwardOnlyRow(in: store, seasonPlanned: true)
        try #require(store.lifecycleState(for: key)?.lifecycle == .failed)
        #expect(store.record(for: key)?.admissionIntent == .retryRequested)
        manager.refreshRecords()

        manager.scheduleSeasonPlannerAdmission()

        #expect(await waitUntil { store.lifecycleState(for: key)?.history.lastFailure == .auth })
        #expect(await waitUntil { manager.admission.supervised.isEmpty })
        #expect(store.lifecycleState(for: key)?.lifecycle == .failed)
        #expect(store.record(for: key)?.status == .failed)
        #expect(store.record(for: key)?.admissionIntent == nil)
        #expect(store.metadata(for: key.ratingKey)?.seasonPlannerPendingAdmission == nil)
    }

    // MARK: - Fixtures

    @Test("Stale session error and rebuild callbacks cannot act on the current row (P5 pin 11)")
    func staleSessionCallbacksAreIgnored() async throws {
        let directory = try makeDirectory("stale-callback")

        let store = DownloadTestFiles.store(baseDirectory: directory)
        let (manager, session) = makeManager(store: store)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await manager.awaitStartupRecoveryForTesting())
        let key = try seedPlexPrepRow(in: store)
        let stale = DownloadAttemptKey(ratingKey: key.ratingKey, attemptID: .init(uuid: UUID()))
        let before = store.lifecycleState(for: key)
        session.onError?(stale, .storageFull)
        session.onRangeRequestNeeded?(stale, .requestRebuildNeeded,
            .init(attemptKey: stale, trainEpoch: 0, generation: 0))
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.lastError[key.ratingKey] == nil)
        #expect(store.lifecycleState(for: key) == before)
        // Exact ownership still delivers the presentation callback.
        session.onError?(key, .storageFull)
        #expect(await waitUntil { manager.lastError[key.ratingKey] == .storageFull })
    }

    @Test("A same-attempt rebuild queued before Pause cannot requeue the paused row (P5 after-review 1)")
    func pausedSessionRebuildCallbackIsIgnored() async throws {
        let directory = try makeDirectory("paused-rebuild-callback")

        let store = DownloadTestFiles.store(baseDirectory: directory)
        let (manager, session) = makeManager(store: store)
        defer { session.invalidateInjectedSessionForTesting() }
        #expect(await manager.awaitStartupRecoveryForTesting())
        manager.setQueuePausedForTesting(false)
        let key = DownloadAttemptKey(ratingKey: "plex:callback", attemptID: .init(uuid: UUID()))
        let record = DownloadRecord(ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Item",
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"), status: .queued,
            metadata: OfflineMetadata(ratingKey: key.ratingKey, title: "Item", type: "movie",
                sourcePartSize: 1_024, backendKind: .plex, resumeMode: .staticByteRange))
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        let currency = BackgroundDownloadSession.DelayedRangeRetryCurrency(
            attemptKey: key, trainEpoch: 0, generation: 0)
        // The callback queues its MainActor Task; Pause wins before this actor yields to it.
        session.onRangeRequestNeeded?(key, .serverAuthorizationRejected, currency)
        #expect(manager.pause(OfflineDownloadRowActionIdentity(ratingKey: key.ratingKey, attemptID: key.attemptID)))
        #expect(store.record(for: key)?.status == .paused)
        #expect(!manager.hasPendingStaticRangeResumes)
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.record(for: key)?.status == .paused)
        #expect(!manager.hasPendingStaticRangeResumes)
    }

    /// A Plex optimize row still in server prep: queued, no bytes, no poller.
    private func seedPlexPrepRow(in store: DownloadStore) throws -> DownloadAttemptKey {
        let key = DownloadAttemptKey(ratingKey: "plex:201", attemptID: DownloadAttemptID(uuid: UUID()))
        let metadata = OfflineMetadata(
            ratingKey: key.ratingKey, title: "Item", type: "movie",
            optimizeTargetName: "Medium", optimizeQueueTitle: "Item [Labstream abcd1234]",
            backendKind: .plex, backendBaseURLString: "https://plex.example.internal:32400",
            backendServerID: "machine-1", downloadLane: .optimize,
            resumeMode: .serverPrepThenStatic)
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Item",
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"),
            status: .queued, metadata: metadata)
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        #expect(store.lifecycleState(for: key)?.lifecycle == .admitted)
        return key
    }

    private func seedJellyfinForwardOnlyRow(
        in store: DownloadStore, seasonPlanned: Bool
    ) throws -> DownloadAttemptKey {
        let key = DownloadAttemptKey(
            ratingKey: "jellyfin:item-1", attemptID: DownloadAttemptID(uuid: UUID()))
        var metadata = OfflineMetadata(
            ratingKey: key.ratingKey, title: "Episode", type: "episode",
            backendKind: .jellyfin, backendBaseURLString: "https://jellyfin.example",
            backendServerID: "server-1", backendUserID: "user-1",
            downloadLane: .optimize, resumeMode: .liveForwardOnly)
        if seasonPlanned { metadata.seasonPlannerPendingAdmission = true }
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Episode",
            localURL: store.destinationURL(ratingKey: key.ratingKey, ext: "mp4"),
            status: .failed, metadata: metadata)
        #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        return key
    }

    private func makeManager(store: DownloadStore) -> (DownloadManager, BackgroundDownloadSession) {
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        let appModel = AppModel(identity: PlatformClientIdentity.make(
            clientIdentifier: "manager-lifecycle-\(UUID().uuidString)"), activeBackend: .jellyfin)
        // Every lane signed out: no path may reach the network.
        appModel.serverBaseURL = nil
        appModel.serverToken = nil
        appModel.jellyfinServerBaseURL = nil
        appModel.jellyfinAccessToken = nil
        appModel.jellyfinUserID = nil
        appModel.embyServerBaseURL = nil
        appModel.embyAccessToken = nil
        appModel.embyUserID = nil
        let manager = DownloadTestFiles.manager(
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
        let parent = DownloadTestFiles.temporaryDirectory
            .appendingPathComponent("manager-lifecycle-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
