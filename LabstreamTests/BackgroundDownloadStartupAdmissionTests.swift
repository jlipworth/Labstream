import Foundation
import PMSKit
import Testing
@testable import Labstream

struct BackgroundDownloadStartupAdmissionTests {
    @Test func purgeWindowAdmitsOnlyHealthyCurrentExactOwnerCallbacks() throws {
        let healthy = DownloadAttemptKey(
            ratingKey: "plex:healthy",
            attemptID: try #require(DownloadAttemptID(rawValue: "healthy-attempt")))
        let reset = DownloadAttemptKey(
            ratingKey: "plex:reset",
            attemptID: try #require(DownloadAttemptID(rawValue: "reset-attempt")))

        #expect(BackgroundDownloadSession.shouldAdmitStartupCallback(
            isActive: false, isPurging: true, isPermanentlyRejected: false,
            hasCurrentMarker: true, taskKey: healthy, resetKeys: [reset], ownsAttempt: true))
        #expect(!BackgroundDownloadSession.shouldAdmitStartupCallback(
            isActive: false, isPurging: true, isPermanentlyRejected: false,
            hasCurrentMarker: true, taskKey: reset, resetKeys: [reset], ownsAttempt: true))
        #expect(!BackgroundDownloadSession.shouldAdmitStartupCallback(
            isActive: false, isPurging: true, isPermanentlyRejected: false,
            hasCurrentMarker: false, taskKey: healthy, resetKeys: [], ownsAttempt: true))
        #expect(!BackgroundDownloadSession.shouldAdmitStartupCallback(
            isActive: false, isPurging: true, isPermanentlyRejected: false,
            hasCurrentMarker: true, taskKey: healthy, resetKeys: [], ownsAttempt: false))
        #expect(!BackgroundDownloadSession.shouldAdmitStartupCallback(
            isActive: true, isPurging: false, isPermanentlyRejected: true,
            hasCurrentMarker: true, taskKey: healthy, resetKeys: [], ownsAttempt: true))
    }

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

    @Test func rangeErrorCompletionAfterDeletionReservationCannotMutateOrPurge() async throws {
        try await withTemporaryDirectory { directory in
            let gate = HeldRangeFailureGate()
            HeldRangeFailureURLProtocol.configure(gate)
            defer { HeldRangeFailureURLProtocol.configure(nil) }
            let store = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(
                store: store, protocolClasses: [HeldRangeFailureURLProtocol.self])
            defer { session.invalidateInjectedSessionForTesting() }
            #expect(await activate(session, resetKeys: []) == .activated(
                cancelledTaskCount: 0, resetKeyCount: 0))

            let attemptID = try #require(DownloadAttemptID(rawValue: "pending-range-error-a"))
            let key = DownloadAttemptKey(ratingKey: "emby:pending-range", attemptID: attemptID)
            let stable = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: attemptID, title: "Pending Range",
                localURL: stable, bytes: 15, progress: 0.15, status: .downloading,
                metadata: OfflineMetadata(
                    ratingKey: key.ratingKey, title: "Pending Range", type: "movie",
                    sourcePartSize: 100,
                    backendKind: .emby,
                    backendBaseURLString: "https://emby.example",
                    backendServerID: "server-1",
                    backendUserID: "user-1",
                    playSessionID: "session-A",
                    resumeMode: .staticByteRange))
            #expect(store.createAttemptOwnedRecord(record, attemptID: attemptID) == .committed(key))
            let working = try #require(store.attemptWorkingFileURL(for: key))
            let workingBytes = Data(repeating: 0xA5, count: 15)
            try workingBytes.write(to: working)
            #expect(store.setResumeData(
                for: key, Data("original-resume".utf8), displayBytes: 15) == .applied)
            let held = OfflineHeldRangeSegment(
                offset: 30, length: 4, relativePath: "pending-held.body")
            let heldURL = directory.appendingPathComponent(held.relativePath)
            try Data([1, 2, 3, 4]).write(to: heldURL)
            guard case .accepted = store.persistHeldRangeSegment(for: key, segment: held) else {
                Issue.record("Expected held manifest persistence"); return
            }

            try session.start(
                ratingKey: key.ratingKey,
                from: URL(string: "https://example.invalid/pending-range.mp4")!,
                to: stable,
                expectedBytes: 100,
                byteRangeCheckpoint: true)
            #expect(await gate.waitUntilStarted())

            let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
                baseURL: URL(string: "https://emby.example")!,
                serverID: "server-1", userID: "user-1"))
            let intent = try #require(DurableDownloadCleanupIntent(
                attemptKey: key, backend: .emby, server: server,
                operation: .activeEncoding(playSessionID: "session-A")))
            #expect(store.markDeletionPending(for: key, cleanupIntents: [intent]) == .applied)

            gate.fail(NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileWriteOutOfSpace.rawValue))
            #expect(await gate.waitUntilFinished())
            for _ in 0..<100 where session.isTrackingTransfer(ratingKey: key.ratingKey) {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(!session.isTrackingTransfer(ratingKey: key.ratingKey))
            #expect(store.isDeletionPending(for: key))
            #expect(store.record(for: key)?.status == .downloading)
            #expect(store.resumeData(for: key) == Data("original-resume".utf8))
            #expect(store.metadata(for: key.ratingKey)?.heldRangeSegments == [held])
            #expect(try Data(contentsOf: working) == workingBytes)
            #expect(FileManager.default.fileExists(atPath: heldURL.path))
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

            // The sweep is launch-scoped: only staging present in the Store's initial inventory is
            // eligible, so work created after admission can never race deletion.
            let relaunchedStore = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(store: relaunchedStore, protocolClasses: [])
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

    @Test func invalidHeldManifestCommitFailurePreservesBodyAndManifestAcrossRelaunch() async throws {
        try await withTemporaryDirectory { directory in
            let initial = DownloadStore(baseDirectory: directory)
            let key = DownloadAttemptKey(
                ratingKey: "plex:invalid-held-commit",
                attemptID: try #require(DownloadAttemptID(rawValue: "attempt-a")))
            let stable = initial.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Invalid",
                localURL: stable, status: .paused,
                metadata: OfflineMetadata(
                    ratingKey: key.ratingKey, title: "Invalid", type: "movie",
                    resumeMode: .staticByteRange))
            #expect(initial.createAttemptOwnedRecord(record, attemptID: key.attemptID)
                == .committed(key))
            let working = try #require(initial.attemptWorkingFileURL(for: key))
            try Data().write(to: working)
            let manifest = OfflineHeldRangeSegment(
                offset: 64, length: 4, relativePath: "invalid-held-commit.body")
            let body = directory.appendingPathComponent(manifest.relativePath)
            try Data([1, 2, 3]).write(to: body) // length mismatch makes launch restoration discard
            guard case .accepted = initial.persistHeldRangeSegment(for: key, segment: manifest) else {
                Issue.record("Expected manifest"); return
            }

            let writes = StartupFailFirstIndexWrite()
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            #expect(await activate(session, resetKeys: []) == .activated(
                cancelledTaskCount: 0, resetKeyCount: 0))
            await withCheckedContinuation { continuation in
                session.reattach { _ in continuation.resume() }
            }

            #expect(FileManager.default.fileExists(atPath: body.path))
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.record(for: key)?.metadata?.heldRangeSegments == [manifest])
            #expect(FileManager.default.fileExists(atPath: body.path))
        }
    }

    @Test func invalidHeldManifestDeleteFaultRetainsIntentUntilHealthyRelaunch() async throws {
        try await withTemporaryDirectory { directory in
            let initial = DownloadStore(baseDirectory: directory)
            let key = DownloadAttemptKey(
                ratingKey: "jellyfin:invalid-held-delete",
                attemptID: try #require(DownloadAttemptID(rawValue: "attempt-a")))
            let stable = initial.destinationURL(ratingKey: key.ratingKey, ext: "mkv")
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Invalid",
                localURL: stable, status: .paused,
                metadata: OfflineMetadata(
                    ratingKey: key.ratingKey, title: "Invalid", type: "movie",
                    resumeMode: .staticByteRange))
            #expect(initial.createAttemptOwnedRecord(record, attemptID: key.attemptID)
                == .committed(key))
            try Data().write(to: try #require(initial.attemptWorkingFileURL(for: key)))
            let manifest = OfflineHeldRangeSegment(
                offset: 64, length: 4, relativePath: "invalid-held-delete.body")
            let body = directory.appendingPathComponent(manifest.relativePath)
            try Data([9, 8, 7]).write(to: body)
            guard case .accepted = initial.persistHeldRangeSegment(for: key, segment: manifest) else {
                Issue.record("Expected manifest"); return
            }

            let failingFiles = StartupSelectiveRemovalFailureFileManager(blockedPath: body.path)
            let store = DownloadStore(baseDirectory: directory, fileManager: failingFiles)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            #expect(await activate(session, resetKeys: []) == .activated(
                cancelledTaskCount: 0, resetKeyCount: 0))
            await withCheckedContinuation { continuation in
                session.reattach { _ in continuation.resume() }
            }
            #expect(store.record(for: key)?.metadata?.heldRangeSegments == nil)
            #expect(store.deferredHeldRangeBodyDeletionRelativePaths(for: key)
                == [manifest.relativePath])
            #expect(FileManager.default.fileExists(atPath: body.path))

            let healthyRelaunch = DownloadStore(baseDirectory: directory)
            #expect(healthyRelaunch.deferredHeldRangeBodyDeletionRelativePaths(for: key) == [])
            #expect(!FileManager.default.fileExists(atPath: body.path))
        }
    }

    @Test func finalizerAdmissionRejectsDuplicateAndAbandonBalancesGate() async throws {
        try await withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            #expect(await activate(session, resetKeys: []) == .activated(
                cancelledTaskCount: 0, resetKeyCount: 0))

            let attemptID = try #require(DownloadAttemptID(rawValue: "attempt-finalizer-a"))
            let key = DownloadAttemptKey(ratingKey: "plex:finalizer", attemptID: attemptID)
            let stable = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: attemptID, title: "Finalizer",
                localURL: stable, status: .downloading,
                metadata: OfflineMetadata(
                    ratingKey: key.ratingKey, title: "Finalizer", type: "movie",
                    resumeMode: .staticByteRange))
            #expect(store.createAttemptOwnedRecord(record, attemptID: attemptID) == .committed(key))
            let working = try #require(store.attemptWorkingFileURL(for: key))
            try Data(repeating: 0xA5, count: 512).write(to: working)

            let requestBox = FinalizerRequestBox()
            session.onFinalizerRequest = { requestBox.store($0) }
            #expect(session.finalizeCompletedStaticRangeFile(
                ratingKey: key.ratingKey, validationLabel: "test"))
            #expect(!session.finalizeCompletedStaticRangeFile(
                ratingKey: key.ratingKey, validationLabel: "duplicate"))
            var snapshot = session.diagnosticSnapshot()
            #expect(snapshot.finalizingRatingKeyCount == 1)
            #expect(snapshot.pendingBackgroundCompletionOperationCount == 1)

            session.abandonFinalizerRequest(try #require(requestBox.load()))
            snapshot = session.diagnosticSnapshot()
            #expect(snapshot.finalizingRatingKeyCount == 0)
            #expect(snapshot.pendingBackgroundCompletionOperationCount == 0)
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

    @Test @MainActor
    func malformedStartupReleasesStoredBackgroundHandler() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-startup-malformed-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
            let seed = DownloadStore(baseDirectory: directory)
            let attemptID = DownloadAttemptID(rawValue: "top-level-owner")!
            let key = DownloadAttemptKey(ratingKey: "plex:malformed-startup", attemptID: attemptID)
            let record = DownloadRecord(
                ratingKey: key.ratingKey, title: "Malformed",
                localURL: directory.appendingPathComponent("malformed.mp4"),
                status: .queued,
                metadata: OfflineMetadata(ratingKey: key.ratingKey, title: "Malformed", type: "movie"))
            #expect(seed.createAttemptOwnedRecord(record, attemptID: attemptID) == .committed(key))

            let indexURL = directory.appendingPathComponent("index.json")
            var envelope = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
            var rows = try #require(envelope["rows"] as? [[String: Any]])
            var metadata = try #require(rows[0]["metadata"] as? [String: Any])
            metadata["downloadAttemptID"] = "different-shadow-owner"
            rows[0]["metadata"] = metadata
            envelope["rows"] = rows
            try JSONSerialization.data(withJSONObject: envelope).write(to: indexURL, options: .atomic)

            let store = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            let released = DispatchSemaphore(value: 0)
            BackgroundDownloadCompletionRegistry.shared.store(
                identifier: BackgroundDownloadSession.identifier,
                completion: { released.signal() })
            let manager = DownloadManager(
                appModel: AppModel(identity: PlatformClientIdentity.make(
                    clientIdentifier: "malformed-startup")),
                store: store, session: session, registerForBackgroundEvents: true)

            #expect(await waitForSignal(released, timeout: 1))
            guard case .blocked = manager.startupRecoveryState else {
                Issue.record("Malformed ownership must block startup")
                return
            }
            #expect(!BackgroundDownloadCompletionRegistry.shared.hasPendingHandler(
                identifier: BackgroundDownloadSession.identifier))
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

    private func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }
}

private final class FinalizerRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: BackgroundDownloadSession.FinalizerRequest?

    func store(_ request: BackgroundDownloadSession.FinalizerRequest) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
    }

    func load() -> BackgroundDownloadSession.FinalizerRequest? {
        lock.lock(); defer { lock.unlock() }
        return request
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

private final class HeldRangeFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: ((Error) -> Void)?
    private var didStart = false
    private var didFinish = false

    func install(_ failure: @escaping (Error) -> Void) {
        lock.withLock {
            self.failure = failure
            didStart = true
        }
    }

    func fail(_ error: Error) {
        let callback = lock.withLock { failure }
        callback?(error)
        lock.withLock { didFinish = true }
    }

    func waitUntilStarted() async -> Bool {
        await waitUntil { self.lock.withLock { self.didStart } }
    }

    func waitUntilFinished() async -> Bool {
        await waitUntil { self.lock.withLock { self.didFinish } }
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private final class HeldRangeFailureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuredGate: HeldRangeFailureGate?

    static func configure(_ gate: HeldRangeFailureGate?) {
        lock.withLock { configuredGate = gate }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let gate = Self.lock.withLock { Self.configuredGate }
        gate?.install { [weak self] error in
            guard let self else { return }
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class StartupFailFirstIndexWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            count += 1
            return count == 1
        }
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}

private final class StartupSelectiveRemovalFailureFileManager: FileManager, @unchecked Sendable {
    private let blockedPath: String

    init(blockedPath: String) {
        self.blockedPath = blockedPath
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.path == blockedPath { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}
