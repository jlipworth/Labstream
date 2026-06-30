import Foundation
import Testing
@testable import PMSKit

@Suite("Download storage estimate policy")
struct DownloadStorageEstimatePolicyTests {
    @Test("Media estimates preserve source-sized and bitrate-sized choices")
    func mediaEstimates() {
        #expect(DownloadStorageEstimatePolicy.estimatedMediaBytes(source: .sourceFile,
                                                                 sourcePartBytes: 123,
                                                                 durationMs: 10_000) == 123)
        #expect(DownloadStorageEstimatePolicy.estimatedMediaBytes(source: .sourceFile,
                                                                 sourcePartBytes: nil,
                                                                 durationMs: 10_000) == nil)
        #expect(DownloadStorageEstimatePolicy.estimatedMediaBytes(source: .transcode(videoBitrateBps: 8_000_000),
                                                                 sourcePartBytes: 123,
                                                                 durationMs: 10_000)
            == TranscodeSizeEstimator.bytes(durationMs: 10_000, videoBitrateBps: 8_000_000))
    }

    @Test("Side asset estimates include chapter images for all backends and trickplay for Plex/Jellyfin")
    func sideAssetEstimates() {
        let chapterOnly = 2 * 30_000
        #expect(DownloadStorageEstimatePolicy.estimatedSideAssetBytes(durationMs: nil,
                                                                     backend: .emby,
                                                                     chapterImageCount: 2) == chapterOnly)
        #expect(DownloadStorageEstimatePolicy.estimatedSideAssetBytes(durationMs: nil,
                                                                     backend: .plex,
                                                                     chapterImageCount: 2) == chapterOnly)
        #expect(DownloadStorageEstimatePolicy.estimatedSideAssetBytes(durationMs: nil,
                                                                     backend: .jellyfin,
                                                                     chapterImageCount: 2) == chapterOnly)
        #expect(DownloadStorageEstimatePolicy.estimatedSideAssetBytes(durationMs: 60_000,
                                                                     backend: .plex,
                                                                     chapterImageCount: 0) > 0)
    }

    @Test("Total estimate adds side assets and treats sidecar-only downloads as nonzero")
    func totalBytes() {
        #expect(DownloadStorageEstimatePolicy.totalBytes(mediaBytes: 100, sideAssetBytes: 0) == 100)
        #expect(DownloadStorageEstimatePolicy.totalBytes(mediaBytes: 100, sideAssetBytes: 25) == 125)
        #expect(DownloadStorageEstimatePolicy.totalBytes(mediaBytes: nil, sideAssetBytes: 25) == 25)
        #expect(DownloadStorageEstimatePolicy.totalBytes(mediaBytes: nil, sideAssetBytes: 0) == nil)
    }

    @Test("Item estimate composes selected media choice and backend side assets")
    func itemEstimateComposesMediaAndSideAssets() throws {
        let item = MediaItem(ratingKey: "m1",
                             title: "Movie",
                             type: "movie",
                             duration: 60_000,
                             media: [
                                Media(id: 1,
                                      part: [Part(id: 10, key: "/p/10", size: 1_000_000)])
                             ],
                             chapters: [
                                Chapter(tag: "A", startTimeOffset: 0, endTimeOffset: 10_000, thumb: "/chapter/1"),
                                Chapter(tag: "B", startTimeOffset: 10_000, endTimeOffset: 20_000, thumb: nil),
                                Chapter(tag: "C", startTimeOffset: 20_000, endTimeOffset: 30_000, thumb: "/chapter/3"),
                             ])

        let embyOriginal = try #require(DownloadStorageEstimatePolicy.estimatedTotalBytes(
            for: item,
            choice: .original,
            backend: .emby))
        #expect(embyOriginal == 1_060_000)

        let plexOriginal = try #require(DownloadStorageEstimatePolicy.estimatedTotalBytes(
            for: item,
            choice: .original,
            backend: .plex))
        #expect(plexOriginal > embyOriginal)

        let transcode = try #require(DownloadStorageEstimatePolicy.estimatedTotalBytes(
            for: item,
            choice: .optimize(targetName: "720p 4 Mbps"),
            backend: .emby))
        #expect(transcode == TranscodeSizeEstimator.bytes(durationMs: 60_000,
                                                         videoBitrateBps: 4_000_000)! + 60_000)
    }
}
