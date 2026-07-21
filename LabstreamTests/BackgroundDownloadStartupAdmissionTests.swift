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
            _ = store.resolveArtifactSynchronouslyForTests(
                through: store.currentArtifactLifecycleWatermark())

            #expect(FileManager.default.fileExists(atPath: ownedStage.path))
            #expect(!FileManager.default.fileExists(atPath: orphanStage.path))
        }
    }

    // D5: `reattach` finalizes a validated promotion whose terminal snapshot committed before a
    // hard kill. The recovery does an F_FULLFSYNC/rename/dir-sync/waitForPersistence, so it now runs
    // off the URLSession delegate queue — but its ordering guarantee must survive the move: the row
    // is terminal (`.complete`) by the time `reattach`'s completion (which drives reconcile) fires.
    @Test func reattachFinalizesPendingValidatedPromotionBeforeReportingCompletion() async throws {
        try await withTemporaryDirectory { directory in
            let seed = DownloadStore(baseDirectory: directory)
            let key = DownloadAttemptKey(
                ratingKey: "plex:reattach-pending-promotion",
                attemptID: try #require(DownloadAttemptID(rawValue: "attempt-a")))
            let stable = seed.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
            try Data("stale-published".utf8).write(to: stable)
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Promotion",
                localURL: stable, status: .queued,
                metadata: OfflineMetadata(
                    ratingKey: key.ratingKey, title: "Promotion", type: "movie",
                    resumeMode: .staticByteRange))
            #expect(seed.createAttemptOwnedRecord(record, attemptID: key.attemptID)
                    == .committed(key))
            let working = try #require(seed.attemptWorkingFileURL(for: key))
            try Data("validated".utf8).write(to: working)

            // Durable prepared-but-not-terminal promotion: the intent's terminal status is recorded
            // on the row, but the process "died" before the rename/terminal publication ran.
            let indexURL = directory.appendingPathComponent("index.json")
            var object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
            var rows = try #require(object["rows"] as? [[String: Any]])
            rows[0]["pendingValidatedPromotionStatus"] = "complete"
            object["rows"] = rows
            try JSONSerialization.data(withJSONObject: object).write(to: indexURL, options: .atomic)

            let store = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            #expect(await activate(session, resetKeys: []) == .activated(
                cancelledTaskCount: 0, resetKeyCount: 0))
            // Store construction alone must not have finalized it — reattach owns the recovery.
            #expect(store.record(for: key)?.status == .queued)

            await withCheckedContinuation { continuation in
                session.reattach { _ in continuation.resume() }
            }

            // Recovery ran (off-queue) and completed before reattach reported: terminal row, the
            // validated working body published over the stale stable file.
            #expect(store.record(for: key)?.status == .complete)
            #expect(store.record(for: key)?.bytes == 9)
            #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self) == "validated")
            #expect(!FileManager.default.fileExists(atPath: working.path))
        }
    }

    // D6: `halt()` (Cancel/Delete) resets every sibling restart budget so a re-download of the same
    // item starts clean. The consecutive-truncation budget is keyed by ratingKey and guarded by a
    // separate queue, so it was omitted — a delete + re-download inherited the stale count and could
    // park immediately. Cancel must now clear it too.
    @Test func haltClearsConsecutiveTruncationBudgetForReDownload() async throws {
        try await withTemporaryDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            #expect(await activate(session, resetKeys: []) == .activated(
                cancelledTaskCount: 0, resetKeyCount: 0))

            let key = DownloadAttemptKey(
                ratingKey: "plex:truncation-budget",
                attemptID: try #require(DownloadAttemptID(rawValue: "attempt-a")))
            let stable = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
            let record = DownloadRecord(
                ratingKey: key.ratingKey, attemptID: key.attemptID, title: "Truncated",
                localURL: stable, status: .queued,
                metadata: OfflineMetadata(
                    ratingKey: key.ratingKey, title: "Truncated", type: "movie",
                    resumeMode: .staticByteRange))
            #expect(store.createAttemptOwnedRecord(record, attemptID: key.attemptID)
                    == .committed(key))

            session.seedTruncationFailureCountForTesting(3, ratingKey: key.ratingKey)
            #expect(session.truncationFailureCountForTesting(ratingKey: key.ratingKey) == 3)

            session.cancel(ratingKey: key.ratingKey)

            #expect(session.truncationFailureCountForTesting(ratingKey: key.ratingKey) == 0)
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

            // `reattach` reports task enumeration, not completion of artifact lifecycle workers
            // that invalid-manifest restoration submitted while enumerating the store.  Wait for
            // that exact process boundary before simulating a hard relaunch; otherwise a slow
            // sanitizer run can construct the second store before the deletion intent itself is
            // durable and race two stores over the same index.
            let failedBoundary = store.resolveArtifactSynchronouslyForTests(
                through: store.currentArtifactLifecycleWatermark())
            guard case .failed(.artifact) = failedBoundary else {
                Issue.record("Expected the injected held-body deletion fault, got \(failedBoundary)")
                return
            }

            let healthyRelaunch = DownloadStore(baseDirectory: directory)
            _ = healthyRelaunch.resolveArtifactSynchronouslyForTests(
                through: healthyRelaunch.currentArtifactLifecycleWatermark())
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
    func malformedStartupReleasesHeldBackgroundCompletion() async throws {
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
            let releases = AsyncStream.makeStream(of: String.self)
            let session = BackgroundDownloadSession(
                store: store,
                protocolClasses: [],
                releaseBackgroundCompletion: { batch in
                    releases.continuation.yield(batch.identifier)
                }
            )
            defer { session.invalidateInjectedSessionForTesting() }
            session.noteBackgroundCompletionHandlerStored(
                identifier: BackgroundDownloadSession.identifier)
            let manager = DownloadManager(
                appModel: AppModel(identity: PlatformClientIdentity.make(
                    clientIdentifier: "malformed-startup")),
                store: store, session: session, registerForBackgroundEvents: false)

            var releaseIterator = releases.stream.makeAsyncIterator()
            #expect(await releaseIterator.next() == BackgroundDownloadSession.identifier)
            guard case .blocked = manager.startupRecoveryState else {
                Issue.record("Malformed ownership must block startup")
                return
            }
            #expect(session.diagnosticSnapshot().pendingBackgroundCompletionOperationCount == 0)
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

struct UnverifiedRevalidationLifecycleTests {
    @MainActor
    @Test func inactiveOvertakingBrokerRegistrationNeverStartsProbeAndActiveRetriesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unverified-broker-overtake-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(baseDirectory: directory)
        let key = try seedUnverified("plex:broker-overtake", in: store)
        let validator = HeldRevalidationValidator()
        await validator.allowSuccess()
        let session = BackgroundDownloadSession(
            store: store, protocolClasses: [],
            playbackValidator: { _, _ in await validator.validate() })
        defer { session.invalidateInjectedSessionForTesting() }
        let manager = DownloadManager(
            appModel: AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "broker-overtake-test")),
            store: store, session: session, registerForBackgroundEvents: false)

        // Both calls run in one MainActor turn. The session claim is synchronous, while its broker
        // registration is queued; inactive must win without allowing the queued probe to start.
        manager.noteAppScenePhase("active")
        manager.noteAppScenePhase("inactive")
        for _ in 0..<20 { await Task.yield() }
        #expect(await validator.attemptCount == 0)
        #expect(store.record(for: key)?.status == .unverified)
        #expect(session.diagnosticSnapshot().finalizingRatingKeyCount == 0)
        #expect(manager.unverifiedRevalidationSnapshotForTesting().desired.contains(key))

        manager.noteAppScenePhase("active")
        #expect(await validator.waitForAttempts(1))
        for _ in 0..<200 where store.record(for: key)?.status != .complete {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.record(for: key)?.status == .complete)
        #expect(await validator.attemptCount == 1)
    }

    @MainActor
    @Test func activeToInactiveCancelsOnlyHeldRevalidationAndActiveRetriesExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unverified-inactive-cancel-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(baseDirectory: directory)
        let key = try seedUnverified("plex:inactive-cancel", in: store)
        let validator = HeldRevalidationValidator()
        let session = BackgroundDownloadSession(
            store: store, protocolClasses: [],
            playbackValidator: { _, _ in await validator.validate() })
        defer { session.invalidateInjectedSessionForTesting() }
        let manager = DownloadManager(
            appModel: AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "inactive-cancel-test")),
            store: store, session: session, registerForBackgroundEvents: false)

        // Keep a publishing finalizer beside the probe. The lifecycle transition must not cancel
        // this work: completed background transfers still need to publish `.unverified` and drain.
        let publishingTask = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
        defer { publishingTask.cancel() }
        let publishingToken = manager.downloadWorkRegistry.register(
            publishingTask, for: key, kind: .finalizer)

        manager.noteAppScenePhase("active")
        #expect(await validator.waitForAttempts(1))
        #expect(store.record(for: key)?.status == .unverified)

        manager.noteAppScenePhase("inactive")
        #expect(await validator.waitForCancellations(1))
        for _ in 0..<100 where session.diagnosticSnapshot().finalizingRatingKeyCount != 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.diagnosticSnapshot().finalizingRatingKeyCount == 0)
        #expect(store.record(for: key)?.status == .unverified)
        #expect(!publishingTask.isCancelled)
        #expect(manager.downloadWorkRegistry.snapshot().attempts
            .first(where: { $0.key == key })?.entries.map(\.kind) == [.finalizer])
        let parked = manager.unverifiedRevalidationSnapshotForTesting()
        #expect(parked.inFlight.isEmpty)
        #expect(parked.desired.contains(key))

        await validator.allowSuccess()
        manager.noteAppScenePhase("active")
        #expect(await validator.waitForAttempts(2))
        for _ in 0..<200 where store.record(for: key)?.status != .complete {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.record(for: key)?.status == .complete)
        #expect(await validator.attemptCount == 2)
        #expect(manager.downloadWorkRegistry.complete(key: key, token: publishingToken))
    }

    @MainActor
    @Test func inactiveSessionChangeAfterGateDrainCreatesNoFinalizerRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unverified-inactive-manager-\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(baseDirectory: directory)
        let key = try seedUnverified("plex:inactive-manager", in: store)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let manager = DownloadManager(
            appModel: AppModel(identity: PlatformClientIdentity.make(
                clientIdentifier: "inactive-revalidation-test")),
            store: store, session: session, registerForBackgroundEvents: false)
        manager.noteAppScenePhase("inactive")

        // This is the same callback that used to start a real AVFoundation finalizer after the
        // background gate had drained, even though the headset scene remained inactive.
        session.onChange?()
        for _ in 0..<10 { await Task.yield() }

        let snapshot = manager.unverifiedRevalidationSnapshotForTesting()
        #expect(snapshot.inFlight.isEmpty)
        #expect(snapshot.desired.contains(key))
        #expect(session.diagnosticSnapshot().finalizingRatingKeyCount == 0)
        // Let the manager's initial injected-session reattach callback finish before deleting its
        // temporary index directory.
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func coordinatorGateDrainOvertakeReDrivesAfterClaimReleaseExactlyOnce() throws {
        let key = try coordinatorKey("gate")
        var state = UnverifiedRevalidationCoordinator()
        let requestID = UUID()
        let began = state.begin(key, preservesOvertakenRequest: false)
        #expect(began)
        _ = state.started(key, requestID: requestID)
        state.gateDrained([key], sceneIsActive: true)
        // Drain can overtake finalizer release. The release consumes the desired edge once.
        let firstFinish = state.finished(
            key, requestID: requestID, cancelled: false, remainsUnverified: true)
        let duplicateFinish = state.finished(
            key, requestID: requestID, cancelled: false, remainsUnverified: true)
        #expect(firstFinish == .soon)
        #expect(duplicateFinish == nil)
    }

    @Test func coordinatorInactiveGateDrainParksUntilActiveTransition() throws {
        let key = try coordinatorKey("inactive-drain")
        var state = UnverifiedRevalidationCoordinator()
        let shouldStartInactive = state.gateDrained([key], sceneIsActive: false)
        #expect(!shouldStartInactive)
        #expect(state.desired == [key])

        // The active transition performs the ordinary scan; the parked desired edge does not
        // suppress its exact admission.
        let beganOnActive = state.begin(key, preservesOvertakenRequest: true)
        #expect(beganOnActive)
    }

    @Test func coordinatorActiveGateDrainRequestsImmediateForegroundScan() throws {
        let key = try coordinatorKey("active-drain")
        var state = UnverifiedRevalidationCoordinator()
        let shouldStart = state.gateDrained([key], sceneIsActive: true)
        #expect(shouldStart)
    }

    @Test func inactiveDrainThenOldFinishRemainsParkedUntilActive() throws {
        let key = try coordinatorKey("inactive-finish")
        var state = UnverifiedRevalidationCoordinator()
        let requestID = UUID()
        let began = state.begin(key, preservesOvertakenRequest: false)
        #expect(began)
        _ = state.started(key, requestID: requestID)
        _ = state.gateDrained([key], sceneIsActive: false)
        let retry = state.finished(
            key, requestID: requestID, cancelled: false, remainsUnverified: true)
        #expect(retry == .soon)
        let permitted = state.permitRetry(key, sceneIsActive: false)
        #expect(!permitted)
        #expect(state.desired == [key])
        let activeBegin = state.begin(key, preservesOvertakenRequest: true)
        #expect(activeBegin)
    }

    @Test func watchdogAndCancelCannotRestartWhileInactive() throws {
        let timerKey = try coordinatorKey("inactive-timer")
        var state = UnverifiedRevalidationCoordinator()
        let timerID = UUID()
        let timerBegan = state.begin(timerKey, preservesOvertakenRequest: false)
        #expect(timerBegan)
        let token = state.started(timerKey, requestID: timerID)
        let timerFired = state.timerFired(
            for: timerKey, token: token, remainsUnverified: true)
        #expect(timerFired)
        let timerPermitted = state.permitRetry(timerKey, sceneIsActive: false)
        #expect(!timerPermitted)
        #expect(state.desired.contains(timerKey))

        let cancelKey = try coordinatorKey("inactive-cancel")
        let cancelID = UUID()
        let cancelBegan = state.begin(cancelKey, preservesOvertakenRequest: false)
        #expect(cancelBegan)
        _ = state.started(cancelKey, requestID: cancelID)
        let retry = state.finished(
            cancelKey, requestID: cancelID, cancelled: true, remainsUnverified: true)
        #expect(retry == .soon)
        let cancelPermitted = state.permitRetry(cancelKey, sceneIsActive: false)
        #expect(!cancelPermitted)
        #expect(state.desired.contains(cancelKey))
    }

    @Test func inactiveParksRunningRequestEvenAfterWatchdogMovedItToDesired() throws {
        let key = try coordinatorKey("watchdog-inactive")
        var state = UnverifiedRevalidationCoordinator()
        let requestID = UUID()
        let began = state.begin(key, preservesOvertakenRequest: false)
        #expect(began)
        let token = state.started(key, requestID: requestID)
        let fired = state.timerFired(for: key, token: token, remainsUnverified: true)
        #expect(fired)
        #expect(state.inFlight.isEmpty)
        #expect(state.desired.contains(key))

        let running = state.parkRunningRequestsUntilActive()
        #expect(running == [key])
        #expect(state.desired.contains(key))
        #expect(state.requestIDs[key] == requestID)
    }

    @Test func staleOldFinishCannotClearNewSameKeyRequestGeneration() throws {
        let key = try coordinatorKey("generation")
        var state = UnverifiedRevalidationCoordinator()
        let oldID = UUID()
        let oldBegan = state.begin(key, preservesOvertakenRequest: false)
        #expect(oldBegan)
        _ = state.started(key, requestID: oldID)
        _ = state.gateDrained([key], sceneIsActive: true)

        let replacementBegan = state.begin(key, preservesOvertakenRequest: true)
        #expect(replacementBegan)
        let replacementID = UUID()
        _ = state.started(key, requestID: replacementID)
        let stale = state.finished(
            key, requestID: oldID, cancelled: false, remainsUnverified: true)
        #expect(stale == nil)
        #expect(state.inFlight.contains(key))
        #expect(state.requestIDs[key] == replacementID)

        let replacement = state.finished(
            key, requestID: replacementID, cancelled: false, remainsUnverified: false)
        #expect(replacement == nil)
        #expect(!state.inFlight.contains(key))
    }

    @Test func coordinatorBrokerRejectionRetriesPromptly() throws {
        let key = try coordinatorKey("broker")
        var state = UnverifiedRevalidationCoordinator()
        let requestID = UUID()
        let began = state.begin(key, preservesOvertakenRequest: true)
        #expect(began)
        _ = state.started(key, requestID: requestID)
        let retry = state.finished(
            key, requestID: requestID, cancelled: true, remainsUnverified: true)
        #expect(retry == .soon)
    }

    @Test func coordinatorInconclusiveProbeGetsOnlyOneDelayedAutomaticRetry() throws {
        let key = try coordinatorKey("inconclusive")
        var state = UnverifiedRevalidationCoordinator()
        let firstID = UUID()
        let firstBegin = state.begin(key, preservesOvertakenRequest: false)
        #expect(firstBegin)
        _ = state.started(key, requestID: firstID)
        let firstFinish = state.finished(
            key, requestID: firstID, cancelled: false, remainsUnverified: true)
        #expect(firstFinish == .delayed)
        let secondBegin = state.begin(key, preservesOvertakenRequest: false)
        #expect(secondBegin)
        let secondID = UUID()
        _ = state.started(key, requestID: secondID)
        let secondFinish = state.finished(
            key, requestID: secondID, cancelled: false, remainsUnverified: true)
        #expect(secondFinish == nil)
    }

    @Test func coordinatorWatchdogRequeuesRatherThanOnlyClearing() throws {
        let key = try coordinatorKey("watchdog")
        var state = UnverifiedRevalidationCoordinator()
        let requestID = UUID()
        let began = state.begin(key, preservesOvertakenRequest: false)
        #expect(began)
        let token = state.started(key, requestID: requestID)
        let fired = state.timerFired(for: key, token: token, remainsUnverified: true)
        #expect(fired)
        #expect(state.desired.contains(key))
        let retryBegan = state.begin(key, preservesOvertakenRequest: true)
        #expect(retryBegan)
    }

    @Test func coordinatorCancelRetriesButReplacementRejectsStaleCompletion() throws {
        let key = try coordinatorKey("cancel")
        var state = UnverifiedRevalidationCoordinator()
        let firstID = UUID()
        let firstBegin = state.begin(key, preservesOvertakenRequest: false)
        #expect(firstBegin)
        _ = state.started(key, requestID: firstID)
        let cancelled = state.finished(
            key, requestID: firstID, cancelled: true, remainsUnverified: true)
        #expect(cancelled == .soon)

        let replacementBegin = state.begin(key, preservesOvertakenRequest: false)
        #expect(replacementBegin)
        let replacementID = UUID()
        _ = state.started(key, requestID: replacementID)
        let staleFinish = state.finished(
            key, requestID: replacementID, cancelled: true, remainsUnverified: false)
        #expect(staleFinish == nil)
        #expect(!state.inFlight.contains(key))
        #expect(!state.desired.contains(key))
    }

    @Test func coordinatorStaleTimerCannotTouchReplacementAttempt() throws {
        let old = try coordinatorKey("old")
        var state = UnverifiedRevalidationCoordinator()
        let requestID = UUID()
        let began = state.begin(old, preservesOvertakenRequest: false)
        #expect(began)
        let token = state.started(old, requestID: requestID)
        let staleFire = state.timerFired(for: old, token: token, remainsUnverified: false)
        #expect(!staleFire)
        #expect(!state.inFlight.contains(old))
        let duplicateFire = state.timerFired(for: old, token: token, remainsUnverified: true)
        #expect(!duplicateFire)
    }

    @Test func pendingBackgroundHandlerDefersWithoutClaimingProbeAndDrainPublishesExactKeysOnce() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            let first = try seedUnverified("plex:first", in: store)
            let second = try seedUnverified("plex:second", in: store)
            let drained = LockedRevalidationDrainBox()
            session.onBackgroundCompletionGateDrained = { drained.append($0) }
            session.noteBackgroundCompletionHandlerStored(identifier: "wake")

            #expect(session.revalidateCompletedDownload(
                ratingKey: first.ratingKey, validationLabel: "test") == .deferredForBackgroundWake)
            #expect(session.revalidateCompletedDownload(
                ratingKey: second.ratingKey, validationLabel: "test") == .deferredForBackgroundWake)
            #expect(session.backgroundDeferredRevalidationKeysForTesting() == [first, second])

            // Models scene-active arriving during the same wake: it remains a cheap exact-key
            // deferral, not an AVFoundation finalizer claim or a second drain notification.
            #expect(session.revalidateCompletedDownload(
                ratingKey: first.ratingKey, validationLabel: "scene") == .deferredForBackgroundWake)
            session.finishBackgroundEventsForTesting(identifier: "wake")
            #expect(drained.values == [[first, second]])
            #expect(session.backgroundDeferredRevalidationKeysForTesting().isEmpty)

            session.finishBackgroundEventsForTesting(identifier: "wake")
            #expect(drained.values == [[first, second]])
        }
    }

    @Test func realProbeAdmissionDeduplicatesUntilExactClaimReleases() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let session = BackgroundDownloadSession(store: store, protocolClasses: [])
            defer { session.invalidateInjectedSessionForTesting() }
            let key = try seedUnverified("plex:dedupe", in: store)
            let request = LockedFinalizerRequestBox()
            session.onFinalizerRequest = { request.store($0) }

            guard case .started = session.revalidateCompletedDownload(
                ratingKey: key.ratingKey, validationLabel: "first") else {
                Issue.record("Expected first real probe admission"); return
            }
            #expect(session.revalidateCompletedDownload(
                ratingKey: key.ratingKey, validationLabel: "concurrent") == .alreadyFinalizing)

            session.abandonFinalizerRequest(try #require(request.value))
            guard case .started = session.revalidateCompletedDownload(
                ratingKey: key.ratingKey, validationLabel: "retry") else {
                Issue.record("Expected retry probe admission"); return
            }
            session.abandonFinalizerRequest(try #require(request.value))
        }
    }

    @Test func positivePlaybackStillPromotesExactUnverifiedAttempt() throws {
        try withDirectory { directory in
            let store = DownloadStore(baseDirectory: directory)
            let key = try seedUnverified("plex:play", in: store)
            #expect(store.markCompleteIfUnverified(for: key) == .promoted)
            #expect(store.record(for: key)?.status == .complete)
        }
    }

    private func seedUnverified(_ ratingKey: String, in store: DownloadStore) throws
        -> DownloadAttemptKey {
        let attemptID = try #require(DownloadAttemptID(rawValue: UUID().uuidString))
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: attemptID)
        let localURL = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        try Data("local-media".utf8).write(to: localURL)
        let record = DownloadRecord(
            ratingKey: ratingKey, attemptID: attemptID, title: "Local",
            localURL: localURL, bytes: 11, progress: 1, status: .unverified)
        #expect(store.createAttemptOwnedRecord(record, attemptID: attemptID) == .committed(key))
        return key
    }

    private func coordinatorKey(_ suffix: String) throws -> DownloadAttemptKey {
        DownloadAttemptKey(
            ratingKey: "plex:\(suffix)",
            attemptID: try #require(DownloadAttemptID(rawValue: "attempt-\(suffix)")))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unverified-revalidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private actor HeldRevalidationValidator {
    private(set) var attemptCount = 0
    private(set) var cancellationCount = 0
    private var succeeds = false

    func validate() async -> BackgroundDownloadSession.PlaybackValidation {
        attemptCount += 1
        while !succeeds {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                cancellationCount += 1
                return .init(played: false, reason: "cancelled", durationMs: nil, detail: nil)
            }
        }
        return .init(played: true, reason: "played", durationMs: 60_000, detail: nil)
    }

    func allowSuccess() { succeeds = true }

    func waitForAttempts(_ expected: Int) async -> Bool {
        for _ in 0..<200 {
            if attemptCount >= expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func waitForCancellations(_ expected: Int) async -> Bool {
        for _ in 0..<200 {
            if cancellationCount >= expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private final class LockedRevalidationDrainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Set<DownloadAttemptKey>] = []
    var values: [Set<DownloadAttemptKey>] { lock.withLock { storage } }
    func append(_ value: Set<DownloadAttemptKey>) { lock.withLock { storage.append(value) } }
}

private final class LockedFinalizerRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: BackgroundDownloadSession.FinalizerRequest?
    var value: BackgroundDownloadSession.FinalizerRequest? { lock.withLock { storage } }
    func store(_ value: BackgroundDownloadSession.FinalizerRequest) {
        lock.withLock { storage = value }
    }
}

/// D4 regression: the held-segment branch of `applyFinishedRangeBody` resolves its lifecycle
/// asynchronously, but the caller's background-completion gate operation ends when the apply
/// returns. Without a nested gate operation spanning that completion, the gate hits zero in the
/// gap, the OS handler fires, and the app suspends before the train slot is refilled — the
/// reopened #212 off-head stall.
@Suite("Held-range body completion gate")
struct HeldRangeBodyCompletionGateTests {
    @Test @MainActor
    func heldBodyLifecycleHoldsCompletionGateUntilTrainSlotIsReplanned() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-body-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writes = BlockingIndexWriteGate()
        let store = DownloadStore(
            baseDirectory: directory,
            indexPersistence: .init { data, url in try writes.write(data, to: url) })
        let attemptID = try #require(DownloadAttemptID(rawValue: "held-gate-a"))
        let key = DownloadAttemptKey(ratingKey: "plex:held-gate", attemptID: attemptID)
        let stable = store.destinationURL(ratingKey: key.ratingKey, ext: "mp4")
        let record = DownloadRecord(
            ratingKey: key.ratingKey, attemptID: attemptID, title: "Held Gate",
            localURL: stable, bytes: 8, progress: 0.08, status: .downloading,
            metadata: OfflineMetadata(
                ratingKey: key.ratingKey, title: "Held Gate", type: "movie",
                resumeMode: .staticByteRange))
        #expect(store.createAttemptOwnedRecord(record, attemptID: attemptID) == .committed(key))
        let working = try #require(store.attemptWorkingFileURL(for: key))
        try Data(repeating: 0x5A, count: 8).write(to: working)

        let session = BackgroundDownloadSession(store: store, protocolClasses: [])
        defer { session.invalidateInjectedSessionForTesting() }
        let rebuildNeeded = DispatchSemaphore(value: 0)
        session.onRangeRequestNeeded = { _, _ in rebuildNeeded.signal() }

        // A stored (unfired) OS background-completion handler is the precondition: the gate is
        // what keeps it — and the app — alive until the next task/hold exists.
        let identifier = "held-gate-\(UUID().uuidString)"
        let fired = DispatchSemaphore(value: 0)
        let completionToken = BackgroundDownloadCompletionRegistry.shared.store(
            identifier: identifier, completion: { fired.signal() })
        defer {
            BackgroundDownloadCompletionRegistry.shared.fireCompletions(in: .init(
                identifier: identifier,
                tokens: [completionToken]
            ))
        }
        session.noteBackgroundCompletionHandlerStored(
            identifier: identifier,
            token: completionToken
        )

        // Off-head segment: durable working file (8 bytes) is behind this closed segment's
        // baseOffset (30), so the body takes the durable-hold branch.
        let stash = directory.appendingPathComponent("held-gate-stash.bin")
        try Data([1, 2, 3, 4]).write(to: stash)
        writes.arm()
        let applied = DispatchSemaphore(value: 0)
        session.applyFinishedHeldRangeBodyForTesting(
            attemptKey: key, workingURL: working, expectedBytes: 100,
            baseOffset: 30, segmentLength: 4, stash: stash, contentRangeStart: 30,
            onApplied: { applied.signal() })

        // The held-manifest persist is now blocked inside the index writer, and the apply — with
        // it the caller's gate operation — has returned. The decisive #212 window: the nested
        // operation begun before the apply returned must keep the gate open.
        #expect(await waitForSignal(writes.entered, timeout: 5))
        #expect(await waitForSignal(applied, timeout: 5))
        #expect(session.diagnosticSnapshot().pendingBackgroundCompletionOperationCount == 1)
        #expect(await waitForSignal(fired, timeout: 0) == false)

        // Releasing the writer lets the lifecycle complete; its completion replans the train
        // (request rebuild grace) BEFORE ending the nested operation, so the gate never drains.
        writes.release.signal()
        #expect(await waitForSignal(rebuildNeeded, timeout: 5))
        var settled = false
        for _ in 0..<200 {
            if session.diagnosticSnapshot().pendingBackgroundCompletionOperationCount == 1 {
                settled = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(settled, "rebuild-grace hold must overlap the held-lifecycle completion")
        #expect(await waitForSignal(fired, timeout: 0) == false)
        #expect(store.metadata(for: key.ratingKey)?.heldRangeSegments?.map(\.offset) == [30])
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

/// Blocks exactly the first index write after `arm()` (signalling `entered`) until `release` is
/// signalled; every other write commits through the live committer.
private final class BlockingIndexWriteGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false

    func arm() { lock.withLock { armed = true } }

    func write(_ data: Data, to url: URL) throws {
        let shouldBlock = lock.withLock {
            let wasArmed = armed
            armed = false
            return wasArmed
        }
        if shouldBlock {
            entered.signal()
            release.wait()
        }
        try DownloadIndexFileCommitter().commit(data, to: url)
    }
}
