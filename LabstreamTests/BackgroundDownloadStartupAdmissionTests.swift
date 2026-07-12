import Foundation
import PMSKit
import Testing
@testable import Labstream

struct BackgroundDownloadStartupAdmissionTests {
    @Test func dormantSessionRejectsStartWithoutCreatingWork() throws {
        try withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            let ratingKey = "plex:dormant"

            do {
                try session.start(
                    ratingKey: ratingKey,
                    from: URL(string: "https://example.invalid/media.mp4")!,
                    to: directory.appendingPathComponent("dormant.mp4")
                )
                Issue.record("A dormant download session unexpectedly admitted new work")
            } catch is CancellationError {
                // Expected: startup admission has not opened.
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }

            #expect(!session.isTrackingTransfer(ratingKey: ratingKey))
            let snapshot = session.diagnosticSnapshot()
            #expect(snapshot.opaqueInflightCount == 0)
            #expect(snapshot.rangeInflightCount == 0)
        }
    }

    @Test func emptyResetActivationOpensAdmissionOnce() async throws {
        try await withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }

            let first = await activate(session, resetKeys: [])
            #expect(first == .activated(cancelledTaskCount: 0, resetKeyCount: 0))

            let second = await activate(session, resetKeys: [])
            #expect(second == .alreadyActive)
        }
    }

    @Test func activeStaticTransferCheckpointsOnlyInAttemptWorkingFile() async throws {
        try await withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            #expect(await activate(session, resetKeys: []) == .activated(
                cancelledTaskCount: 0, resetKeyCount: 0))

            let ratingKey = "plex:attempt-working-session"
            let attemptID = try #require(DownloadAttemptID(rawValue: "attempt-session-a"))
            let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
            let stable = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
            try Data("previous-published-body".utf8).write(to: stable)
            let record = DownloadRecord(
                ratingKey: ratingKey, attemptID: attemptID, title: "Working",
                localURL: stable, status: .queued,
                metadata: OfflineMetadata(
                    ratingKey: ratingKey, title: "Working", type: "movie",
                    resumeMode: .staticByteRange))
            #expect(store.createAttemptOwnedRecord(record, attemptID: attemptID) == .committed(key))
            let working = try #require(store.attemptWorkingFileURL(for: key))

            try session.start(
                ratingKey: ratingKey,
                from: URL(string: "https://example.invalid/media.mp4")!,
                to: stable,
                expectedBytes: 1_024,
                byteRangeCheckpoint: true)

            #expect(FileManager.default.fileExists(atPath: working.path))
            #expect((try Data(contentsOf: stable)) == Data("previous-published-body".utf8))
            #expect(store.record(for: key)?.localURL == stable)
            session.cancel(ratingKey: ratingKey)
        }
    }

    @Test func reattachSweepsOnlyUnreferencedAttemptStaging() async throws {
        try await withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let owner = DownloadAttemptKey(
                ratingKey: "plex:owned-stage",
                attemptID: try #require(DownloadAttemptID(rawValue: "owner-a")))
            let orphan = DownloadAttemptKey(
                ratingKey: "plex:orphan-stage",
                attemptID: try #require(DownloadAttemptID(rawValue: "orphan-a")))
            let ownedStable = store.destinationURL(ratingKey: owner.ratingKey, ext: "mp4")
            let orphanStable = store.destinationURL(ratingKey: orphan.ratingKey, ext: "mp4")
            let record = DownloadRecord(
                ratingKey: owner.ratingKey, attemptID: owner.attemptID, title: "Owned",
                localURL: ownedStable, status: .queued)
            #expect(store.createAttemptOwnedRecord(record, attemptID: owner.attemptID)
                    == .committed(owner))
            let ownedStage = try #require(store.attemptWorkingFileURL(for: owner))
            let orphanStage = try #require(store.attemptStagingURL(
                for: orphan, stableURL: orphanStable))
            try Data("owned".utf8).write(to: ownedStage)
            try Data("orphan".utf8).write(to: orphanStage)

            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            #expect(await activate(session, resetKeys: []) == .activated(
                cancelledTaskCount: 0, resetKeyCount: 0))
            await withCheckedContinuation { continuation in
                session.reattach { _ in continuation.resume() }
            }

            #expect(FileManager.default.fileExists(atPath: ownedStage.path))
            #expect(!FileManager.default.fileExists(atPath: orphanStage.path))
        }
    }

    @Test func migratedPausedRowIsDurablyResetBeforeAdmission() async throws {
        try await withTemporaryDirectory { directory in
            let ratingKey = "plex:legacy-paused"
            let relativePath = "legacy-paused.mp4"
            let partialURL = directory.appendingPathComponent(relativePath)
            try Data(repeating: 0xA5, count: 4_096).write(to: partialURL)
            try writeV2PausedRow(
                ratingKey: ratingKey,
                relativePath: relativePath,
                bytes: 4_096,
                directory: directory
            )

            let attemptID = DownloadAttemptID(
                uuid: UUID(uuidString: "B1B1B1B1-B1B1-4B1B-8B1B-B1B1B1B1B1B1")!
            )
            let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
            let store = DownloadStore(baseDirectory: directory)
            let migration = await Task.detached(priority: .utility) {
                store.commitLegacyAttemptOwnershipMigration { migratedRatingKey in
                    #expect(migratedRatingKey == ratingKey)
                    return attemptID
                }
            }.value
            guard case .committed(let plan) = migration else {
                Issue.record("Expected committed schema-v3 migration, got \(migration)")
                return
            }
            #expect(plan.taskCancellationAndReset == [key])
            #expect(FileManager.default.fileExists(atPath: partialURL.path))

            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            let activation = await activate(session, resetKeys: [key])
            #expect(activation == .activated(cancelledTaskCount: 0, resetKeyCount: 1))

            let reset = try #require(store.record(for: ratingKey))
            #expect(reset.attemptID == attemptID)
            #expect(reset.status == .failed)
            #expect(reset.bytes == 0)
            #expect(reset.progress == 0)
            #expect(!FileManager.default.fileExists(atPath: partialURL.path))

            let indexData = try Data(contentsOf: directory.appendingPathComponent("index.json"))
            let index = try #require(
                JSONSerialization.jsonObject(with: indexData) as? [String: Any]
            )
            #expect(index["schemaVersion"] as? Int == 4)

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.commitLegacyAttemptOwnershipMigration() == .notRequired)
            let restored = try #require(relaunched.record(for: ratingKey))
            #expect(restored.attemptID == attemptID)
            #expect(restored.status == .failed)
            #expect(restored.bytes == 0)
            #expect(restored.progress == 0)
        }
    }

    private func activate(
        _ session: BackgroundDownloadSession,
        resetKeys: Set<DownloadAttemptKey>,
        timeout: TimeInterval = 2
    ) async -> BackgroundDownloadSession.StartupActivationResult? {
        await ActivationWaiter().wait(session: session, resetKeys: resetKeys, timeout: timeout)
    }

    private func writeV2PausedRow(
        ratingKey: String,
        relativePath: String,
        bytes: Int,
        directory: URL
    ) throws {
        let row: [String: Any] = [
            "ratingKey": ratingKey,
            "title": "Legacy Paused",
            "relativePath": relativePath,
            "bytes": bytes,
            "progress": 0.5,
            "status": "paused",
            "metadata": [
                "ratingKey": ratingKey,
                "title": "Legacy Paused",
                "type": "movie",
            ],
        ]
        let envelope: [String: Any] = ["schemaVersion": 2, "rows": [row]]
        try JSONSerialization.data(withJSONObject: envelope)
            .write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-startup-admission-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-startup-admission-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private final class ActivationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BackgroundDownloadSession.StartupActivationResult?, Never>?

    func wait(
        session: BackgroundDownloadSession,
        resetKeys: Set<DownloadAttemptKey>,
        timeout: TimeInterval
    ) async -> BackgroundDownloadSession.StartupActivationResult? {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            session.activateAfterPurgingLegacyTasks(resetKeys: resetKeys) { [weak self] result in
                self?.finish(result)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(nil)
            }
        }
    }

    private func finish(_ result: BackgroundDownloadSession.StartupActivationResult?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
