import Foundation
import Testing
@testable import PMSKit

@Suite("Download media selection policy")
struct DownloadMediaSelectionPolicyTests {
    @Test("Selects media and part by safe indices")
    func selectsMediaAndPart() throws {
        let item = MediaItem(ratingKey: "item", title: "Item", type: "movie", media: [
            Media(id: 1, container: "mkv", part: [Part(id: 10, key: "/Items/item/media/source-a", container: "mkv")]),
            Media(id: 2, container: "mp4", part: [Part(id: 20, key: "/Items/item/media/source-b", container: "mp4")]),
        ])
        let selection = DownloadMediaSelectionPolicy.selection(item: item, mediaIndex: 1, partIndex: 0)
        #expect(selection.media?.id == 2)
        #expect(selection.part?.id == 20)
        #expect(selection.mediaSourceID == "source-b")
        #expect(DownloadMediaSelectionPolicy.containerExtension(selection: selection) == "mp4")
    }

    @Test("MediaSource id extraction prefers selected part then media fallback")
    func mediaSourceIDFallback() {
        let selectedWithoutSource = Part(id: 1, key: "/Videos/item/stream.mp4")
        let fallbackSource = Part(id: 2, key: "/Items/item/media/fallback-source")
        let media = Media(id: 1, part: [fallbackSource])
        #expect(DownloadMediaSelectionPolicy.mediaSourceID(media: media, part: selectedWithoutSource) == "fallback-source")
        #expect(DownloadMediaSelectionPolicy.mediaSourceID(media: nil, part: nil) == nil)
    }

    @Test("Out of range selection is nil tolerant")
    func outOfRange() {
        let item = MediaItem(ratingKey: "item", title: "Item", type: "movie", media: [
            Media(id: 1, container: "mp4", part: [])
        ])
        let selection = DownloadMediaSelectionPolicy.selection(item: item, mediaIndex: 3, partIndex: 0)
        #expect(selection.media == nil)
        #expect(selection.part == nil)
        #expect(selection.mediaSourceID == nil)
        #expect(DownloadMediaSelectionPolicy.containerExtension(selection: selection) == "mp4")
    }
}
