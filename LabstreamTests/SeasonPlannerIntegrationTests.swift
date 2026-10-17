#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct SeasonPlannerIntegrationTests {
    private let events = TestEvents()
    enum Change: CaseIterable { case deleteCurrent, deleteCurrentError, deleteLater, pauseCurrent, unchanged }

    @Test(arguments: Change.allCases)
    func persistedSeasonAdmissionHonorsDeletionDuringRealMetadataRequest(change: Change) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("season-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = "\(UUID().uuidString.lowercased()).season.test.invalid"
        let gate = SeasonMetadataGate(events: events)
        SeasonMetadataProtocol.register(host: host, gate: gate)
        defer { SeasonMetadataProtocol.unregister(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeasonMetadataProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let identity = PlatformClientIdentity.make(clientIdentifier: "season-integration")
        let model = AppModel(identity: identity, token: "fixture-token",
                             client: PlexClient(session: transport, identity: identity))
        model.serverToken = "fixture-token"
        model.serverBaseURL = URL(string: "https://\(host)")
        let events = self.events
        let store = DownloadStore(baseDirectory: directory, indexPersistence: .init { data, url in
            try DownloadIndexFileCommitter().commit(data, to: url)
            events.signal()
        })
        let session = BackgroundDownloadSession(store: store, protocolClasses: [SeasonMetadataProtocol.self])
        let manager = DownloadManager(appModel: model, store: store, session: session,
                                      registerForBackgroundEvents: false)
        manager.setQueuePausedForTesting(false)
        defer {
            manager.admissionPumpTask?.cancel()
            session.invalidateInjectedSessionForTesting()
        }
        try #require(await manager.awaitStartupRecoveryForTesting())
        let ids = change == .deleteLater ? ["episode-1", "episode-2"] : ["episode-1"]
        let plans = try ids.map { id in
            SeasonEpisodeDownloadPlan(
                item: try JSONDecoder().decode(MediaItem.self, from: SeasonMetadataGate.itemData(id)),
                backend: .plex, choice: .existingVersion, mediaIndex: 0, partIndex: 0,
                audioStreamIndex: nil, mediaSourceIDOverride: nil, estimatedBytes: 100, shouldStart: true)
        }
        let result = await manager.commitSeasonPlan(.init(newPlans: plans, retryAttempts: []))
        #expect(result.succeeded)
        #expect(result.added == ids.count)
        // Every admitted row refreshes concurrently (#362): both static episodes fit the
        // two-row static lane, so both metadata requests are in flight at once.
        try #require(await waitUntil { gate.heldIDs.count == ids.count })
        let first = try #require(gate.heldID)
        let original = try #require(store.record(for: first)?.attemptID)
        let deleted: String?
        switch change {
        case .deleteCurrent, .deleteCurrentError: deleted = first
        case .deleteLater: deleted = try #require(ids.first { $0 != first })
        default: deleted = nil
        }
        if let deleted {
            manager.delete(ratingKey: deleted)
            try #require(await waitUntil {
                store.record(for: deleted) == nil && !store.isDeletionPending(ratingKey: deleted)
            })
            // Row removal precedes the artifact worker's terminal index commit. In-memory
            // absence is not a durability barrier; await the already-submitted revision
            // before asking a fresh store to prove deletion survived reopening.
            let deletionTicket = store.currentPersistenceTicket()
            let flush = await store.flushPersistence(through: deletionTicket, timeout: 10)
            guard case .committed(let revision) = flush else {
                Issue.record("Deletion snapshot did not commit: \(flush)")
                return
            }
            #expect(revision >= deletionTicket.revision)
            // A newly opened index must agree before the suspended response is released.
            #expect(DownloadStore(baseDirectory: directory).record(for: deleted) == nil)
        }
        if change == .pauseCurrent {
            let row = OfflineDownloadRowActionIdentity(ratingKey: first, attemptID: original)
            #expect(manager.pause(row))
            #expect(store.record(for: first)?.status == .paused)
        }
        gate.releaseMetadata(id: first, failing: change == .deleteCurrentError)
        if change == .deleteLater, let deleted {
            // The deleted row's refresh was already in flight; its late response must be revoked.
            gate.releaseMetadata(id: deleted, failing: false)
        }
        try #require(await events.wait { _ = manager.records; return manager.admission.supervised.isEmpty })
        if change == .unchanged || change == .deleteLater {
            try #require(await waitUntil { gate.transferPaths.count == 1 })
            #expect(store.record(for: first)?.attemptID != original)
            #expect(Set(gate.metadataIDs) == Set(ids))
            #expect(gate.transferPaths == ["/library/parts/\(first)/file.mp4"])
        } else {
            #expect(gate.transferPaths.isEmpty)
            #expect(manager.activeJobs.isEmpty)
            #expect(gate.metadataIDs == [first])
            if change == .pauseCurrent {
                #expect(store.record(for: first)?.attemptID == original)
                #expect(store.record(for: first)?.status == .paused)
            }
        }
        if let deleted {
            #expect(store.record(for: deleted) == nil)
            #expect(DownloadStore(baseDirectory: directory).record(for: deleted) == nil)
            #expect(!manager.activeJobs.contains(deleted))
        }
        #expect(gate.unexpectedPaths.isEmpty) // No backend negotiation or auxiliary fetch.
        for row in store.records { manager.delete(ratingKey: row.ratingKey) }
        try #require(await waitUntil { store.records.isEmpty })
    }

    /// #362: a long-running admitted start (an Emby Convert or Plex optimize chain does not return
    /// until the server job finishes) must not hold back other admitted rows, and in-flight starts
    /// must still count against lane caps across repeated admission passes.
    @Test func seasonAdmissionStartsRowsConcurrentlyWithinLaneCaps() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("season-concurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = "\(UUID().uuidString.lowercased()).season.test.invalid"
        let gate = SeasonMetadataGate(events: events)
        SeasonMetadataProtocol.register(host: host, gate: gate)
        defer { SeasonMetadataProtocol.unregister(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeasonMetadataProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let identity = PlatformClientIdentity.make(clientIdentifier: "season-concurrency")
        let model = AppModel(identity: identity, token: "fixture-token",
                             client: PlexClient(session: transport, identity: identity))
        model.serverToken = "fixture-token"
        model.serverBaseURL = URL(string: "https://\(host)")
        let events = self.events
        let store = DownloadStore(baseDirectory: directory, indexPersistence: .init { data, url in
            try DownloadIndexFileCommitter().commit(data, to: url)
            events.signal()
        })
        let session = BackgroundDownloadSession(store: store, protocolClasses: [SeasonMetadataProtocol.self])
        let manager = DownloadManager(appModel: model, store: store, session: session,
                                      registerForBackgroundEvents: false)
        manager.setQueuePausedForTesting(false)
        defer {
            manager.admissionPumpTask?.cancel()
            session.invalidateInjectedSessionForTesting()
        }
        try #require(await manager.awaitStartupRecoveryForTesting())
        let ids = ["episode-1", "episode-2", "episode-3"]
        let plans = try ids.map { id in
            SeasonEpisodeDownloadPlan(
                item: try JSONDecoder().decode(MediaItem.self, from: SeasonMetadataGate.itemData(id)),
                backend: .plex, choice: .existingVersion, mediaIndex: 0, partIndex: 0,
                audioStreamIndex: nil, mediaSourceIDOverride: nil, estimatedBytes: 100, shouldStart: true)
        }
        let result = await manager.commitSeasonPlan(.init(newPlans: plans, retryAttempts: []))
        #expect(result.succeeded)
        #expect(result.added == ids.count)

        // The static lane admits two rows at once; their starts run concurrently.
        try #require(await waitUntil { gate.heldIDs.count == 2 })
        let held = gate.heldIDs
        let stuck = held[0]
        let moving = held[1]
        // P4: supervised starts occupy the lane, so later admission passes do not admit the
        // third row while both starts are still running (B72).
        for _ in 0..<3 { manager.pumpAdmission() }
        #expect(Set(manager.admission.supervised.keys) == Set(held))
        #expect(gate.metadataIDs.count == 2)

        // A start that never returns (standing in for a server-prep chain) does not block the
        // other admitted row from reaching its transfer.
        gate.releaseMetadata(id: moving, failing: false)
        try #require(await waitUntil { gate.transferPaths == ["/library/parts/\(moving)/file.mp4"] })
        #expect(gate.heldIDs == [stuck])
        #expect(Set(manager.admission.supervised.keys) == [stuck])
        // Both static slots remain occupied (one transferring, one still starting).
        #expect(gate.metadataIDs.count == 2)

        gate.releaseMetadata(id: stuck, failing: false)
        try #require(await waitUntil { gate.transferPaths.count == 2 })
        try #require(await events.wait { _ = manager.records; return manager.admission.supervised.isEmpty })
        #expect(gate.unexpectedPaths.isEmpty)
        for row in store.records { manager.delete(ratingKey: row.ratingKey) }
        try #require(await waitUntil { store.records.isEmpty })
        // Release any metadata request admitted during teardown so no URLProtocol stays pending.
        while gate.heldID != nil { gate.releaseMetadata(failing: true) }
    }

    // MARK: - P4 admission pins

    private struct Harness {
        let directory: URL
        let host: String
        let gate: SeasonMetadataGate
        let transport: URLSession
        let store: DownloadStore
        let session: BackgroundDownloadSession
        let manager: DownloadManager

        @MainActor func teardown() async {
            for row in store.records { manager.delete(ratingKey: row.ratingKey) }
            while gate.heldID != nil { gate.releaseMetadata(failing: true) }
            manager.admissionPumpTask?.cancel()
            session.invalidateInjectedSessionForTesting()
            transport.invalidateAndCancel()
            SeasonMetadataProtocol.unregister(host: host)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeHarness(_ label: String) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = "\(UUID().uuidString.lowercased()).season.test.invalid"
        let gate = SeasonMetadataGate(events: events)
        SeasonMetadataProtocol.register(host: host, gate: gate)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeasonMetadataProtocol.self]
        let transport = URLSession(configuration: configuration)
        let identity = PlatformClientIdentity.make(clientIdentifier: "admission-\(label)")
        let model = AppModel(identity: identity, token: "fixture-token",
                             client: PlexClient(session: transport, identity: identity))
        model.serverToken = "fixture-token"
        model.serverBaseURL = URL(string: "https://\(host)")
        let events = self.events
        let store = DownloadStore(baseDirectory: directory, indexPersistence: .init { data, url in
            try DownloadIndexFileCommitter().commit(data, to: url)
            events.signal()
        })
        let session = BackgroundDownloadSession(store: store, protocolClasses: [SeasonMetadataProtocol.self])
        let manager = DownloadManager(appModel: model, store: store, session: session,
                                      registerForBackgroundEvents: false)
        manager.setQueuePausedForTesting(false)
        try #require(await manager.awaitStartupRecoveryForTesting())
        return Harness(directory: directory, host: host, gate: gate, transport: transport,
                       store: store, session: session, manager: manager)
    }

    private func plan(_ id: String, choice: DownloadIntentChoice = .existingVersion) throws
        -> SeasonEpisodeDownloadPlan {
        SeasonEpisodeDownloadPlan(
            item: try JSONDecoder().decode(MediaItem.self, from: SeasonMetadataGate.itemData(id)),
            backend: .plex, choice: choice, mediaIndex: 0, partIndex: 0,
            audioStreamIndex: nil, mediaSourceIDOverride: nil, estimatedBytes: 100, shouldStart: true)
    }

    /// A paused static Plex row bound to the fixture's exact Part, so its retry refreshes metadata
    /// and then starts the static transfer.
    private func seedPausedStaticRow(_ id: String, host: String, in store: DownloadStore) async throws {
        let attemptID = DownloadAttemptID.generated()
        let metadata = OfflineMetadata(
            ratingKey: id, title: "Episode fixture", type: "episode", mediaIndex: 0, partIndex: 0,
            sourcePartID: 11, backendKind: .plex, backendBaseURLString: "https://\(host)",
            downloadLane: .original, resumeMode: .staticByteRange, serverPreparedVersion: true)
        let record = DownloadRecord(
            ratingKey: id, attemptID: attemptID, title: "Episode fixture",
            localURL: store.destinationURL(ratingKey: id, ext: "mp4"), status: .paused,
            metadata: metadata)
        #expect(await store.createAttemptOwnedRecordAsync(record, attemptID: attemptID)
            == .committed(DownloadAttemptKey(ratingKey: id, attemptID: attemptID)))
    }

    // MARK: - P5 storage pins

    /// A paused static Plex row with a known 1 000-byte source and `bytes` already on disk.
    private func seedPausedSizedRow(_ id: String, bytes: Int, host: String, in store: DownloadStore,
                                    serverPreparedVersion: Bool = true) async throws -> DownloadAttemptKey {
        let attemptID = DownloadAttemptID.generated()
        let metadata = OfflineMetadata(
            ratingKey: id, title: "Episode fixture", type: "episode", duration: 2_400_000,
            mediaIndex: 0, partIndex: 0, sourcePartID: 11, sourcePartSize: 1_000,
            backendKind: .plex, backendBaseURLString: "https://\(host)",
            downloadLane: .original, resumeMode: .staticByteRange,
            serverPreparedVersion: serverPreparedVersion)
        let record = DownloadRecord(
            ratingKey: id, attemptID: attemptID, title: "Episode fixture",
            localURL: store.destinationURL(ratingKey: id, ext: "mp4"), bytes: bytes,
            status: .paused, metadata: metadata)
        let key = DownloadAttemptKey(ratingKey: id, attemptID: attemptID)
        #expect(await store.createAttemptOwnedRecordAsync(record, attemptID: attemptID) == .committed(key))
        return key
    }

    private func isStorageLimit(_ error: DownloadManager.DownloadError?) -> Bool {
        if case .storageLimitExceeded = error { return true }
        return false
    }

    /// B24 (P5 review 4): the cap counts the larger of the durable checkpoint and `bytes`.
    @Test func capRowsCountTheDurableCheckpointWhenItIsAheadOfBytes() async throws {
        let h = try await makeHarness("cap-checkpoint")
        let key = try await seedPausedSizedRow("episode-1", bytes: 100, host: h.host, in: h.store)
        let working = try #require(h.store.attemptWorkingFileURL(for: key))
        try FileManager.default.createDirectory(at: working.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(count: 600).write(to: working)
        let row = try #require(h.manager.storageCapRows().first { $0.id == "episode-1" })
        #expect(row.retainedBytes == 600)
        await h.teardown()
    }

    /// P5 pin 6: a season commit charges its retried rows' remaining bytes.
    @Test func aSeasonCommitChargesRetriedRowsRemainingBytes() async throws {
        let h = try await makeHarness("season-retry-cap")
        let key = try await seedPausedSizedRow("episode-1", bytes: 100, host: h.host, in: h.store)
        h.manager.refreshRecords()
        h.manager.storageLimitBytesOverrideForTesting = 500
        let expected = try #require(h.manager.storageLimitMessage(adding: 900))
        let result = await h.manager.commitSeasonPlan(.init(newPlans: [], retryAttempts: [key]))
        #expect(result.failureMessage == expected, "refused by the cap, not by anything else")
        #expect(h.gate.metadataIDs.isEmpty, "a refused season never starts the retry")
        // 100 held + 900 remaining fits exactly in 1 000.
        h.manager.storageLimitBytesOverrideForTesting = 1_000
        #expect(h.manager.seasonStorageLimitMessage(newKnownBytes: 0, retryAttempts: [key]) == nil)
        await h.teardown()
    }

    /// P5 review 3: a persisted-blob Resume passes the cap first and keeps its blob on refusal.
    @Test func aBlobResumeOverTheCapIsRefusedAndKeepsItsBlob() async throws {
        let h = try await makeHarness("blob-cap")
        let key = try await seedPausedSizedRow("episode-1", bytes: 100, host: h.host, in: h.store)
        #expect(await h.store.resolve(h.store.submitResumeData(for: key, Data("fixture-blob".utf8)), deadline: .after(30)) == .applied)
        h.manager.refreshRecords()
        h.manager.storageLimitBytesOverrideForTesting = 500
        let record = try #require(h.store.record(for: "episode-1"))
        let task = h.manager.retry(record: record, allowReplacingExistingActiveRow: false)
        await task?.value
        #expect(isStorageLimit(h.manager.lastError["episode-1"]))
        #expect(h.store.resumeData(for: key) != nil, "the blob survives the refusal")
        #expect(h.store.record(for: "episode-1")?.status == .paused)
        await h.teardown()
    }

    /// B41 (P5 pin 4): the validation fallback checks the cap before creating an optimize job.
    @Test func theValidationFallbackChecksTheCapBeforeCreatingAnOptimizeJob() async throws {
        let h = try await makeHarness("fallback-cap")
        _ = try await seedPausedSizedRow("episode-1", bytes: 100, host: h.host, in: h.store,
                                   serverPreparedVersion: false)
        h.manager.refreshRecords()
        h.manager.storageLimitBytesOverrideForTesting = 1_000
        await h.manager.fallbackOriginalValidationFailureIfPossible(ratingKey: "episode-1")
        #expect(isStorageLimit(h.manager.lastError["episode-1"]))
        #expect(!h.manager.activeJobs.contains("episode-1"), "no optimize job was started")
        await h.teardown()
    }

    /// B63 + B72: Resume All queues every parked row and admits only the static cap; the rest
    /// wait with a retry request until a lane frees.
    @Test func resumeAllAdmitsParkedRowsWithinTheStaticLane() async throws {
        let h = try await makeHarness("resume-all")
        let ids = (1...5).map { "episode-\($0)" }
        for id in ids { try await seedPausedStaticRow(id, host: h.host, in: h.store) }
        h.manager.refreshRecords()

        h.manager.resumeQueue()

        try #require(await waitUntil { h.gate.heldIDs.count == 2 })
        for _ in 0..<3 { h.manager.pumpAdmission() }
        #expect(h.gate.metadataIDs.count == 2, "only the static cap starts")
        #expect(h.manager.admission.supervised.count == 2)
        let waiting = h.store.records.filter { $0.admissionIntent == .retryRequested }
        #expect(waiting.count == 3)
        #expect(waiting.allSatisfy { $0.status == .paused })

        // A started row keeps its lane while its transfer is pending; deleting it frees the lane
        // and the next waiting row is admitted.
        let first = try #require(h.gate.heldID)
        h.gate.releaseMetadata(id: first, failing: false)
        try #require(await waitUntil { h.gate.transferPaths.count == 1 })
        #expect(h.gate.metadataIDs.count == 2)
        h.manager.delete(ratingKey: first)
        try #require(await waitUntil { h.gate.metadataIDs.count == 3 })
        await h.teardown()
    }

    /// B67: a season row whose metadata refresh fails (an unreachable server) waits again as
    /// planned and is retried after backoff; it never becomes a failed row.
    @Test func aRefreshOutageDefersAPlannedRowInsteadOfFailingIt() async throws {
        let h = try await makeHarness("refresh-outage")
        let result = await h.manager.commitSeasonPlan(.init(newPlans: [try plan("episode-1")],
                                                            retryAttempts: []))
        #expect(result.succeeded)
        try #require(await waitUntil { h.gate.heldIDs == ["episode-1"] })
        h.gate.releaseMetadata(id: "episode-1", failing: true)
        try #require(await events.wait { _ = h.manager.records; return h.manager.admission.supervised.isEmpty })
        let deferred = try #require(h.store.record(for: "episode-1"))
        #expect(deferred.lifecycle == .planned)
        #expect(deferred.admissionIntent == .seasonPlanned)
        #expect(deferred.status == .queued)
        // Backoff (1 s) then a second refresh.
        try #require(await waitUntil { h.gate.metadataIDs.count == 2 })
        await h.teardown()
    }

    /// P4.3: a tap while the static lane is full waits as a durable planned row (the season seed
    /// shape) and starts when a lane frees.
    @Test func aTapOverCapacityWaitsThenStarts() async throws {
        let h = try await makeHarness("tap-waits")
        let result = await h.manager.commitSeasonPlan(.init(
            newPlans: [try plan("episode-1"), try plan("episode-2")], retryAttempts: []))
        #expect(result.succeeded)
        try #require(await waitUntil { h.gate.heldIDs.count == 2 })

        let item = try JSONDecoder().decode(MediaItem.self, from: SeasonMetadataGate.itemData("episode-3"))
        await h.manager.requestDownload(item, backend: .plex, choice: .existingVersion,
                                        mediaIndex: 0, partIndex: 0, audioStreamIndex: nil)
        let waiting = try #require(h.store.record(for: "episode-3"))
        #expect(waiting.lifecycle == .planned)
        #expect(waiting.admissionIntent == .seasonPlanned)
        #expect(waiting.metadata?.sourcePartID == nil || waiting.metadata?.sourcePartID == 11)
        #expect(DownloadStore(baseDirectory: h.directory).record(for: "episode-3")?.lifecycle
            == .planned, "the waiting tap is durable")
        for _ in 0..<3 { h.manager.pumpAdmission() }
        #expect(h.manager.admission.supervised.count == 2)
        #expect(!h.gate.metadataIDs.contains("episode-3"))

        h.manager.delete(ratingKey: "episode-1")
        try #require(await waitUntil { h.gate.metadataIDs.contains("episode-3") })
        await h.teardown()
    }

    /// B62: the Plex prep scanner never attaches a poller to a planned (waiting) row.
    @Test func thePrepScannerSkipsPlannedRows() async throws {
        let h = try await makeHarness("scanner")
        h.manager.admission.recoveryComplete = false // hold admission closed
        let result = await h.manager.commitSeasonPlan(.init(
            newPlans: [try plan("episode-1", choice: .optimize(targetName: "1080p"))],
            retryAttempts: []))
        #expect(result.succeeded)
        let row = try #require(h.store.record(for: "episode-1"))
        #expect(row.lifecycle == .planned)
        #expect(row.status == .queued)

        h.manager.resumePendingServerPrepDownloads()
        await h.manager.resumePendingEmbyConvertDownloadsAsync()

        #expect(!h.manager.activeJobs.contains("episode-1"))
        #expect(!h.manager.hasRegisteredServerPrepPoller(ratingKey: "episode-1"))
        #expect(h.gate.metadataIDs.isEmpty)
        await h.teardown()
    }

    /// B64/B65: pausing a waiting row parks it at once and keeps its first-start intent; Resume
    /// returns it to planned and it starts through the first-start path.
    @Test func aRowPausedWhileWaitingResumesToPlanned() async throws {
        let h = try await makeHarness("pause-waiting")
        h.manager.admission.recoveryComplete = false
        let result = await h.manager.commitSeasonPlan(.init(newPlans: [try plan("episode-1")],
                                                            retryAttempts: []))
        #expect(result.succeeded)
        let planned = try #require(h.store.record(for: "episode-1"))
        let identity = try #require(planned.attemptID.map {
            OfflineDownloadRowActionIdentity(ratingKey: "episode-1", attemptID: $0)
        })
        #expect(h.manager.pause(identity))
        let paused = try #require(h.store.record(for: "episode-1"))
        #expect(paused.status == .paused)
        #expect(paused.admissionIntent == .seasonPlanned)

        h.manager.admission.recoveryComplete = true
        #expect(h.manager.retry(identity))
        #expect(h.store.record(for: "episode-1")?.lifecycle == .planned)
        try #require(await waitUntil { h.gate.metadataIDs == ["episode-1"] })
        await h.teardown()
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        await events.wait(until: condition)
    }
}

/// Holds actual Plex metadata responses at URLSession's transport boundary, one per episode, so
/// concurrent admissions can be observed and released independently. Transfer requests are
/// observed but kept pending, so tests never need network or media decoding.
private final class SeasonMetadataGate: @unchecked Sendable {
    private let lock = NSLock()
    private let events: TestEvents
    init(events: TestEvents) { self.events = events }
    private var held: [(id: String, request: SeasonMetadataProtocol)] = []
    private var metadata: [String] = []
    private var transfers: [String] = []
    private var unexpected: [String] = []
    /// The first still-held metadata request, in arrival order.
    var heldID: String? { lock.withLock { held.first?.id } }
    var heldIDs: [String] { lock.withLock { held.map(\.id) } }
    var metadataIDs: [String] { lock.withLock { metadata } }
    var transferPaths: [String] { lock.withLock { transfers } }
    var unexpectedPaths: [String] { lock.withLock { unexpected } }

    func receive(_ request: SeasonMetadataProtocol) {
        defer { events.signal() }
        let path = request.request.url!.path
        lock.withLock {
            if path.hasPrefix("/library/metadata/") {
                let id = request.request.url!.lastPathComponent
                metadata.append(id)
                held.append((id, request))
            } else if path.hasPrefix("/library/parts/") {
                transfers.append(path)
            } else {
                unexpected.append(path)
            }
        }
    }
    /// Release one held metadata request (the oldest when `id` is nil).
    func releaseMetadata(id: String? = nil, failing: Bool) {
        let request: SeasonMetadataProtocol? = lock.withLock {
            let index: Int?
            if let id {
                index = held.firstIndex { $0.id == id }
            } else {
                index = held.isEmpty ? nil : 0
            }
            guard let index else { return nil }
            return held.remove(at: index).request
        }
        guard let request, let url = request.request.url else { return }
        if failing {
            request.client?.urlProtocol(request, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        let item = Self.itemData(url.lastPathComponent)
        let data = Data("{\"MediaContainer\":{\"Metadata\":[".utf8) + item + Data("]}}".utf8)
        request.client?.urlProtocol(request, didReceive: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: data)
        request.client?.urlProtocolDidFinishLoading(request)
    }
    static func itemData(_ id: String) -> Data {
        Data("""
        {"ratingKey":"\(id)","key":"/library/metadata/\(id)","title":"Episode fixture","type":"episode",
         "Media":[{"id":1,"container":"mp4","Part":[{"id":11,"key":"/library/parts/\(id)/file.mp4","container":"mp4","size":100}]}]}
        """.utf8)
    }
}

private final class SeasonMetadataProtocol: URLProtocol, @unchecked Sendable {
    private static let gates = TestLockedBox<[String: SeasonMetadataGate]>([:])
    static func register(host: String, gate: SeasonMetadataGate) { gates.withValue { $0[host] = gate } }
    static func unregister(host: String) { gates.withValue { $0.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".season.test.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let gate = Self.gates.value[host] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        gate.receive(self)
    }
    override func stopLoading() {}
}
#endif
