#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

@Suite("P7 checkpoint handoff storage")
struct P7CheckpointHandoffStorageTests {
    @Test("B86 hard-kill residue is swept with startup identity, references and leases intact")
    func hardKillResidueSweepGuards() async throws {
        let fixture = try HandoffStorageFixture()
        let initial = fixture.store()
        let owner = try fixture.seed(initial)
        let checkpoint = try fixture.working(initial, owner, bytes: 3)
        let residue = fixture.temp("b")
        let pending = fixture.temp("c")
        let leased = fixture.temp("d")
        let replaced = fixture.temp("e")
        let explicit = fixture.temp("f")
        let malformed = "..attempt-stage-v1-invalid.stage.checkpoint-" + UUID().uuidString
        for name in [residue, pending, leased, replaced, explicit, malformed] {
            // Model a hard kill directly: throwing from durableCopy would run its defer.
            try Data([7, 8]).write(to: fixture.directory.appendingPathComponent(name))
        }
        try fixture.addPendingCheckpoint(owner: owner, working: checkpoint.lastPathComponent, temp: pending)
        let live = DownloadStaticCheckpointFilesystem.live
        let store = fixture.store(checkpoint: .init(exists: { _ in false }, size: live.size,
            durableCopy: { _, _, _ in throw CocoaError(.fileReadUnknown) }))
        // Failed replay retains its durable recipe but releases its path lease. Preservation of
        // this temp must therefore come from the pending reference, independently of leases.
        await store.drainArtifactWorkerForP6Testing()
        guard case .acquired(let lease) = store.tryAcquirePathLease(
            for: owner, relativePaths: [leased], purpose: .checkpointHandoff) else {
            Issue.record("lease rejected"); return
        }
        defer { store.releasePathLease(lease) }
        let born = fixture.temp("a")
        try Data([9]).write(to: fixture.directory.appendingPathComponent(born))
        // Atomic replacement changes file identity after inventory, even at the same path.
        try Data([9, 9, 9]).write(to: fixture.directory.appendingPathComponent(replaced), options: .atomic)
        let result = store.sweepUnreferencedAttemptStaging(additionalReferencedRelativePaths: [explicit])
        #expect(result.removedRelativePaths == [residue])
        #expect(!fixture.exists(residue))
        #expect(store.checkpointStorageDiagnostics.sweepReclaimedCount == 1)
        #expect(store.checkpointStorageDiagnostics.sweepReclaimedBytes == 2)
        for name in [checkpoint.lastPathComponent, pending, leased, born, replaced, explicit, malformed] {
            #expect(fixture.exists(name))
        }
        #expect(try Data(contentsOf: checkpoint) == Data(repeating: 1, count: 3))
    }

    @Test("B86 repeated hard-kill recovery cycles do not accumulate copy temps")
    func repeatedRecoverySweeps() throws {
        let fixture = try HandoffStorageFixture()
        for _ in 0..<3 {
            let name = fixture.temp("b")
            try Data([1, 2, 3]).write(to: fixture.directory.appendingPathComponent(name))
            let reopened = fixture.store()
            #expect(reopened.sweepUnreferencedAttemptStaging().removedRelativePaths == [name])
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
                .filter { $0.contains(".checkpoint-") }.isEmpty)
        }
    }

    @Test("B87 insufficient space refuses before copying and retains the predecessor checkpoint")
    func insufficientSpaceBeforeCopy() throws {
        let fixture = try HandoffStorageFixture()
        let spy = HandoffCopySpy()
        let store = fixture.store(free: 600_000_000, checkpoint: spy.filesystem)
        let owner = try fixture.seed(store)
        let source = try fixture.working(store, owner, bytes: 1_000_000_000)
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        let successor = fixture.record("b")
        let result = store.createAttemptOwnedRecord(successor, attemptID: successor.attemptID!, replacing: owner.attemptID)
        #expect(result != .committed(DownloadAttemptKey(ratingKey: owner.ratingKey, attemptID: successor.attemptID!)))
        #expect(spy.calls == 0)
        #expect(store.checkpointStorageDiagnostics.spaceRefusalCount == 1)
        #expect(store.checkpointStorageDiagnostics.copyBeginCount == 0)
        #expect(store.record(for: owner)?.attemptID == owner.attemptID)
        #expect(store.lifecycleState(for: owner)?.history.lastFailure == .storage)
        #expect(DownloadStaticCheckpointFilesystem.live.size(source) == 1_000_000_000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == before)
        #expect(DownloadStore(baseDirectory: fixture.directory).record(for: owner)?.attemptID == owner.attemptID)
    }

    @Test("B87 seed caller surfaces the existing storage-full message")
    @MainActor func managerReportsStorageRefusal() async throws {
        let fixture = try HandoffStorageFixture()
        let spy = HandoffCopySpy()
        let store = fixture.store(free: 600_000_000, checkpoint: spy.filesystem)
        let owner = try fixture.seed(store)
        _ = try fixture.working(store, owner, bytes: 1_000_000_000)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "handoff-storage-fixture"))
        let manager = DownloadManager(appModel: model, store: store, session: session,
            registerForBackgroundEvents: false)
        try #require(await manager.awaitStartupRecoveryForTesting())
        let handle = try #require(manager.acquireStartAttempt(ratingKey: owner.ratingKey, backend: "plex"))
        var successor = fixture.record("b")
        successor.attemptID = handle.attemptID
        #expect(!(await manager.persistAttemptSeed(successor, for: handle, backend: "plex")))
        if case .storageFull = manager.lastError[owner.ratingKey] {} else {
            Issue.record("Expected existing storageFull user message")
        }
        #expect(store.ownsAttempt(owner))
        #expect(spy.calls == 0)
    }

    @Test("B87 competing handoffs cannot spend the same physical capacity")
    func competingHandoffsReserveCapacity() async throws {
        let fixture = try HandoffStorageFixture()
        let gate = HandoffStorageGate()
        let spy = HandoffCopySpy(gate: gate)
        // One 400 MB copy + 500 MB headroom fits; two do not.
        let store = fixture.store(free: 1_000_000_000, checkpoint: spy.filesystem)
        let first = try fixture.seed(store, ratingKey: "fixture-a", filename: "a.mp4")
        let second = try fixture.seed(store, ratingKey: "fixture-b", filename: "b.mp4")
        _ = try fixture.working(store, first, bytes: 400_000_000)
        let secondSource = try fixture.working(store, second, bytes: 400_000_000)
        let firstSuccessor = fixture.record("b", ratingKey: first.ratingKey, filename: "a.mp4")
        let work = store.submitAttemptOwnedRecord(firstSuccessor, attemptID: firstSuccessor.attemptID!, replacing: first.attemptID)
        defer { gate.release.signal() }
        try #require(await handoffSignal(gate.entered))
        let secondSuccessor = fixture.record("b", ratingKey: second.ratingKey, filename: "b.mp4")
        let result = store.createAttemptOwnedRecord(secondSuccessor, attemptID: secondSuccessor.attemptID!, replacing: second.attemptID)
        #expect(result != .committed(DownloadAttemptKey(ratingKey: second.ratingKey, attemptID: secondSuccessor.attemptID!)))
        #expect(spy.calls == 1)
        #expect(store.checkpointStorageDiagnostics.copyBeginBytes == 400_000_000)
        #expect(store.checkpointStorageDiagnostics.copyEndBytes == 0)
        #expect(store.checkpointStorageDiagnostics.spaceRefusalCount == 1)
        #expect(store.record(for: second)?.attemptID == second.attemptID)
        #expect(store.lifecycleState(for: second)?.history.lastFailure == .storage)
        #expect(DownloadStaticCheckpointFilesystem.live.size(secondSource) == 400_000_000)
        gate.release.signal()
        #expect(await store.resolve(work, deadline: .after(30)) == .committed(
            DownloadAttemptKey(ratingKey: first.ratingKey, attemptID: firstSuccessor.attemptID!)))
        // Physical completion releases the reservation: the second row can retry afterwards.
        #expect(store.createAttemptOwnedRecord(secondSuccessor, attemptID: secondSuccessor.attemptID!, replacing: second.attemptID)
            == .committed(DownloadAttemptKey(ratingKey: second.ratingKey, attemptID: secondSuccessor.attemptID!)))
        #expect(spy.calls == 2)
        #expect(store.checkpointStorageDiagnostics.copyBeginCount == 2)
        #expect(store.checkpointStorageDiagnostics.copyEndCount == 2)
        #expect(store.checkpointStorageDiagnostics.copyEndBytes == 800_000_000)
    }
}

private final class HandoffStorageFixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-storage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent)-download-authority"))
    }
    func store(free: Int64? = nil, checkpoint: DownloadStaticCheckpointFilesystem = .live) -> DownloadStore {
        DownloadStore(baseDirectory: directory, checkpointFilesystem: checkpoint,
            availableStorageBytes: { _ in free })
    }
    func record(_ attempt: String = "a", ratingKey: String = "fixture", filename: String = "fixture.mp4") -> DownloadRecord {
        let metadata = OfflineMetadata(ratingKey: ratingKey, title: "Fixture", type: "movie", resumeMode: .staticByteRange)
        return DownloadRecord(ratingKey: ratingKey, attemptID: DownloadAttemptID(rawValue: attempt)!,
            title: "Fixture", localURL: directory.appendingPathComponent(filename), bytes: 7,
            status: .failed, metadata: metadata)
    }
    func seed(_ store: DownloadStore, ratingKey: String = "fixture", filename: String = "fixture.mp4") throws -> DownloadAttemptKey {
        let record = record(ratingKey: ratingKey, filename: filename)
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: record.attemptID!)
        try #require(store.createAttemptOwnedRecord(record, attemptID: key.attemptID) == .committed(key))
        return key
    }
    func working(_ store: DownloadStore, _ owner: DownloadAttemptKey, bytes: Int) throws -> URL {
        let url = try #require(store.attemptWorkingFileURL(for: owner))
        try Data([1]).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        if bytes == 3 { try Data(repeating: 1, count: 3).write(to: url) }
        return url
    }
    func temp(_ digit: String) -> String {
        "..attempt-stage-v1-" + String(repeating: digit, count: 64) + ".stage.checkpoint-" + UUID().uuidString
    }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
    func addPendingCheckpoint(owner: DownloadAttemptKey, working: String, temp: String) throws {
        let index = directory.appendingPathComponent("index.json")
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var rows = try #require(root["rows"] as? [[String: Any]])
        rows[0]["pendingArtifactIntents"] = [["id": UUID().uuidString, "attemptID": owner.attemptID.rawValue,
            "generation": 1, "phase": "prepared", "operation": ["staticCheckpoint": [
                "workingRelativePath": working, "copyTempRelativePath": temp,
                "stableSourceRelativePath": "fixture.mp4",
                "expectedBytes": 100, "reconstructedTerminal": true]]]]
        root["rows"] = rows
        try JSONSerialization.data(withJSONObject: root).write(to: index)
    }
}

private final class HandoffStorageGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let first = Mutex(true)
    func hold() {
        guard first.withLock({ let value = $0; $0 = false; return value }) else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 30)
    }
}

private final class HandoffCopySpy: Sendable {
    private let count = Mutex(0)
    let gate: HandoffStorageGate?
    init(gate: HandoffStorageGate? = nil) { self.gate = gate }
    var calls: Int { count.withLock { $0 } }
    var filesystem: DownloadStaticCheckpointFilesystem {
        let live = DownloadStaticCheckpointFilesystem.live
        return .init(exists: live.exists, size: live.size, durableCopy: { [self] _, destination, _ in
            count.withLock { $0 += 1 }
            gate?.hold()
            // Admission pin: avoid physically allocating the sparse fixture's large body.
            try Data([1]).write(to: destination)
        })
    }
}

private func handoffSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 30) == .success)
        }
    }
}

#endif
