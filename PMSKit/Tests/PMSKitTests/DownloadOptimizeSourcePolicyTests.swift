import Foundation
import Testing
@testable import PMSKit

@Suite("Download optimize source policy")
struct DownloadOptimizeSourcePolicyTests {
    @Test("Resume baseline prefers persisted source part, then selected media part, then legacy baseline")
    func resumeBaselinePrecedence() {
        let item = item(parts: [part(10, file: "/Movies/original.mkv"),
                                part(11, file: "/Movies/Plex Versions/old.mp4")])
        #expect(DownloadOptimizeSourcePolicy.resumeBaselinePartIDs(
            metadata: metadata(sourcePartID: 42, mediaIndex: 0, partIndex: 0, baseline: [10, 11]),
            item: item) == [42])
        #expect(DownloadOptimizeSourcePolicy.resumeBaselinePartIDs(
            metadata: metadata(mediaIndex: 0, partIndex: 0, baseline: [99]),
            item: item) == [10])
        #expect(DownloadOptimizeSourcePolicy.resumeBaselinePartIDs(
            metadata: metadata(baseline: [99, 100]),
            item: item) == [99, 100])
    }

    @Test("Resume baseline falls back to non-optimized current parts for very old rows")
    func resumeBaselineFallbackSkipsPlexVersions() {
        let item = item(parts: [part(10, file: "/Movies/original.mkv"),
                                part(11, file: "/Movies/Plex Versions/old.mp4"),
                                part(12, file: nil)])
        #expect(DownloadOptimizeSourcePolicy.resumeBaselinePartIDs(metadata: metadata(), item: item) == [10, 12])
    }

    @Test("Source part ids prefer the selected source and fall back across item snapshots")
    func sourcePartIDs() {
        let current = item(parts: [part(10, file: "/Movies/original.mkv")])
        let fallback = item(parts: [part(20, file: "/Movies/fallback.mkv"),
                                    part(21, file: "/Movies/fallback2.mkv")])
        #expect(DownloadOptimizeSourcePolicy.sourcePartIDs(item: current,
                                                           fallbackItem: fallback,
                                                           mediaIndex: 0,
                                                           partIndex: 0) == [10])
        #expect(DownloadOptimizeSourcePolicy.sourcePartIDs(item: itemNoMedia(),
                                                           fallbackItem: fallback,
                                                           mediaIndex: 0,
                                                           partIndex: 1) == [21])
        #expect(DownloadOptimizeSourcePolicy.sourcePartIDs(item: item(parts: []),
                                                           fallbackItem: fallback,
                                                           mediaIndex: 99,
                                                           partIndex: 0) == [])
    }

    private func metadata(sourcePartID: Int? = nil,
                          mediaIndex: Int? = nil,
                          partIndex: Int? = nil,
                          baseline: [Int]? = nil) -> OfflineMetadata {
        OfflineMetadata(ratingKey: "rk",
                        title: "Title",
                        type: "movie",
                        mediaIndex: mediaIndex,
                        partIndex: partIndex,
                        sourcePartID: sourcePartID,
                        optimizeBaselinePartIDs: baseline)
    }

    private func item(parts: [Part]) -> MediaItem {
        MediaItem(ratingKey: "rk", title: "Title", type: "movie", media: [Media(id: 1, part: parts)])
    }

    private func itemNoMedia() -> MediaItem {
        MediaItem(ratingKey: "rk", title: "Title", type: "movie")
    }

    private func part(_ id: Int, file: String?) -> Part {
        Part(id: id, key: "/library/parts/\(id)/file", file: file)
    }
}
