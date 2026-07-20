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

    // JF retry regression: a retry/rebuild reconstructs the item WITHOUT media/part arrays, so the
    // selection collapses to the "mp4" fallback — the in-progress row's on-disk extension must win
    // or a non-MP4 original's checkpoint reads 0 and the multi-GB partial is orphaned.
    @Test("Existing row extension is stable across retry with a lean rebuilt item")
    func containerExtensionStableAcrossRetry() {
        let leanItem = MediaItem(ratingKey: "item", title: "Item", type: "movie")
        let leanSelection = DownloadMediaSelectionPolicy.selection(item: leanItem, mediaIndex: 0, partIndex: 0)
        #expect(DownloadMediaSelectionPolicy.containerExtension(selection: leanSelection) == "mp4")
        #expect(DownloadMediaSelectionPolicy.containerExtension(
            selection: leanSelection, existingRelativePath: "jellyfin-item.mkv") == "mkv")
        // No existing row (fresh enqueue) or extension-less path → normal selection fallback.
        #expect(DownloadMediaSelectionPolicy.containerExtension(
            selection: leanSelection, existingRelativePath: nil) == "mp4")
        #expect(DownloadMediaSelectionPolicy.containerExtension(
            selection: leanSelection, existingRelativePath: "jellyfin-item") == "mp4")
    }

    @Test("Download audio selection prefers override, then selected/default/first")
    func audioSelectionFallbacks() {
        let streams = [
            Stream(id: 1, streamType: StreamType.audio.rawValue, codec: "aac",
                   language: "English", isDefault: true, channels: 2),
            Stream(id: 4, streamType: StreamType.audio.rawValue, codec: "dts",
                   displayTitle: "Japanese DTS-HD MA 5.1", selected: true, channels: 6),
        ]
        let part = Part(id: 1, key: "/Videos/item/stream.mkv", streams: streams)

        let selected = DownloadAudioSelectionPolicy.selectedAudioTrack(part: part)
        #expect(selected?.streamIndex == 4)
        #expect(selected?.displayName == "Japanese DTS-HD MA 5.1")

        let preferred = DownloadAudioSelectionPolicy.selectedAudioTrack(
            part: part, preferredLanguage: "en")
        #expect(preferred?.streamIndex == 1)

        let override = DownloadAudioSelectionPolicy.selectedAudioTrack(part: part, overrideStreamIndex: 1)
        #expect(override?.streamIndex == 1)
        #expect(override?.displayName == "English · AAC 2.0")
    }

    @Test("Download audio override survives sparse metadata")
    func audioOverrideWithoutStreams() {
        let selected = DownloadAudioSelectionPolicy.selectedAudioTrack(part: nil, overrideStreamIndex: 7)
        #expect(selected?.streamIndex == 7)
        #expect(selected?.displayName == "Track 7")
        #expect(DownloadAudioSelectionPolicy.selectedAudioStreamIndex(part: nil) == nil)
    }
}
