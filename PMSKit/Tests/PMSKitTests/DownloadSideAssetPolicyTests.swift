import Foundation
import Testing
@testable import PMSKit

@Suite("Download side asset policy")
struct DownloadSideAssetPolicyTests {
    private func part(id: Int, indexes: String? = nil) -> Part {
        Part(id: id, key: "/library/parts/\(id)", indexes: indexes)
    }

    @Test("Episode poster prefers show then season then still then art")
    func episodePosterPreference() {
        #expect(DownloadSideAssetPolicy.offlinePosterRef(for: MediaItem(ratingKey: "e1", title: "Ep", type: "episode",
                                                                       thumb: "episode", art: "art",
                                                                       grandparentThumb: "show",
                                                                       parentThumb: "season")) == "show")
        #expect(DownloadSideAssetPolicy.offlinePosterRef(for: MediaItem(ratingKey: "e2", title: "Ep", type: "episode",
                                                                       thumb: "episode", art: "art",
                                                                       parentThumb: "season")) == "season")
        #expect(DownloadSideAssetPolicy.offlinePosterRef(for: MediaItem(ratingKey: "e3", title: "Ep", type: "episode",
                                                                       thumb: "episode", art: "art")) == "episode")
    }

    @Test("Movie poster prefers thumb then art")
    func moviePosterPreference() {
        #expect(DownloadSideAssetPolicy.offlinePosterRef(for: MediaItem(ratingKey: "m1", title: "Movie", type: "movie",
                                                                       thumb: "poster", art: "art")) == "poster")
        #expect(DownloadSideAssetPolicy.offlinePosterRef(for: MediaItem(ratingKey: "m2", title: "Movie", type: "movie",
                                                                       art: "art")) == "art")
    }

    @Test("Selected Plex BIF part uses requested media when available and falls back to first media")
    func selectedPlexBIFPart() {
        let item = MediaItem(ratingKey: "item", title: "Title", type: "movie", media: [
            Media(id: 1, part: [part(id: 10, indexes: "sd")]),
            Media(id: 2, part: [part(id: 20, indexes: "thumbs")]),
            Media(id: 3, part: [part(id: 30, indexes: "sd,other")]),
        ])

        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 0)?.id == 10)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 1) == nil)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 2)?.id == 30)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 99)?.id == 10)
    }

    @Test("Synthetic chapter image parser validates scheme shape and tag")
    func parsedSyntheticChapterImageKey() {
        #expect(DownloadSideAssetPolicy.parsedSyntheticChapterImageKey("jellyfin://item/abc/Chapter/3?tag=v1", scheme: "jellyfin")
            == ParsedChapterImageKey(itemID: "abc", index: 3, tag: "v1"))
        #expect(DownloadSideAssetPolicy.parsedSyntheticChapterImageKey("emby://item/abc/Chapter/0", scheme: "emby")
            == ParsedChapterImageKey(itemID: "abc", index: 0, tag: nil))
        #expect(DownloadSideAssetPolicy.parsedSyntheticChapterImageKey("emby://item/abc/Chapter/nope", scheme: "emby") == nil)
        #expect(DownloadSideAssetPolicy.parsedSyntheticChapterImageKey("jellyfin://item/abc/Chapter/1", scheme: "emby") == nil)
    }

    @Test("Chapter image throttling starts above batch size")
    func throttlingPredicate() {
        #expect(!DownloadSideAssetPolicy.shouldLogChapterImageThrottling(requestCount: DownloadSideAssetPolicy.chapterImageBatchSize))
        #expect(DownloadSideAssetPolicy.shouldLogChapterImageThrottling(requestCount: DownloadSideAssetPolicy.chapterImageBatchSize + 1))
    }
}
