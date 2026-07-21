import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("DownloadStore attempt staging")
struct DownloadStoreAttemptStagingTests {
    @Test func validatedPromotionPreparedFailureKeepsWorkingAuthorityAndRetries() throws {
        try withStore { initial, directory in
            let owner = key("plex:promotion-prepared-failure", "attempt-a")
            let stable = directory.appendingPathComponent("promotion-prepared-failure.mp4")
            try Data("old-stable".utf8).write(to: stable)
            #expect(created(initial, key: owner, stable: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)
            let writes = FailPromotionWriteNth(1)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            guard case .persistenceFailed = store.promoteValidatedAttempt(
                for: owner, terminalStatus: .complete) else {
                Issue.record("expected prepared failure"); return
            }
            #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self) == "old-stable")
            #expect(String(decoding: try Data(contentsOf: working), as: UTF8.self) == "validated")
            #expect(store.promoteValidatedAttempt(for: owner, terminalStatus: .complete)
                == .promoted(owner, bytes: 9, status: .complete))
        }
    }

    @Test func validatedPromotionTerminalFailureRestoresAndRetriesSameProcess() throws {
        try withStore { initial, directory in
            let owner = key("plex:promotion-terminal-failure", "attempt-a")
            let stable = directory.appendingPathComponent("promotion-terminal-failure.mp4")
            #expect(created(initial, key: owner, stable: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)
            let writes = FailPromotionWriteNth(3)
            let store = DownloadStore(
                baseDirectory: directory,
                indexPersistence: .init { data, url in try writes.write(data, to: url) })
            guard case .persistenceFailed = store.promoteValidatedAttempt(
                for: owner, terminalStatus: .complete) else {
                Issue.record("expected terminal failure"); return
            }
            #expect(!FileManager.default.fileExists(atPath: working.path))
            #expect(store.promoteValidatedAttempt(for: owner, terminalStatus: .complete)
                == .promoted(owner, bytes: 9, status: .complete))
        }
    }

    @Test func validatedPromotionRenameRunsOffStoreLockBehindNonblockingTicket() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:promotion-off-lock", "attempt-a")
            let stable = directory.appendingPathComponent("promotion-off-lock.mp4")
            #expect(created(initial, key: owner, stable: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)
            let gate = BlockingPromotionRename()
            let live = DownloadPromotionFilesystem.live
            let store = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists, size: live.size,
                    fullSyncSource: live.fullSyncSource,
                    renameReplacing: { source, destination in
                        try gate.rename(source, destination, using: live.renameReplacing)
                    },
                    syncParentDirectory: live.syncParentDirectory))
            let submission = store.submitValidatedPromotion(
                for: owner, terminalStatus: .complete)
            #expect(await wait(gate.blocked, timeout: 1))
            let read = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = store.records; read.signal() }
            #expect(await wait(read, timeout: 0.25))
            gate.release.signal()
            #expect(await store.resolveValidatedPromotion(submission)
                == .promoted(owner, bytes: 9, status: .complete))
        }
    }

    @Test func validatedPromotionReplaysHardKillWindowAfterRenameBeforeTerminal() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:promotion-hard-kill", "attempt-a")
            let stable = directory.appendingPathComponent("promotion-hard-kill.mp4")
            try Data("old".utf8).write(to: stable)
            #expect(created(initial, key: owner, stable: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)
            let gate = BlockAfterPromotionRename()
            let live = DownloadPromotionFilesystem.live
            let original = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists, size: live.size,
                    fullSyncSource: live.fullSyncSource,
                    renameReplacing: { source, destination in
                        try gate.rename(source, destination, using: live.renameReplacing)
                    },
                    syncParentDirectory: live.syncParentDirectory))
            let submission = original.submitValidatedPromotion(
                for: owner, terminalStatus: .complete)
            #expect(await wait(gate.renamed, timeout: 1))
            #expect(!FileManager.default.fileExists(atPath: working.path))
            #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self) == "validated")

            let replayDurability = PromotionDurabilityRecorder()
            let relaunched = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists, size: live.size,
                    fullSyncSource: live.fullSyncSource,
                    renameReplacing: live.renameReplacing,
                    syncParentDirectory: { url in
                        try replayDurability.run("directory-sync") {
                            try live.syncParentDirectory(url)
                        }
                    }))
            #expect(relaunched.resolveArtifactSynchronouslyForTests(
                through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
            #expect(relaunched.record(for: owner)?.status == .complete)
            #expect(relaunched.record(for: owner)?.bytes == 9)
            #expect(replayDurability.events == ["directory-sync"])
            gate.release.signal()
            #expect(await original.resolveValidatedPromotion(submission)
                == .promoted(owner, bytes: 9, status: .complete))
        }
    }

    @Test func sourceAbsentReplayRequiresDirectorySyncBeforeTerminalPublication() async throws {
        try await withStoreAsync { initial, directory in
            let owner = key("plex:promotion-replay-dir-sync", "attempt-a")
            let stable = directory.appendingPathComponent("promotion-replay-dir-sync.mp4")
            #expect(created(initial, key: owner, stable: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)
            let gate = BlockAfterPromotionRename()
            let live = DownloadPromotionFilesystem.live
            let original = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists, size: live.size,
                    fullSyncSource: live.fullSyncSource,
                    renameReplacing: { source, destination in
                        try gate.rename(source, destination, using: live.renameReplacing)
                    },
                    syncParentDirectory: live.syncParentDirectory))
            let submission = original.submitValidatedPromotion(
                for: owner, terminalStatus: .complete)
            #expect(await wait(gate.renamed, timeout: 1))

            let failingReplay = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists, size: live.size,
                    fullSyncSource: live.fullSyncSource,
                    renameReplacing: live.renameReplacing,
                    syncParentDirectory: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
            guard case .failed(.artifact) = failingReplay.resolveArtifactSynchronouslyForTests(
                through: failingReplay.currentArtifactLifecycleWatermark()) else {
                Issue.record("replay must fail closed when directory sync fails"); return
            }
            let index = try #require(JSONSerialization.jsonObject(with: Data(
                contentsOf: directory.appendingPathComponent("index.json"))) as? [String: Any])
            let rows = try #require(index["rows"] as? [[String: Any]])
            #expect(rows.first?["status"] as? String == "queued")
            let survivor = DownloadStore(baseDirectory: directory)
            #expect(survivor.resolveArtifactSynchronouslyForTests(
                through: survivor.currentArtifactLifecycleWatermark()) == .completed)
            #expect(survivor.record(for: owner)?.status == .complete)
            gate.release.signal()
            _ = await original.resolveValidatedPromotion(submission)
        }
    }

    @Test func validatedPromotionDurabilityOrdersFileSyncRenameThenDirectorySync() throws {
        try withStore { initial, directory in
            let owner = key("plex:promotion-durability-order", "attempt-a")
            let stable = directory.appendingPathComponent("promotion-durability-order.mp4")
            #expect(created(initial, key: owner, stable: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)
            let recorder = PromotionDurabilityRecorder()
            let live = DownloadPromotionFilesystem.live
            let store = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists, size: live.size,
                    fullSyncSource: { url in
                        try recorder.run("file-sync") { try live.fullSyncSource(url) }
                    },
                    renameReplacing: { source, destination in
                        try recorder.run("rename") {
                            try live.renameReplacing(source, destination)
                        }
                    },
                    syncParentDirectory: { url in
                        try recorder.run("directory-sync") {
                            try live.syncParentDirectory(url)
                        }
                    }))
            #expect(store.promoteValidatedAttempt(for: owner, terminalStatus: .complete)
                == .promoted(owner, bytes: 9, status: .complete))
            #expect(recorder.events == ["file-sync", "rename", "directory-sync"])
        }
    }

    @Test func validatedPromotionFullSyncFailureNeverRenames() throws {
        try withStore { initial, directory in
            let owner = key("plex:promotion-sync-failure", "attempt-a")
            let stable = directory.appendingPathComponent("promotion-sync-failure.mp4")
            try Data("old".utf8).write(to: stable)
            #expect(created(initial, key: owner, stable: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)
            let live = DownloadPromotionFilesystem.live
            let store = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists, size: live.size,
                    fullSyncSource: { _ in throw CocoaError(.fileWriteOutOfSpace) },
                    renameReplacing: { _, _ in
                        Issue.record("rename must not run after sync failure")
                    },
                    syncParentDirectory: { _ in
                        Issue.record("directory sync must not run after sync failure")
                    }))
            guard case .renameFailed = store.promoteValidatedAttempt(
                for: owner, terminalStatus: .complete) else {
                Issue.record("expected sync failure"); return
            }
            #expect(FileManager.default.fileExists(atPath: working.path))
            #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self) == "old")
        }
    }

    @Test func legacyPendingPromotionRecoveryUsesDurableFilesystemOrdering() throws {
        try withStore { initial, directory in
            let owner = key("plex:legacy-promotion-recovery", "attempt-a")
            let stable = directory.appendingPathComponent("legacy-promotion-recovery.mp4")
            #expect(created(initial, key: owner, stable: stable))
            let working = try #require(initial.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)
            let indexURL = directory.appendingPathComponent("index.json")
            var object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
            var rows = try #require(object["rows"] as? [[String: Any]])
            rows[0]["pendingValidatedPromotionStatus"] = "complete"
            object["rows"] = rows
            try JSONSerialization.data(withJSONObject: object).write(to: indexURL, options: .atomic)

            let recorder = PromotionDurabilityRecorder()
            let live = DownloadPromotionFilesystem.live
            let store = DownloadStore(
                baseDirectory: directory,
                promotionFilesystem: .init(
                    exists: live.exists, size: live.size,
                    fullSyncSource: { url in
                        try recorder.run("file-sync") { try live.fullSyncSource(url) }
                    },
                    renameReplacing: { source, destination in
                        try recorder.run("rename") {
                            try live.renameReplacing(source, destination)
                        }
                    },
                    syncParentDirectory: { url in
                        try recorder.run("directory-sync") {
                            try live.syncParentDirectory(url)
                        }
                    }))
            #expect(store.recoverPendingValidatedPromotion(for: owner)
                == .promoted(owner, bytes: 9, status: .complete))
            #expect(recorder.events == ["file-sync", "rename", "directory-sync"])
        }
    }

    @Test func stagingNamesAreDeterministicPathSafeAndAttemptScoped() throws {
        try withStore { store, directory in
            let a = key("plex:item/unsafe", "attempt/a")
            let b = key("plex:item/unsafe", "attempt?a")
            let media = store.destinationURL(ratingKey: a.ratingKey, ext: "mp4")
            let poster = store.posterDestinationURL(ratingKey: a.ratingKey)
            let first = try #require(store.attemptStagingURL(for: a, stableURL: media))

            #expect(store.attemptStagingURL(for: a, stableURL: media) == first)
            #expect(store.attemptStagingURL(for: b, stableURL: media) != first)
            #expect(store.attemptStagingURL(for: a, stableURL: poster) != first)
            #expect(first.deletingLastPathComponent() == directory)
            #expect(first.lastPathComponent.range(
                of: #"^\.attempt-stage-v1-[0-9a-f]{64}\.stage$"#,
                options: .regularExpression) != nil)
            #expect(store.attemptStagingURL(
                for: a, stableURL: directory.deletingLastPathComponent()
                    .appendingPathComponent("outside.mp4")) == nil)
        }
    }

    @Test func staleAttemptCannotReplaceNewOwnersStableFile() throws {
        try withStore { store, directory in
            let a = key("emby:item", "attempt-a")
            let b = key("emby:item", "attempt-b")
            let stable = store.destinationURL(ratingKey: a.ratingKey, ext: "mp4")
            try Data("stable-before".utf8).write(to: stable)
            #expect(created(store, key: a, stable: stable))
            let stageA = try #require(store.attemptStagingURL(for: a, stableURL: stable))
            try Data("attempt-a".utf8).write(to: stageA)

            #expect(created(store, key: b, stable: stable, replacing: a.attemptID))
            #expect(store.promoteAttemptStagingFile(for: a, stagingURL: stageA, to: stable)
                    == .staleOrMissingOwner)
            #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self) == "stable-before")
            #expect(!FileManager.default.fileExists(atPath: stageA.path))

            let stageB = try #require(store.attemptStagingURL(for: b, stableURL: stable))
            #expect(String(decoding: try Data(contentsOf: stageB), as: UTF8.self) == "attempt-a")
            try Data("attempt-b".utf8).write(to: stageB)
            #expect(store.promoteAttemptStagingFile(for: b, stagingURL: stageB, to: stable)
                    == .promoted)
            #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self) == "attempt-b")
            #expect(!FileManager.default.fileExists(atPath: stageB.path))
            #expect(store.record(for: b) != nil)
        }
    }

    @Test func workingLayoutIsDurableExactOwnerMetadataWhileRecordPublishesStableURL() throws {
        try withStore { store, directory in
            let owner = key("plex:durable-working", "attempt-a")
            let stable = store.destinationURL(ratingKey: owner.ratingKey, ext: "mp4")
            #expect(created(store, key: owner, stable: stable))
            let initial = try #require(store.attemptWorkingFileLayout(for: owner))
            #expect(initial.stableURL == stable)
            #expect(initial.workingURL != stable)
            #expect(store.record(for: owner)?.localURL == stable)

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.attemptWorkingFileLayout(for: owner) == initial)
            #expect(relaunched.record(for: owner)?.localURL == stable)
            #expect(relaunched.attemptWorkingFileURL(
                for: key(owner.ratingKey, "attempt-b")) == nil)
        }
    }

    @Test func validatedPromotionPublishesAndTerminalsOneExactOwnerAtomically() throws {
        try withStore { store, directory in
            let owner = key("emby:promote", "attempt-a")
            let stable = store.destinationURL(ratingKey: owner.ratingKey, ext: "mp4")
            try Data("old-stable-junk".utf8).write(to: stable)
            #expect(created(store, key: owner, stable: stable))
            let working = try #require(store.attemptWorkingFileURL(for: owner))
            try Data("validated".utf8).write(to: working)

            #expect(store.promoteValidatedAttempt(for: owner, terminalStatus: .complete)
                    == .promoted(owner, bytes: 9, status: .complete))
            #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self) == "validated")
            #expect(!FileManager.default.fileExists(atPath: working.path))
            #expect(store.attemptWorkingFileLayout(for: owner) == nil)
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.record(for: owner)?.status == .complete)
            #expect(relaunched.record(for: owner)?.bytes == 9)
            #expect(relaunched.record(for: owner)?.localURL == stable)
        }
    }

    @Test func durableValidatedIntentRecoversRenameToTerminalCommitCrashWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-promotion-recovery-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = PromotionWriteCounter()
        let owner = key("plex:promotion-crash", "attempt-a")
        let store = DownloadStore(
            baseDirectory: directory,
            indexPersistence: .init { data, url in
                let count = writes.next()
                if count == 4 { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            })
        let stable = store.destinationURL(ratingKey: owner.ratingKey, ext: "mp4")
        try Data("old-owner".utf8).write(to: stable)
        #expect(created(store, key: owner, stable: stable)) // write 1: row
        let working = try #require(store.attemptWorkingFileURL(for: owner))
        try Data("validated-owner-a".utf8).write(to: working)

        // Writes 2–3 durably record the intent and captured source size; rename succeeds; write 4 fails before the
        // terminal row can replace that intent on disk.
        guard case .persistenceFailed(let failedKey, _) = store.promoteValidatedAttempt(
            for: owner, terminalStatus: .complete) else {
            Issue.record("Expected injected terminal snapshot failure")
            return
        }
        #expect(failedKey == owner)
        #expect(!FileManager.default.fileExists(atPath: working.path))
        #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self)
                == "validated-owner-a")

        let relaunched = DownloadStore(baseDirectory: directory)
        #expect(relaunched.resolveArtifactSynchronouslyForTests(
            through: relaunched.currentArtifactLifecycleWatermark()) == .completed)
        #expect(relaunched.record(for: owner)?.status == .complete)
        #expect(relaunched.record(for: owner)?.bytes == 17)
        let verified = DownloadStore(baseDirectory: directory)
        #expect(verified.record(for: owner)?.status == .complete)
        #expect(verified.record(for: owner)?.bytes == 17)
        #expect(verified.attemptWorkingFileLayout(for: owner) == nil)
    }

    @Test func genericUpsertDerivesNewOwnersWorkingPathInsteadOfInheritingOldOwner() throws {
        try withStore { store, _ in
            let a = key("plex:upsert-owner", "attempt-a")
            let b = key("plex:upsert-owner", "attempt-b")
            let stable = store.destinationURL(ratingKey: a.ratingKey, ext: "mp4")
            #expect(created(store, key: a, stable: stable))
            let workingA = try #require(store.attemptWorkingFileURL(for: a))
            store.upsert(DownloadRecord(
                ratingKey: b.ratingKey, attemptID: b.attemptID, title: "B",
                localURL: stable, status: .queued,
                metadata: OfflineMetadata(ratingKey: b.ratingKey, title: "B", type: "movie")))
            let workingB = try #require(store.attemptWorkingFileURL(for: b))
            #expect(workingB != workingA)
            #expect(store.attemptWorkingFileURL(for: a) == nil)
        }
    }

    @Test func relaunchInventoryAndSweepSelectOnlyUnreferencedAttemptStaging() throws {
        try withStore { store, directory in
            let owned = key("jellyfin:owned", "owned-attempt")
            let orphan = key("jellyfin:orphan", "orphan-attempt")
            let ownedStable = store.destinationURL(ratingKey: owned.ratingKey, ext: "mkv")
            let orphanStable = store.destinationURL(ratingKey: orphan.ratingKey, ext: "mkv")
            #expect(created(store, key: owned, stable: ownedStable))
            let ownedStage = try #require(store.attemptStagingURL(for: owned, stableURL: ownedStable))
            let orphanStage = try #require(store.attemptStagingURL(for: orphan, stableURL: orphanStable))
            let heldStable = store.heldRangeSegmentDestinationURL(
                ratingKey: owned.ratingKey, offset: 512)
            let heldStage = try #require(store.attemptStagingURL(for: owned, stableURL: heldStable))
            try Data("owned".utf8).write(to: ownedStage)
            try Data("orphan".utf8).write(to: orphanStage)
            try Data("held".utf8).write(to: heldStage)
            guard case .accepted = store.persistHeldRangeSegment(
                for: owned,
                segment: OfflineHeldRangeSegment(
                    offset: 512, length: 4, validator: nil,
                    relativePath: heldStage.lastPathComponent,
                    attemptID: owned.attemptID.rawValue)) else {
                Issue.record("Expected held manifest persistence")
                return
            }
            let unrelated = directory.appendingPathComponent(".attempt-stage-v1-not-a-digest.stage")
            try Data("unrelated".utf8).write(to: unrelated)

            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.unreferencedAttemptStagingURLs().map(\.lastPathComponent)
                    == [orphanStage.lastPathComponent])
            #expect(relaunched.unreferencedAttemptStagingURLs(
                additionalReferencedRelativePaths: [orphanStage.lastPathComponent]).isEmpty)

            let result = relaunched.sweepUnreferencedAttemptStaging()
            #expect(result.removedRelativePaths == [orphanStage.lastPathComponent])
            #expect(result.failedRelativePaths.isEmpty)
            #expect(FileManager.default.fileExists(atPath: ownedStage.path))
            #expect(FileManager.default.fileExists(atPath: heldStage.path))
            #expect(FileManager.default.fileExists(atPath: unrelated.path))
            #expect(!FileManager.default.fileExists(atPath: orphanStage.path))
        }
    }

    @Test func startupSweepDefersStagingBornDuringCurrentStoreLifetime() throws {
        try withStore { store, directory in
            let orphan = key("plex:late-side-write", "attempt-a")
            let stable = store.posterDestinationURL(ratingKey: orphan.ratingKey)
            let staging = try #require(store.attemptStagingURL(for: orphan, stableURL: stable))
            try Data("writer-in-flight".utf8).write(to: staging)

            #expect(store.sweepUnreferencedAttemptStaging().removedRelativePaths.isEmpty)
            #expect(FileManager.default.fileExists(atPath: staging.path))

            // A subsequent launch has a later cutoff and can prove the unadopted file predates all
            // writers in that process.
            Thread.sleep(forTimeInterval: 0.01)
            let relaunched = DownloadStore(baseDirectory: directory)
            #expect(relaunched.sweepUnreferencedAttemptStaging().removedRelativePaths
                == [staging.lastPathComponent])
            #expect(!FileManager.default.fileExists(atPath: staging.path))
        }
    }

    @Test func validatedPromotionDurabilityWaitDoesNotBlockUnrelatedStoreReaders() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-promotion-lock-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = BlockingPromotionWriter()
        let owner = key("plex:promotion-reader", "attempt-a")
        let store = DownloadStore(
            baseDirectory: directory,
            indexPersistence: .init { data, url in try writes.write(data, to: url) })
        let stable = store.destinationURL(ratingKey: owner.ratingKey, ext: "mp4")
        #expect(created(store, key: owner, stable: stable))
        let working = try #require(store.attemptWorkingFileURL(for: owner))
        try Data("validated".utf8).write(to: working)

        let promotionReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            _ = store.promoteValidatedAttempt(for: owner, terminalStatus: .complete)
            promotionReturned.signal()
        }
        #expect(await wait(writes.blocked, timeout: 1))

        let readReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            _ = store.records
            readReturned.signal()
        }
        #expect(await wait(readReturned, timeout: 0.2))
        writes.release.signal()
        #expect(await wait(promotionReturned, timeout: 1))
        #expect(store.record(for: owner)?.status == .complete)
    }

    @Test func sideCacheTailDeletesOnlyStaleAttemptsStaging() throws {
        try withStore { store, _ in
            let a = key("plex:side-cache", "attempt-a")
            let b = key("plex:side-cache", "attempt-b")
            let stable = store.posterDestinationURL(ratingKey: a.ratingKey)
            try Data("owner-b".utf8).write(to: stable)
            #expect(created(store, key: a, stable: stable))
            let sourceA = try #require(store.sideAssetSourceIdentity(for: a))
            let staging = try #require(store.attemptStagingURL(for: a, stableURL: stable))
            try Data("stale-a".utf8).write(to: staging)
            #expect(created(store, key: b, stable: stable, replacing: a.attemptID))

            #expect(!DownloadManager.promoteSideAsset(store: store, key: a,
                                                      expectedSource: sourceA,
                                                      stagingURL: staging, stableURL: stable))
            #expect(!FileManager.default.fileExists(atPath: staging.path))
            #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self) == "owner-b")
            #expect(store.updateMetadata(for: a) { $0.posterRelativePath = stable.lastPathComponent }
                    == .staleOrMissing)
            #expect(store.record(for: b)?.metadata?.posterRelativePath == nil)
        }
    }

    @Test func embyBIFPromotionIsFencedFromReplacementAttempt() throws {
        try withStore { store, _ in
            let a = key("emby:side-cache", "attempt-a")
            let b = key("emby:side-cache", "attempt-b")
            let stable = store.embyBIFDestinationURL(ratingKey: a.ratingKey)
            try Data("owner-b".utf8).write(to: stable)
            #expect(created(store, key: a, stable: stable))
            let sourceA = try #require(store.sideAssetSourceIdentity(for: a))
            let staging = try #require(store.attemptStagingURL(for: a, stableURL: stable))
            try Data("stale-a".utf8).write(to: staging)
            #expect(created(store, key: b, stable: stable, replacing: a.attemptID))

            #expect(!DownloadManager.promoteSideAsset(store: store, key: a,
                                                      expectedSource: sourceA,
                                                      stagingURL: staging, stableURL: stable))
            #expect(!FileManager.default.fileExists(atPath: staging.path))
            #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self) == "owner-b")
            #expect(store.updateMetadata(for: a) {
                $0.embyBIFRelativePath = stable.lastPathComponent
            } == .staleOrMissing)
            #expect(store.record(for: b)?.metadata?.embyBIFRelativePath == nil)
        }
    }

    private func key(_ ratingKey: String, _ attempt: String) -> DownloadAttemptKey {
        DownloadAttemptKey(ratingKey: ratingKey,
                           attemptID: DownloadAttemptID(rawValue: attempt)!)
    }

    private func created(_ store: DownloadStore, key: DownloadAttemptKey, stable: URL,
                         replacing: DownloadAttemptID? = nil) -> Bool {
        let record = DownloadRecord(ratingKey: key.ratingKey, attemptID: key.attemptID,
                                    title: "Item", localURL: stable, status: .queued,
                                    metadata: OfflineMetadata(
                                        ratingKey: key.ratingKey, title: "Item", type: "movie"))
        if case .committed(let actual) = store.createAttemptOwnedRecord(
            record, attemptID: key.attemptID, replacing: replacing) {
            return actual == key
        }
        return false
    }

    private func withStore(_ body: (DownloadStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(DownloadStore(baseDirectory: directory), directory)
    }

    private func withStoreAsync(
        _ body: (DownloadStore, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(DownloadStore(baseDirectory: directory), directory)
    }

    private func wait(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning:
                    semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }
}

private final class PromotionWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class BlockingPromotionWriter: @unchecked Sendable {
    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0

    func write(_ data: Data, to url: URL) throws {
        let shouldBlock = lock.withLock {
            count += 1
            return count == 2
        }
        if shouldBlock {
            blocked.signal()
            release.wait()
        }
        try data.write(to: url, options: .atomic)
    }
}

private final class FailPromotionWriteNth: @unchecked Sendable {
    private let lock = NSLock()
    private let failure: Int
    private var count = 0
    init(_ failure: Int) { self.failure = failure }
    func write(_ data: Data, to url: URL) throws {
        let fail = lock.withLock { count += 1; return count == failure }
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}

private final class BlockingPromotionRename: @unchecked Sendable {
    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func rename(
        _ source: URL,
        _ destination: URL,
        using body: @Sendable (URL, URL) throws -> Void
    ) throws {
        blocked.signal()
        release.wait()
        try body(source, destination)
    }
}

private final class BlockAfterPromotionRename: @unchecked Sendable {
    let renamed = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func rename(
        _ source: URL,
        _ destination: URL,
        using body: @Sendable (URL, URL) throws -> Void
    ) throws {
        try body(source, destination)
        renamed.signal()
        release.wait()
    }
}

private final class PromotionDurabilityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var events: [String] { lock.withLock { storage } }
    func run(_ event: String, _ body: () throws -> Void) throws {
        lock.withLock { storage.append(event) }
        try body()
    }
}
