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
}
