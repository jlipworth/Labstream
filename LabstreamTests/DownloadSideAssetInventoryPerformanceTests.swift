#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Foreground side-asset inventory I/O", .serialized)
@MainActor
struct DownloadSideAssetInventoryPerformanceTests {
    @Test func foregroundInventoriesCompletedRowsOffMainAndSharesChapterEvidence() async throws {
        let filesystem = DownloadPerformanceFileManager()
        let f = try await P7PlaybackFixture(status: .complete, fileManager: filesystem)
        for index in 0..<12 {
            let key = "plex:fixture-\(index)"
            var row = f.files.record(status: .complete, ratingKey: key, filename: "fixture-\(index).mp4")
            let chapter = f.store.chapterImageDestinationURL(ratingKey: key, index: 0)
            try Data([1]).write(to: chapter)
            row.metadata?.chapters = [OfflineChapter(thumb: "/fixture"), OfflineChapter(thumb: "/missing")]
            row.metadata?.chapterImageRelativePaths = [0: chapter.lastPathComponent]
            _ = await f.store.createAttemptOwnedRecordAsync(row, attemptID: row.attemptID!)
        }
        f.manager.refreshRecords() // Warm published metadata hydration before the foreground edge.
        f.manager.setQueuePausedForTesting(false)
        let mainBefore = filesystem.mainStats.value
        f.manager.noteAppSceneRecovery(.aggregateSceneBecameActive)
        await f.manager.completedSideAssetInventoryWorker?.value
        #expect(filesystem.mainStats.value == mainBefore)
        #expect(f.manager.completedSideAssetInventories.count == 13)
        let beforeSetup = filesystem.stats.value
        for inventory in f.manager.completedSideAssetInventories.values where !inventory.reusable.isEmpty {
            let destination = f.store.chapterImageDestinationURL(ratingKey: inventory.key.ratingKey, index: 0)
            let reused = await f.manager.reusableSideAssetObservations(for: inventory.key, destinations: [destination])
            #expect(reused.contains(destination.lastPathComponent))
            #expect(inventory.missing.contains(.chapterImages))
            #expect(inventory.resources[.chapterImages]?.count == 1)
        }
        #expect(filesystem.stats.value == beforeSetup)
        await f.finish()
    }

    @Test(arguments: [false, true])
    func replacementOrSourceChangeDuringInventoryCannotRepairOldRow(changeSource: Bool) async throws {
        let filesystem = DownloadPerformanceFileManager()
        let f = try await P7PlaybackFixture(status: .complete, fileManager: filesystem)
        defer { filesystem.attributeHold.release.signal() }
        let chapter = f.store.chapterImageDestinationURL(ratingKey: f.key.ratingKey, index: 0)
        try Data([1]).write(to: chapter)
        _ = await f.store.updateMetadataAsync(for: f.key) {
            $0.chapters = [OfflineChapter(thumb: "/fixture")]
            $0.chapterImageRelativePaths = [0: chapter.lastPathComponent]
        }
        f.manager.refreshRecords()
        f.manager.setQueuePausedForTesting(false)
        filesystem.attributeHold.arm()
        f.manager.rehydrateMissingOptionalSideAssetsForCompletedRows(reason: "fixture")
        _ = await filesystem.attributeHold.acknowledgement.wait()
        let worker = f.manager.completedSideAssetInventoryWorker
        if changeSource {
            _ = await f.store.updateMetadataAsync(for: f.key) { $0.mediaSourceID = "replacement-source" }
        } else {
            let replacement = f.files.record("b", status: .complete, filename: "replacement.mp4")
            _ = await f.store.createAttemptOwnedRecordAsync(replacement, attemptID: replacement.attemptID!, replacing: f.key.attemptID)
        }
        filesystem.attributeHold.release.signal()
        await worker?.value
        #expect(f.manager.completedSideAssetInventories[f.key] == nil)
        #expect(f.requests.value == 0)
        await f.finish()
    }
}
#endif
