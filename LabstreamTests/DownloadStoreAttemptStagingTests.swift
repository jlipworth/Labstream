import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("DownloadStore attempt staging")
struct DownloadStoreAttemptStagingTests {
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
            #expect(FileManager.default.fileExists(atPath: stageA.path))

            let stageB = try #require(store.attemptStagingURL(for: b, stableURL: stable))
            try Data("attempt-b".utf8).write(to: stageB)
            #expect(store.promoteAttemptStagingFile(for: b, stagingURL: stageB, to: stable)
                    == .promoted)
            #expect(String(decoding: try Data(contentsOf: stable), as: UTF8.self) == "attempt-b")
            #expect(!FileManager.default.fileExists(atPath: stageB.path))
            #expect(store.record(for: b) != nil)
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
            try Data("owned".utf8).write(to: ownedStage)
            try Data("orphan".utf8).write(to: orphanStage)
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
            #expect(FileManager.default.fileExists(atPath: unrelated.path))
            #expect(!FileManager.default.fileExists(atPath: orphanStage.path))
        }
    }

    private func key(_ ratingKey: String, _ attempt: String) -> DownloadAttemptKey {
        DownloadAttemptKey(ratingKey: ratingKey,
                           attemptID: DownloadAttemptID(rawValue: attempt)!)
    }

    private func created(_ store: DownloadStore, key: DownloadAttemptKey, stable: URL,
                         replacing: DownloadAttemptID? = nil) -> Bool {
        let record = DownloadRecord(ratingKey: key.ratingKey, attemptID: key.attemptID,
                                    title: "Item", localURL: stable, status: .queued)
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
}
