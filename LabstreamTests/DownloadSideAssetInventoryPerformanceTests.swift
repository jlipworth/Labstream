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
            try Data([1]).write(to: row.localURL)
            row.metadata?.chapters = [OfflineChapter(thumb: "/fixture"), OfflineChapter(thumb: "/missing")]
            row.metadata?.chapterImageRelativePaths = [0: chapter.lastPathComponent]
            _ = await f.store.createAttemptOwnedRecordAsync(row, attemptID: row.attemptID!)
        }
        f.manager.refreshRecords() // Warm published metadata hydration before the foreground edge.
        f.manager.setQueuePausedForTesting(false)
        let recovered = P6Acknowledgement<Bool>()
        f.manager.foregroundRecoveryDidResolveForTesting = { recovered.signal($0) }
        let mainBefore = filesystem.mainStats.value
        f.manager.noteAppSceneRecovery(.aggregateSceneBecameActive)
        try #require(await p6AwaitTask(f.manager.completedSideAssetInventoryWorker))
        try #require(await recovered.wait(seconds: 10) == true)
        try #require(await p6AwaitTask(f.manager.scheduledRefreshTaskForTesting))
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
        try #require(await p6AwaitTask(Task { await f.finish() }))
    }

    @Test func firstMissingTileDoesNotHideExistingTilesFromRepair() async throws {
        let filesystem = DownloadPerformanceFileManager()
        let f = try await P7PlaybackFixture(status: .complete, fileManager: filesystem)
        f.manager.setQueuePausedForTesting(false)
        let tiles = (0..<3).map { f.store.jellyfinTrickPlayTileDestinationURL(ratingKey: f.key.ratingKey, index: $0) }
        let playlistURL = f.store.jellyfinTrickPlayPlaylistDestinationURL(ratingKey: f.key.ratingKey)
        func playlist(_ names: [String]) -> String {
            "#EXTM3U\n" + names.map {
                "#EXTINF:10,\n#EXT-X-TILES:RESOLUTION=1x1,LAYOUT=1x1,DURATION=10\n\($0)\n"
            }.joined()
        }
        let local = playlist(tiles.map(\.lastPathComponent))
        let remote = playlist((0..<3).map { "tile-\($0).jpg" })
        #expect(try JellyfinTrickPlayPlaylistParser.parse(remote).tiles.count == 3)
        try Data(local.utf8).write(to: playlistURL)
        for tile in tiles.dropFirst() { try Data([1]).write(to: tile) }
        _ = await f.store.updateMetadataAsync(for: f.key) {
            $0.backendKind = .jellyfin
            $0.mediaSourceID = "fixture-source"
            $0.jellyfinTrickPlayPlaylistRelativePath = playlistURL.lastPathComponent
            $0.jellyfinTrickPlayTileRelativePaths = tiles.map(\.lastPathComponent)
        }
        let record = try #require(f.store.record(for: f.key))
        let mainBefore = filesystem.mainStats.value
        let inventory = try #require(await p6TaskResult(Task.detached {
            CompletedSideAssetInventory.observe(record: record, store: f.store)
        }) ?? nil)
        f.manager.completedSideAssetInventories[f.key] = inventory
        for tile in tiles.dropFirst() {
            let reusable = await f.manager.reusableSideAssetObservations(for: f.key, destinations: [tile])
            #expect(reusable.contains(tile.lastPathComponent))
        }
        #expect(filesystem.mainStats.value == mainBefore, "Inventory and reuse must not stat on MainActor")
        let requested = TestLockedBox<[String]>([])
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let stub = TestURLProtocolStub { request in
            let url = request.url!
            requested.withValue { $0.append(url.lastPathComponent) }
            let data: Data
            if url.pathExtension == "m3u8" { data = Data(remote.utf8) }
            else if url.lastPathComponent == "tile-0.jpg" { data = png }
            else { throw URLError(.notConnectedToInternet) }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let transport = URLSession(configuration: stub.configuration)
        defer { transport.invalidateAndCancel() }
        f.manager.optionalSideAssetSessionForTesting = transport
        f.manager.cacheJellyfinTrickPlay(for: f.key, itemId: "fixture", mediaSourceId: "fixture-source",
            server: URL(string: "https://media.invalid")!, token: "fixture",
            identity: f.manager.appModel.identity.jellyfin)
        // Join the real work registry's completion without a polling/scheduling deadline.
        try #require(await p6AwaitTask(Task { await f.manager.downloadWorkRegistry.waitForSideCacheForTesting(for: f.key) }))
        let tileRequests = requested.value.filter { $0.hasSuffix(".jpg") }
        #expect(tileRequests == ["tile-0.jpg"])
        let published = try JellyfinTrickPlayPlaylistParser.parse(String(contentsOf: playlistURL, encoding: .utf8))
        #expect(published.tiles.map(\.uri) == tiles.map(\.lastPathComponent))
        try #require(await p6AwaitTask(Task { await f.finish() }))
    }

    @Test(arguments: [DownloadBackendKind.plex, .jellyfin, .emby])
    func missingFirstAssetStillInventoriesLaterChaptersSubtitlesAndBIF(backend: DownloadBackendKind) async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let chapter = f.store.chapterImageDestinationURL(ratingKey: f.key.ratingKey, index: 1)
        let subtitle = f.files.directory.appendingPathComponent("existing.vtt")
        let bif = backend == .emby ? f.store.embyBIFDestinationURL(ratingKey: f.key.ratingKey)
            : f.store.plexBIFDestinationURL(ratingKey: f.key.ratingKey)
        for url in [chapter, subtitle, bif] { try Data([1]).write(to: url) }
        _ = await f.store.updateMetadataAsync(for: f.key) {
            $0.backendKind = backend
            $0.mediaSourceID = "fixture-source"
            $0.chapters = [OfflineChapter(thumb: "/missing"), OfflineChapter(thumb: "/existing")]
            $0.chapterImageRelativePaths = [0: "missing.jpg", 1: chapter.lastPathComponent]
            $0.offlineTextSubtitles = [
                .init(id: 0, displayName: "Fixture", relativePath: "missing.vtt"),
                .init(id: 1, displayName: "Fixture", relativePath: subtitle.lastPathComponent)]
            if backend == .emby { $0.embyBIFRelativePath = bif.lastPathComponent }
            else { $0.plexBIFRelativePath = bif.lastPathComponent }
        }
        let record = try #require(f.store.record(for: f.key))
        let inventory = try #require(await p6TaskResult(Task.detached {
            CompletedSideAssetInventory.observe(record: record, store: f.store)
        }) ?? nil)
        #expect(inventory.reusable.isSuperset(of: [chapter.lastPathComponent, subtitle.lastPathComponent, bif.lastPathComponent]))
        #expect(inventory.missing.contains(.chapterImages))
        #expect(inventory.missing.contains(.textSubtitles))
        try #require(await p6AwaitTask(Task { await f.finish() }))
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
        try #require(await filesystem.attributeHold.acknowledgement.wait(seconds: 5) == true)
        let worker = f.manager.completedSideAssetInventoryWorker
        if changeSource {
            _ = await f.store.updateMetadataAsync(for: f.key) { $0.mediaSourceID = "replacement-source" }
        } else {
            let replacement = f.files.record("b", status: .complete, filename: "replacement.mp4")
            _ = await f.store.createAttemptOwnedRecordAsync(replacement, attemptID: replacement.attemptID!, replacing: f.key.attemptID)
        }
        filesystem.attributeHold.release.signal()
        try #require(await p6AwaitTask(worker))
        #expect(f.manager.completedSideAssetInventories[f.key] == nil)
        #expect(f.requests.value == 0)
        try #require(await p6AwaitTask(Task { await f.finish() }))
    }
}
#endif
