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

        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 0, partIndex: 0)?.id == 10)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 1, partIndex: 0) == nil)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 2, partIndex: 0)?.id == 30)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 99, partIndex: 0)?.id == 10)
    }

    @Test("Selected Plex BIF part is the downloaded part, not the media's first part (#495)")
    func selectedPlexBIFPartUsesChosenPart() {
        let item = MediaItem(ratingKey: "item", title: "Title", type: "movie", media: [
            Media(id: 1, part: [part(id: 10, indexes: "sd"), part(id: 11, indexes: nil)]),
            Media(id: 2, part: [part(id: 20, indexes: nil), part(id: 21, indexes: "sd")]),
        ])

        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 0, partIndex: 1) == nil)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 1, partIndex: 1)?.id == 21)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 1, partIndex: 0) == nil)
        // A part index the media does not have selects nothing, like the transfer.
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 0, partIndex: 5) == nil)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 0, partIndex: -1) == nil)
    }

    @Test("Empty or blank artwork fields are absent and fall back to the next field (#504)")
    func blankArtworkFallsBack() {
        #expect(DownloadSideAssetPolicy.offlinePosterRef(for: MediaItem(ratingKey: "m1", title: "Movie", type: "movie",
                                                                       thumb: "", art: "art")) == "art")
        #expect(DownloadSideAssetPolicy.offlinePosterRef(for: MediaItem(ratingKey: "m2", title: "Movie", type: "movie",
                                                                       thumb: "  ", art: "art")) == "art")
        #expect(DownloadSideAssetPolicy.offlinePosterRef(for: MediaItem(ratingKey: "m3", title: "Movie", type: "movie",
                                                                       thumb: "", art: "")) == nil)
        #expect(DownloadSideAssetPolicy.offlinePosterRef(for: MediaItem(ratingKey: "e1", title: "Ep", type: "episode",
                                                                       thumb: "episode", art: "art",
                                                                       grandparentThumb: "",
                                                                       parentThumb: "season")) == "season")
        // Jellyfin/Emby synthetic refs go through the same selector.
        #expect(DownloadSideAssetPolicy.offlinePosterRef(for: MediaItem(ratingKey: "j1", title: "Movie", type: "movie",
                                                                       thumb: "",
                                                                       art: "jellyfin://item/x/Backdrop?tag=t"))
            == "jellyfin://item/x/Backdrop?tag=t")
    }

    @Test("Plex repair part is resolved by the persisted part ID, by index only without one (#503)")
    func plexRepairPartByID() {
        let item = MediaItem(ratingKey: "item", title: "Title", type: "movie", media: [
            Media(id: 2, part: [part(id: 20, indexes: "sd"), part(id: 21)]),
            Media(id: 1, part: [part(id: 10), part(id: 11, indexes: "sd")]),
        ])
        #expect(DownloadSideAssetPolicy.plexRepairPart(from: item, mediaIndex: 0, partIndex: 1, sourcePartID: 11)?.id == 11)
        #expect(DownloadSideAssetPolicy.plexRepairPart(from: item, mediaIndex: 0, partIndex: 1, sourcePartID: 99) == nil)
        // Legacy rows without an ID keep the index lookup, strictly in range.
        #expect(DownloadSideAssetPolicy.plexRepairPart(from: item, mediaIndex: 0, partIndex: 1, sourcePartID: nil)?.id == 21)
        #expect(DownloadSideAssetPolicy.plexRepairPart(from: item, mediaIndex: 5, partIndex: 0, sourcePartID: nil) == nil)
        // The BIF follows the same identity, and still needs the part's own index.
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 0, partIndex: 1, sourcePartID: 11)?.id == 11)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 0, partIndex: 0, sourcePartID: 10) == nil)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 1, partIndex: 1, sourcePartID: 99) == nil)
    }

    @Test("A source refresh teaches a row the chapter thumbnails it was saved without (#504)")
    func learnedOfflineChapters() {
        let bare = [OfflineChapter(tag: "A", startTimeOffset: 0), OfflineChapter(tag: "B", startTimeOffset: 10)]
        let thumbed = [Chapter(tag: "A", startTimeOffset: 0, thumb: "/a"), Chapter(tag: "B", startTimeOffset: 10, thumb: "/b")]
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: bare, current: thumbed)?.map(\.thumb) == ["/a", "/b"])
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: nil, current: thumbed)?.count == 2)
        // A saved list without thumbnails is replaced even when the chapters differ.
        let other = [Chapter(tag: "X", startTimeOffset: 5, thumb: "/x")]
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: bare, current: other)?.map(\.tag) == ["X"])
        // Nothing to learn.
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: bare, current: nil) == nil)
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(
            saved: bare, current: [Chapter(tag: "A", startTimeOffset: 0, thumb: " ")]) == nil)
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: thumbed.map(OfflineChapter.init), current: thumbed) == nil)
        // A partly thumbed list gains the missing thumbnails only when the chapters match.
        let partial = [OfflineChapter(tag: "A", startTimeOffset: 0, thumb: "/a"), OfflineChapter(tag: "B", startTimeOffset: 10)]
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: partial, current: thumbed)?.map(\.thumb) == ["/a", "/b"])
        let shifted = [Chapter(tag: "A", startTimeOffset: 0, thumb: "/a"), Chapter(tag: "B", startTimeOffset: 20, thumb: "/b")]
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: partial, current: shifted) == nil)
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
}
