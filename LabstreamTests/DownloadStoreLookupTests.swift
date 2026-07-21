import Foundation
import PMSKit
import Testing
@testable import Labstream

struct DownloadStoreLookupTests {
    @Test func embyBIFHydratesCountsAuditsAndDeletesWithItsRecord() throws {
        try withTemporaryDirectory { directory in
            let bifName = "item.emby.bif"
            let attemptID = try #require(DownloadAttemptID(rawValue: "attempt-a"))
            var metadata = OfflineMetadata(
                ratingKey: "emby:item", title: "Title", type: "movie",
                embyBIFRelativePath: bifName, downloadAttemptID: "attempt-a")
            metadata.claimCachedSideAssets(attemptID: attemptID.rawValue)
            try DownloadIndexCoding.encode([
                SeedRow(ratingKey: "emby:item", attemptID: attemptID,
                        title: "Title", relativePath: "item.mp4",
                        bytes: 3, progress: 1, status: .complete, metadata: metadata),
            ]).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("item.mp4"))
            try Data([4, 5, 6, 7]).write(to: directory.appendingPathComponent(bifName))
            let store = DownloadStore(baseDirectory: directory)

            let record = try #require(store.record(for: "emby:item"))
            #expect(record.embyBIFURL?.lastPathComponent == bifName)
            #expect(record.sideAssetBytes == 4)
            #expect(store.embyBIFURL(for: "emby:item")?.lastPathComponent == bifName)
            let audit = store.storageAudit()
            #expect(audit.referencedRelativePaths.contains(bifName))
            #expect(audit.referencedBytes == 7)

            let attemptKey = DownloadAttemptKey(
                ratingKey: "emby:item",
                attemptID: attemptID)
            #expect(store.remove(for: attemptKey) == .applied)
            #expect(store.resolveArtifactSynchronouslyForTests(
                through: store.currentArtifactLifecycleWatermark()) == .completed)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(bifName).path))
            #expect(store.record(for: "emby:item") == nil)
        }
    }

    @Test func sideAssetReuseRequiresExactAttemptMetadataAndNonemptyRegularFile() throws {
        try withTemporaryDirectory { directory in
            let relative = "chapter-0.jpg"
            let attemptID = try #require(DownloadAttemptID(rawValue: "attempt-a"))
            var metadata = OfflineMetadata(
                ratingKey: "emby:item", title: "Title", type: "movie",
                chapterImageRelativePaths: [0: relative], downloadAttemptID: "attempt-a")
            metadata.claimCachedSideAssets(attemptID: attemptID.rawValue)
            try DownloadIndexCoding.encode([
                SeedRow(ratingKey: "emby:item", attemptID: attemptID,
                        title: "Title", relativePath: "media.mp4",
                        bytes: 0, progress: 0, status: .queued, metadata: metadata),
            ]).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            let store = DownloadStore(baseDirectory: directory)
            let destination = directory.appendingPathComponent(relative)
            let owner = DownloadAttemptKey(
                ratingKey: "emby:item", attemptID: attemptID)
            let replacement = DownloadAttemptKey(
                ratingKey: "emby:item", attemptID: try #require(DownloadAttemptID(rawValue: "attempt-b")))

            try Data().write(to: destination)
            #expect(store.reusableSideAssetRelativePath(for: owner, destination: destination) == nil)
            try Data([1]).write(to: destination)
            #expect(store.reusableSideAssetRelativePath(for: owner, destination: destination) == relative)
            #expect(store.reusableSideAssetRelativePath(for: replacement, destination: destination) == nil)

            let orphan = directory.appendingPathComponent("orphan.jpg")
            try Data([1]).write(to: orphan)
            #expect(store.reusableSideAssetRelativePath(for: owner, destination: orphan) == nil)
        }
    }

    @Test func oneRecordLookupMatchesFullSnapshotAndTouchesOnlyItsSideAssets() throws {
        try withSeededStore(rowCount: 1_000) { store, fileManager, directory in
            let targetKey = ratingKey(777)

            fileManager.resetObservedAttributePaths()
            let narrow = try #require(store.record(for: targetKey))
            let observed = fileManager.observedAttributePaths

            #expect(observed == [directory.appendingPathComponent("poster-777.jpg").path])
            #expect(narrow == store.records.first { $0.ratingKey == targetKey })

            fileManager.resetObservedAttributePaths()
            #expect(store.contains(ratingKey: targetKey))
            #expect(!store.contains(ratingKey: "missing"))
            #expect(store.metadata(for: targetKey) == narrow.metadata)
            #expect(store.duration(for: targetKey) == 777_000)
            #expect(store.downloadAttemptID(ratingKey: targetKey) == "attempt-777")
            #expect(fileManager.observedAttributePaths.isEmpty)
        }
    }

    @Test func startupRetirementPreservesCrossKindMainMediaAlias() throws {
        try withTemporaryDirectory { directory in
            let staleAttempt = try #require(DownloadAttemptID(rawValue: "attempt-stale"))
            let mediaAttempt = try #require(DownloadAttemptID(rawValue: "attempt-media"))
            let shared = "shared-body.mp4"
            let staleMetadata = OfflineMetadata(
                ratingKey: "plex:stale", title: "Stale", type: "movie",
                posterRelativePath: shared, downloadAttemptID: staleAttempt.rawValue)
            let mediaMetadata = OfflineMetadata(
                ratingKey: "plex:media", title: "Media", type: "movie",
                downloadAttemptID: mediaAttempt.rawValue)
            try DownloadIndexCoding.encode([
                SeedRow(ratingKey: "plex:stale", attemptID: staleAttempt, title: "Stale",
                        relativePath: "stale.mp4", bytes: 0, progress: 0,
                        status: .queued, metadata: staleMetadata),
                SeedRow(ratingKey: "plex:media", attemptID: mediaAttempt, title: "Media",
                        relativePath: shared, bytes: 3, progress: 1,
                        status: .complete, metadata: mediaMetadata),
            ]).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            let sharedURL = directory.appendingPathComponent(shared)
            try Data([1, 2, 3]).write(to: sharedURL)

            let store = DownloadStore(baseDirectory: directory)

            #expect(store.metadata(for: "plex:stale")?.posterRelativePath == nil)
            #expect(FileManager.default.fileExists(atPath: sharedURL.path))
            #expect(store.localURL(for: "plex:media") == sharedURL)
        }
    }

    @Test func validPosterOwnerDoesNotAdoptDeterministicOrphanSubtitle() throws {
        try withTemporaryDirectory { directory in
            let ratingKey = "plex:valid-owner"
            let attempt = try #require(DownloadAttemptID(rawValue: "attempt-current"))
            var metadata = OfflineMetadata(
                ratingKey: ratingKey, title: "Current", type: "movie",
                posterRelativePath: "current.poster.jpg", backendKind: .plex,
                downloadAttemptID: attempt.rawValue)
            metadata.claimCachedSideAssets(attemptID: attempt.rawValue)
            try DownloadIndexCoding.encode([
                SeedRow(ratingKey: ratingKey, attemptID: attempt, title: "Current",
                        relativePath: "current.mp4", bytes: 3, progress: 1,
                        status: .complete, metadata: metadata),
            ]).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
            try Data([1]).write(to: directory.appendingPathComponent("current.poster.jpg"))
            let orphanSubtitle = directory.appendingPathComponent("plex_valid-owner.sub-7.srt")
            try Data("orphan predecessor".utf8).write(to: orphanSubtitle)

            let store = DownloadStore(baseDirectory: directory)

            #expect(store.metadata(for: ratingKey)?.posterRelativePath == "current.poster.jpg")
            #expect(store.metadata(for: ratingKey)?.offlineTextSubtitles == nil)
            #expect(store.storageAudit().orphanCandidates.contains {
                $0.relativePath == orphanSubtitle.lastPathComponent
            })
        }
    }

    @Test func narrowLookupPreservesLegacyHydrationAndMissingRowSemantics() throws {
        try withTemporaryDirectory { directory in
            let rows = [
                SeedRow(ratingKey: "legacy", title: "Legacy", relativePath: "legacy.mp4",
                        bytes: 20, progress: 1, status: nil, metadata: nil),
                SeedRow(ratingKey: "rich",
                        attemptID: DownloadAttemptID(rawValue: "attempt-2"),
                        title: "Rich", relativePath: "rich.mkv",
                        bytes: 40, progress: 0.5, status: .paused,
                        metadata: makeMetadata(index: 2)),
            ]
            try DownloadIndexCoding.encode(rows).write(
                to: directory.appendingPathComponent("index.json"), options: .atomic
            )
            let store = DownloadStore(baseDirectory: directory)

            #expect(store.record(for: "legacy") == store.records.first { $0.ratingKey == "legacy" })
            #expect(store.record(for: "legacy")?.status == .complete)
            #expect(store.record(for: "rich") == store.records.first { $0.ratingKey == "rich" })
            #expect(store.record(for: "missing") == nil)
            #expect(store.metadata(for: "missing") == nil)
            #expect(store.duration(for: "missing") == nil)
            #expect(!store.contains(ratingKey: "missing"))
        }
    }

    @Test(arguments: [10, 100, 1_000])
    func benchmarkNarrowLookupAgainstFullSnapshot(rowCount: Int) throws {
        try withSeededStore(rowCount: rowCount) { store, _, _ in
            let targetKey = ratingKey(rowCount / 2)
            _ = store.records
            _ = store.record(for: targetKey)

            let narrow = medianNanoseconds(iterations: 31) {
                _ = store.record(for: targetKey)
            }
            let full = medianNanoseconds(iterations: 31) {
                _ = store.records.first { $0.ratingKey == targetKey }
            }

            let result = "PERF02_BENCH rows=\(rowCount) narrow_ns=\(narrow) full_ns=\(full)\n"
            print(result, terminator: "")
            #expect(store.record(for: targetKey) == store.records.first { $0.ratingKey == targetKey })
        }
    }

    private func withSeededStore(
        rowCount: Int,
        _ body: (DownloadStore, CountingFileManager, URL) throws -> Void
    ) throws {
        try withTemporaryDirectory { directory in
            let rows = (0..<rowCount).map { index in
                SeedRow(ratingKey: ratingKey(index),
                        attemptID: DownloadAttemptID(rawValue: "attempt-\(index)"),
                        title: "Item \(index)",
                        relativePath: "media-\(index).mp4",
                        bytes: index * 10,
                        progress: 0.5,
                        status: .paused,
                        metadata: makeMetadata(index: index))
            }
            try DownloadIndexCoding.encode(rows).write(
                to: directory.appendingPathComponent("index.json"), options: .atomic
            )
            let fileManager = CountingFileManager()
            let store = DownloadStore(baseDirectory: directory, fileManager: fileManager)
            try body(store, fileManager, directory)
        }
    }

    private func makeMetadata(index: Int) -> OfflineMetadata {
        var metadata = OfflineMetadata(ratingKey: ratingKey(index),
                                       title: "Item \(index)",
                                       type: "movie",
                                       duration: index * 1_000,
                                       posterRelativePath: "poster-\(index).jpg",
                                       downloadAttemptID: "attempt-\(index)")
        metadata.claimCachedSideAssets(attemptID: "attempt-\(index)")
        return metadata
    }

    private func ratingKey(_ index: Int) -> String {
        "plex:item-\(index)"
    }

    private func medianNanoseconds(iterations: Int, _ body: () -> Void) -> UInt64 {
        var samples: [UInt64] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(DispatchTime.now().uptimeNanoseconds - start)
        }
        return samples.sorted()[samples.count / 2]
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-store-lookups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private struct SeedRow: Codable {
    let ratingKey: String
    let attemptID: DownloadAttemptID?
    let title: String
    let relativePath: String
    let bytes: Int
    let progress: Double
    let status: DownloadStatus?
    let metadata: OfflineMetadata?

    init(ratingKey: String, attemptID: DownloadAttemptID? = nil, title: String,
         relativePath: String, bytes: Int, progress: Double, status: DownloadStatus?,
         metadata: OfflineMetadata?) {
        self.ratingKey = ratingKey
        self.attemptID = attemptID
        self.title = title
        self.relativePath = relativePath
        self.bytes = bytes
        self.progress = progress
        self.status = status
        self.metadata = metadata
    }
}

private final class CountingFileManager: FileManager, @unchecked Sendable {
    private let observationLock = NSLock()
    private var attributePaths: [String] = []

    var observedAttributePaths: [String] {
        observationLock.withLock { attributePaths }
    }

    func resetObservedAttributePaths() {
        observationLock.withLock { attributePaths.removeAll() }
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        observationLock.withLock { attributePaths.append(path) }
        return try super.attributesOfItem(atPath: path)
    }
}
