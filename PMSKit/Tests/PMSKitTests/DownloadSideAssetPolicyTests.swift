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

    @Test("Selected Plex BIF part uses the requested media and never substitutes the first media")
    func selectedPlexBIFPart() {
        let item = MediaItem(ratingKey: "item", title: "Title", type: "movie", media: [
            Media(id: 1, part: [part(id: 10, indexes: "sd")]),
            Media(id: 2, part: [part(id: 20, indexes: "thumbs")]),
            Media(id: 3, part: [part(id: 30, indexes: "sd,other")]),
        ])

        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 0, partIndex: 0)?.id == 10)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 1, partIndex: 0) == nil)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 2, partIndex: 0)?.id == 30)
        // A media index the item no longer has selects nothing, never media[0]'s file.
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 99, partIndex: 0) == nil)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: -1, partIndex: 0) == nil)
    }

    @Test("Legacy BIF repair without a part ID declines exactly where the subtitle repair declines")
    func legacyBIFRepairMatchesSubtitleRepair() {
        // The row downloaded media 1 part 0 and stored no part ID; Plex has since dropped a version.
        let shrunk = MediaItem(ratingKey: "item", title: "Title", type: "movie", media: [
            Media(id: 1, part: [part(id: 10, indexes: "sd")]),
        ])
        #expect(DownloadSideAssetPolicy.plexRepairPart(from: shrunk, mediaIndex: 1, partIndex: 0, sourcePartID: nil) == nil)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: shrunk, mediaIndex: 1, partIndex: 0, sourcePartID: nil) == nil)
        for mediaIndex in -1...2 {
            for partIndex in -1...1 {
                let repair = DownloadSideAssetPolicy.plexRepairPart(
                    from: shrunk, mediaIndex: mediaIndex, partIndex: partIndex, sourcePartID: nil)
                let bif = DownloadSideAssetPolicy.selectedPlexBIFPart(
                    from: shrunk, mediaIndex: mediaIndex, partIndex: partIndex, sourcePartID: nil)
                #expect(bif?.id == repair?.id)
            }
        }
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

    @Test("Plex repair requires the persisted part ID after a reorder")
    func plexRepairPartByID() {
        let item = MediaItem(ratingKey: "item", title: "Title", type: "movie", media: [
            Media(id: 2, part: [part(id: 20, indexes: "sd"), part(id: 21)]),
            Media(id: 1, part: [part(id: 10), part(id: 11, indexes: "sd")]),
        ])
        #expect(DownloadSideAssetPolicy.plexRepairPart(from: item, mediaIndex: 0, partIndex: 1, sourcePartID: 11)?.id == 11)
        #expect(DownloadSideAssetPolicy.plexRepairPart(from: item, mediaIndex: 0, partIndex: 1, sourcePartID: 99) == nil)
        // Even valid indexes cannot identify the downloaded version after a reorder.
        #expect(DownloadSideAssetPolicy.plexRepairPart(from: item, mediaIndex: 0, partIndex: 1, sourcePartID: nil) == nil)
        #expect(DownloadSideAssetPolicy.plexRepairPart(from: item, mediaIndex: 5, partIndex: 0, sourcePartID: nil) == nil)
        // The BIF follows the same identity, and still needs the part's own index.
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 0, partIndex: 1, sourcePartID: 11)?.id == 11)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 0, partIndex: 0, sourcePartID: 10) == nil)
        #expect(DownloadSideAssetPolicy.selectedPlexBIFPart(from: item, mediaIndex: 1, partIndex: 1, sourcePartID: 99) == nil)
    }

    @Test("A source refresh teaches a row the chapter thumbnails it was saved without (#504)")
    func learnedOfflineChapters() {
        let bare = [OfflineChapter(tag: "A", startTimeOffset: 0), OfflineChapter(tag: "B", startTimeOffset: 10_000)]
        let thumbed = [Chapter(tag: "A", startTimeOffset: 0, thumb: "/a"),
                       Chapter(tag: "B", startTimeOffset: 10_000, thumb: "/b")]
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: bare, current: thumbed)?.map(\.thumb) == ["/a", "/b"])
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: nil, current: thumbed)?.count == 2)
        // Nothing to learn.
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: bare, current: nil) == nil)
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: nil, current: nil) == nil)
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: [], current: []) == nil)
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(
            saved: bare, current: [Chapter(tag: "A", startTimeOffset: 0, thumb: " ")]) == nil)
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: thumbed.map(OfflineChapter.init), current: thumbed) == nil)
        // A partly thumbed list gains the missing thumbnails of the chapters that match.
        let partial = [OfflineChapter(tag: "A", startTimeOffset: 0, thumb: "/a"), OfflineChapter(tag: "B", startTimeOffset: 10_000)]
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: partial, current: thumbed)?.map(\.thumb) == ["/a", "/b"])
        let shifted = [Chapter(tag: "A", startTimeOffset: 0, thumb: "/a"), Chapter(tag: "B", startTimeOffset: 20_000, thumb: "/b")]
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: partial, current: shifted) == nil)
    }

    @Test("A refreshed thumbnail never replaces the saved chapter timeline")
    func learnedChaptersKeepTheSavedTimeline() throws {
        // Two named chapters saved without thumbnails; a rescan now reports one, retimed.
        let bare = [OfflineChapter(chapterID: 1, tag: "Opening", startTimeOffset: 0, endTimeOffset: 10_000),
                    OfflineChapter(chapterID: 2, tag: "Finale", startTimeOffset: 10_000, endTimeOffset: 20_000)]
        let rescan = [Chapter(tag: "Chapter 1", startTimeOffset: 5_000, thumb: "/x")]
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(saved: bare, current: rescan) == nil,
                "a chapter that matches no saved chapter teaches nothing")
        // A rescan that renames, retimes by a frame and adds a chapter: titles, times and the
        // saved count stay, and only the matching chapters gain a thumbnail.
        let drift = [Chapter(tag: "Chapter 1", startTimeOffset: 40, endTimeOffset: 9_000, thumb: "/1"),
                     Chapter(tag: "Chapter 1.5", startTimeOffset: 5_000, thumb: "/1.5"),
                     Chapter(tag: "Chapter 2", startTimeOffset: 10_000, thumb: "/2")]
        let learned = try #require(DownloadSideAssetPolicy.learnedOfflineChapters(saved: bare, current: drift))
        #expect(learned.map(\.tag) == ["Opening", "Finale"])
        #expect(learned.map(\.startTimeOffset) == [0, 10_000])
        #expect(learned.map(\.endTimeOffset) == [10_000, 20_000])
        #expect(learned.map(\.chapterID) == [1, 2])
        #expect(learned.map(\.thumb) == ["/1", "/2"])
        // Off its index, a saved chapter with two refreshed chapters within the tolerance is
        // ambiguous and learns nothing.
        let ambiguous = [Chapter(tag: "Intro", startTimeOffset: 0, thumb: "/i"),
                         Chapter(tag: "Extra", startTimeOffset: 3_000, thumb: "/e"),
                         Chapter(tag: "X", startTimeOffset: 9_500, thumb: "/x"),
                         Chapter(tag: "Y", startTimeOffset: 10_500, thumb: "/y")]
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(
            saved: [OfflineChapter(tag: "Intro", startTimeOffset: 0, thumb: "/i"),
                    OfflineChapter(tag: "Only", startTimeOffset: 10_000)], current: ambiguous) == nil)
        // Saved chapters without start offsets match by index only when both lack one.
        let untimed = [OfflineChapter(tag: "U")]
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(
            saved: untimed, current: [Chapter(tag: "V", thumb: "/v")])?.map(\.tag) == ["U"])
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(
            saved: untimed, current: [Chapter(tag: "V", startTimeOffset: 0, thumb: "/v")]) == nil)
    }

    @Test("An empty saved list adopts refreshed chapters even without thumbnails")
    func emptySavedListAdoptsChaptersWithoutThumbnails() throws {
        let titlesOnly = [Chapter(tag: "A", startTimeOffset: 0), Chapter(tag: "B", startTimeOffset: 60_000)]
        for saved in [nil, [OfflineChapter]()] {
            let learned = try #require(DownloadSideAssetPolicy.learnedOfflineChapters(saved: saved, current: titlesOnly))
            #expect(learned.map(\.tag) == ["A", "B"])
            #expect(learned.map(\.startTimeOffset) == [0, 60_000])
            #expect(learned.allSatisfy { $0.thumb == nil })
        }
        // A non-empty saved list is not touched by a thumbnail-free refresh.
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(
            saved: [OfflineChapter(tag: "Saved", startTimeOffset: 0)], current: titlesOnly) == nil)
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

    @Test(arguments: [0, Int.max])
    func distantChapterStartsAreDistinct(start: Int) {
        #expect(DownloadSideAssetPolicy.learnedOfflineChapters(
            saved: [OfflineChapter(startTimeOffset: .min)],
            current: [Chapter(startTimeOffset: start, thumb: "/fixture")]) == nil)
    }
}
