#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

@Suite("P6 session checkpoint responsiveness", .serialized)
struct P6SessionCheckpointTests {
    @Test("A held checkpoint leaves delivery free, expires its waiter, and rejects a later halt",
          arguments: ["normal", "deadline", "halt"])
    func delegateHeartbeat(action: String) async throws {
        let fixture = try P6Fixture()
        let hold = P6Hold()
        let live = DownloadStaticCheckpointFilesystem.live
        let store = fixture.store(checkpoint: .init(exists: live.exists,
            size: { url in hold.hit(); return live.size(url) }, durableCopy: live.durableCopy))
        let key = try fixture.seed(store)
        _ = try fixture.working(store, key)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [P6CheckpointURLProtocol.self],
            wakeBudget: .init(wholeWake: 25, operation: action == "deadline" ? 0.25 : 20, persistenceReserve: 5))
        defer { hold.release.signal(); session.invalidateInjectedSessionForTesting() }
        let settled = DispatchSemaphore(value: 0)
        let errors = Mutex(0)
        session.onError = { _, _ in errors.withLock { $0 += 1 } }
        session.checkpointDidResolveForTesting = { settled.signal() }
        _ = await withCheckedContinuation { continuation in
            session.activateCurrentStore { continuation.resume(returning: $0) }
        }
        try session.start(ratingKey: key.ratingKey, from: URL(string: "https://example.invalid/body")!,
                          expectedBytes: 100, byteRangeCheckpoint: true)
        try #require(await p6Signal(P6CheckpointURLProtocol.started))
        hold.arm()
        let heartbeat = DispatchSemaphore(value: 0)
        await session.deliverSystemCancellationForP6Testing { heartbeat.signal() }
        try #require(await p6Signal(hold.entered))
        #expect(await p6Signal(heartbeat))
        if action == "halt" { session.haltForPendingDeletion(attemptKey: key) }
        if action == "deadline" {
            #expect(await p6Signal(settled)) // physical worker is still held
            #expect(store.ownsAttempt(key))
            #expect(errors.withLock { $0 } == 0)
        }
        hold.release.signal()
        if action != "deadline" { try #require(await p6Signal(settled)) }
        await store.drainArtifactWorkerForP6Testing()
        #expect(errors.withLock { $0 } == (action == "normal" ? 1 : 0))
        _ = await store.flushLifecycleAndPersistence(through: store.currentPersistenceTicket(),
            artifactWatermark: store.currentArtifactLifecycleWatermark(), timeout: 2)
    }

    @Test("Incomplete published-body revalidation leaves a MainActor heartbeat free")
    func mainActorHeartbeat() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        var row = fixture.record(status: .unverified)
        row.metadata?.sourcePartSize = 100
        try #require(initial.createAttemptOwnedRecord(row, attemptID: row.attemptID!) ==
            .committed(.init(ratingKey: row.ratingKey, attemptID: row.attemptID!)))
        try Data([1, 2, 3]).write(to: row.localURL)
        let hold = P6Hold()
        let live = DownloadStaticCheckpointFilesystem.live
        let store = fixture.store(checkpoint: .init(exists: live.exists,
            size: { url in hold.hit(); return live.size(url) }, durableCopy: live.durableCopy))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { hold.release.signal(); session.invalidateInjectedSessionForTesting() }
        let settled = DispatchSemaphore(value: 0)
        session.checkpointDidResolveForTesting = { settled.signal() }
        let heartbeat = DispatchSemaphore(value: 0)
        hold.arm()
        Task { @MainActor in
            _ = session.revalidateCompletedDownload(ratingKey: row.ratingKey, validationLabel: "p6-checkpoint")
            heartbeat.signal()
        }
        try #require(await p6Signal(hold.entered))
        #expect(await p6Signal(heartbeat))
        hold.release.signal()
        try #require(await p6Signal(settled))
        _ = await store.flushLifecycleAndPersistence(through: store.currentPersistenceTicket(),
            artifactWatermark: store.currentArtifactLifecycleWatermark(), timeout: 2)
    }
}

private final class P6CheckpointURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static let started = DispatchSemaphore(value: 0)
    override func startLoading() { Self.started.signal() }
    override func stopLoading() {}
}
#endif
