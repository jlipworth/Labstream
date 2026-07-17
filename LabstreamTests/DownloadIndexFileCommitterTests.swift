import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Download index explicit file committer")
struct DownloadIndexFileCommitterTests {
    @Test func atomicallyReplacesCanonicalBytesAndLeavesNoTemporaryFile() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            try Data("old".utf8).write(to: destination)

            try DownloadIndexFileCommitter().commit(Data("new".utf8), to: destination)

            #expect(try Data(contentsOf: destination) == Data("new".utf8))
            #expect(try commitTemps(in: directory).isEmpty)
            #expect(try destination.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup == true)
            if CredentialArtifactStorage.supportsFileProtectionAttributes {
                #if targetEnvironment(simulator)
                // The iOS/visionOS simulators accept the protection attribute but omit it from
                // `attributesOfItem`; a signed physical-platform run performs the readback.
                #else
                let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                #expect(attributes[.protectionKey] as? FileProtectionType
                        == CredentialArtifactStorage.authArtifactProtection)
                #endif
            }
        }
    }

    @Test func failureBeforeReplacePreservesCanonicalAndCleansTemporaryFile() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            try Data("old".utf8).write(to: destination)
            let committer = DownloadIndexFileCommitter(stageHook: { stage in
                if stage == .beforeReplace { throw InjectedFailure() }
            })

            #expect(throws: DownloadIndexFileCommitter.CommitFailure.self) {
                try committer.commit(Data("new".utf8), to: destination)
            }
            #expect(try Data(contentsOf: destination) == Data("old".utf8))
            #expect(try commitTemps(in: directory).isEmpty)
        }
    }

    @Test func failureAfterTempWritePreservesCanonicalAndCleansTemporaryFile() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            try Data("old".utf8).write(to: destination)
            let committer = DownloadIndexFileCommitter(stageHook: { stage in
                if stage == .afterTempWrite { throw InjectedFailure() }
            })

            do {
                try committer.commit(Data("new".utf8), to: destination)
                Issue.record("expected injected temp-write failure")
            } catch let failure as DownloadIndexFileCommitter.CommitFailure {
                #expect(failure.stage == .afterTempWrite)
                #expect(!failure.replacementMayHaveOccurred)
            }
            #expect(try Data(contentsOf: destination) == Data("old".utf8))
            #expect(try commitTemps(in: directory).isEmpty)
        }
    }

    @Test func failureAfterReplaceReportsAmbiguityAndRetainsNewCanonical() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            try Data("old".utf8).write(to: destination)
            let committer = DownloadIndexFileCommitter(stageHook: { stage in
                if stage == .afterReplace { throw InjectedFailure() }
            })

            do {
                try committer.commit(Data("new".utf8), to: destination)
                Issue.record("expected injected post-replace failure")
            } catch let failure as DownloadIndexFileCommitter.CommitFailure {
                #expect(failure.stage == .afterReplace)
                #expect(failure.replacementMayHaveOccurred)
            }
            #expect(try Data(contentsOf: destination) == Data("new".utf8))
            #expect(try commitTemps(in: directory).isEmpty)
        }
    }

    @Test func startupRecoverySweepsOnlyAgedAbandonedSiblingTemps() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            let stale = directory.appendingPathComponent(".index.json.commit-stale")
            let active = directory.appendingPathComponent(".index.json.commit-active")
            try Data("stale".utf8).write(to: stale)
            try Data("active".utf8).write(to: active)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-7_200)],
                ofItemAtPath: stale.path)

            try DownloadIndexFileCommitter.cleanupAbandonedTemps(for: destination)

            #expect(!FileManager.default.fileExists(atPath: stale.path))
            #expect(FileManager.default.fileExists(atPath: active.path))
        }
    }

    @Test func fullSyncFailurePreservesOldCanonical() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            try Data("old".utf8).write(to: destination)
            let committer = DownloadIndexFileCommitter(
                durability: .init(
                    fullSync: { _ in EIO },
                    directorySync: { _ in nil }))

            do {
                try committer.commit(Data("new".utf8), to: destination)
                Issue.record("expected full-sync failure")
            } catch let failure as DownloadIndexFileCommitter.CommitFailure {
                #expect(failure.stage == .afterTempWrite)
                #expect(failure.errnoCode == EIO)
                #expect(!failure.replacementMayHaveOccurred)
            }
            #expect(try Data(contentsOf: destination) == Data("old".utf8))
        }
    }

    @Test func directorySyncFailureReportsPostReplaceAmbiguity() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("index.json")
            try Data("old".utf8).write(to: destination)
            let committer = DownloadIndexFileCommitter(
                durability: .init(
                    fullSync: { _ in nil },
                    directorySync: { _ in EIO }))

            do {
                try committer.commit(Data("new".utf8), to: destination)
                Issue.record("expected directory-sync failure")
            } catch let failure as DownloadIndexFileCommitter.CommitFailure {
                #expect(failure.stage == .afterReplace)
                #expect(failure.errnoCode == EIO)
                #expect(failure.replacementMayHaveOccurred)
            }
            #expect(try Data(contentsOf: destination) == Data("new".utf8))
        }
    }

    @Test func postReplaceFailureRemainsDirtyAndRetriesThroughStoreFlush() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadIndexFileCommitterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oneShot = OneShotFlag()
        let persistence = DownloadStore.IndexPersistence { data, url in
            let fail = oneShot.consume()
            try DownloadIndexFileCommitter(stageHook: { stage in
                if fail, stage == .afterReplace { throw InjectedFailure() }
            }).commit(data, to: url)
        }
        let store = DownloadStore(
            baseDirectory: directory,
            indexPersistence: persistence)
        let destination = store.destinationURL(ratingKey: "plex:ambiguous", ext: "mp4")
        store.upsert(DownloadRecord(
            ratingKey: "plex:ambiguous",
            title: "Ambiguous",
            localURL: destination,
            status: .queued))
        let ticket = store.currentPersistenceTicket()

        let result = await store.flushPersistence(through: ticket, timeout: 1)

        if case .committed(let revision) = result {
            #expect(revision >= ticket.revision)
        } else {
            Issue.record("dirty post-replace revision did not commit on retry: \(result)")
        }
        #expect(DownloadStore(baseDirectory: directory)
            .record(for: "plex:ambiguous") != nil)
    }

    private func commitTemps(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".index.json.commit-") }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadIndexFileCommitterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private struct InjectedFailure: Error {}

    private final class OneShotFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true

        func consume() -> Bool {
            lock.withLock {
                defer { value = false }
                return value
            }
        }
    }
}
