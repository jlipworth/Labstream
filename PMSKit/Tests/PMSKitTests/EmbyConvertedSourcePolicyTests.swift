import Foundation
import Testing
@testable import PMSKit

@Suite("Emby converted source policy")
struct EmbyConvertedSourcePolicyTests {
    @Test("File source filtering keeps on-disk ids and older protocol-less sources")
    func fileSourceFiltering() throws {
        let sources = try mediaSources(#"""
        { "Id": "", "Protocol": "File", "Container": "mp4" },
        { "Id": "1", "Protocol": "Http", "Container": "mp4" },
        { "Id": "2", "Protocol": "File", "Container": "mp4" },
        { "Id": "3", "Container": "mkv" }
        """#)
        #expect(EmbyConvertedSourcePolicy.fileSources(sources).map(\.id) == ["2", "3"])
    }

    @Test("Preset labels map to output height tiers")
    func presetHeightTiers() {
        #expect(EmbyConvertedSourcePolicy.presetOutputHeight(forLabel: "Original video quality") == 2160)
        #expect(EmbyConvertedSourcePolicy.presetOutputHeight(forLabel: "4K 40 Mbps") == 2160)
        #expect(EmbyConvertedSourcePolicy.presetOutputHeight(forLabel: "1080p 8 Mbps") == 1080)
        #expect(EmbyConvertedSourcePolicy.presetOutputHeight(forLabel: "720p 4 Mbps") == 720)
        #expect(EmbyConvertedSourcePolicy.presetOutputHeight(forLabel: "mystery") == nil)
    }

    @Test("Reusable converted source prefers exact tier and newest id while excluding primary")
    func reusableExactTier() throws {
        let sources = try mediaSources(#"""
        { "Id": "1", "Protocol": "File", "Container": "mp4", "Width": 1920, "Height": 1080 },
        { "Id": "9", "Protocol": "File", "Container": "mp4", "Width": 1920, "Height": 1080 },
        { "Id": "10", "Protocol": "File", "Container": "mp4", "Width": 1280, "Height": 720 }
        """#)
        let source = EmbyConvertedSourcePolicy.reusableSource(sources,
                                                              requestedHeight: 1080,
                                                              primaryMediaSourceID: "1")
        #expect(source?.id == "9")
    }

    // User-choice fidelity: reuse below the requested tier is legitimate ONLY when the source
    // itself is that small (Convert never upscales, so min(request, source) is the source's band).
    @Test("Below-tier reuse allowed only when the source itself is in that band")
    func reusableBelowTierRequiresMatchingSourceBand() throws {
        let sources = try mediaSources(#"""
        { "Id": "3", "Protocol": "File", "Container": "mkv", "Width": 720, "Height": 404 },
        { "Id": "4", "Protocol": "File", "Container": "mp4", "Width": 720, "Height": 404 },
        { "Id": "5", "Protocol": "File", "Container": "mp4", "Width": 3840, "Height": 2160 }
        """#)
        let source = EmbyConvertedSourcePolicy.reusableSource(sources,
                                                              requestedHeight: 1080,
                                                              primaryMediaSourceID: "3")
        #expect(source?.id == "4")
    }

    // The old "any tier ≤ request" fallback silently downgraded: a stale 404p sibling satisfied a
    // 1080p request on a 4K source. That is a wrong version, not a reuse — require re-convert.
    @Test("Stale low-res sibling does not satisfy a higher-tier request on a big source")
    func reusableRejectsDowngradeSibling() throws {
        let sources = try mediaSources(#"""
        { "Id": "1", "Protocol": "File", "Container": "mkv", "Width": 3840, "Height": 2160 },
        { "Id": "4", "Protocol": "File", "Container": "mp4", "Width": 720, "Height": 404 }
        """#)
        let source = EmbyConvertedSourcePolicy.reusableSource(sources,
                                                              requestedHeight: 1080,
                                                              primaryMediaSourceID: "1")
        #expect(source == nil)
    }

    @Test("Below-tier reuse needs a resolvable primary source to prove the band")
    func reusableBelowTierRequiresKnownPrimary() throws {
        let sources = try mediaSources(#"""
        { "Id": "4", "Protocol": "File", "Container": "mp4", "Width": 720, "Height": 404 },
        { "Id": "5", "Protocol": "File", "Container": "mp4", "Width": 3840, "Height": 2160 }
        """#)
        let source = EmbyConvertedSourcePolicy.reusableSource(sources,
                                                              requestedHeight: 1080,
                                                              primaryMediaSourceID: nil)
        #expect(source == nil)
    }

    @Test("Pinned audio stream restricts reuse to a source carrying that language")
    func reusableMatchesRequestedAudioLanguage() throws {
        let sources = try mediaSources(#"""
        { "Id": "1", "Protocol": "File", "Container": "mkv", "Width": 1920, "Height": 1080,
          "MediaStreams": [ { "Type": "Audio", "Index": 1, "Language": "eng" },
                            { "Type": "Audio", "Index": 2, "Language": "fre" } ] },
        { "Id": "8", "Protocol": "File", "Container": "mp4", "Width": 1920, "Height": 1080,
          "MediaStreams": [ { "Type": "Audio", "Index": 1, "Language": "eng" } ] },
        { "Id": "9", "Protocol": "File", "Container": "mp4", "Width": 1920, "Height": 1080,
          "MediaStreams": [ { "Type": "Audio", "Index": 1, "Language": "fre" } ] }
        """#)
        let french = EmbyConvertedSourcePolicy.reusableSource(sources,
                                                              requestedHeight: 1080,
                                                              primaryMediaSourceID: "1",
                                                              requestedAudioStreamIndex: 2)
        #expect(french?.id == "9")
        let english = EmbyConvertedSourcePolicy.reusableSource(sources,
                                                               requestedHeight: 1080,
                                                               primaryMediaSourceID: "1",
                                                               requestedAudioStreamIndex: 1)
        #expect(english?.id == "8")
        // No pinned stream → historical newest-exact-tier behavior.
        let any = EmbyConvertedSourcePolicy.reusableSource(sources,
                                                           requestedHeight: 1080,
                                                           primaryMediaSourceID: "1")
        #expect(any?.id == "9")
    }

    @Test("4K and Original require exact tier instead of silently reusing 1080p")
    func reusable4KRequiresExactTier() throws {
        let sources = try mediaSources(#"""
        { "Id": "4", "Protocol": "File", "Container": "mp4", "Width": 1920, "Height": 1080 }
        """#)
        let source = EmbyConvertedSourcePolicy.reusableSource(sources,
                                                              requestedHeight: 2160,
                                                              primaryMediaSourceID: nil)
        #expect(source == nil)
    }

    @Test("Completed convert source selection prefers new converted output then bounded fallbacks")
    func completedSourceSelection() throws {
        let sources = try mediaSources(#"""
        { "Id": "1", "Protocol": "File", "Container": "mkv", "Width": 3840, "Height": 2160 },
        { "Id": "7", "Protocol": "File", "Container": "mp4", "Width": 1920, "Height": 1080 },
        { "Id": "8", "Protocol": "File", "Container": "mp4", "Width": 1280, "Height": 720 }
        """#)
        #expect(EmbyConvertedSourcePolicy.newConvertedSource(sources,
                                                             excludingSnapshotIDs: ["1", "7"])?.id == "8")
        // B46: once every visible source was in the pre-conversion snapshot, nothing is new, so the
        // fallback must not adopt a pre-existing sibling.
        #expect(EmbyConvertedSourcePolicy.completedSourceFallback(sources,
                                                                  excludingSnapshotIDs: ["1", "7", "8"]) == nil)
    }

    // B46: the second fallback tier ignored the snapshot, so an older converted sibling, or an
    // h264/mp4 original (which "looks converted"), was adopted as this job's output.
    @Test("Completed-source fallback never adopts a snapshot sibling or the original")
    func completedSourceFallbackExcludesSnapshotAndOriginal() throws {
        let sources = try mediaSources(#"""
        { "Id": "1", "Protocol": "File", "Container": "mp4", "VideoCodec": "h264",
          "Width": 3840, "Height": 2160 },
        { "Id": "6", "Protocol": "File", "Container": "mp4", "Width": 1280, "Height": 720 }
        """#)
        // Snapshot holds the h264/mp4 4K original and an older 720p sibling: no new output yet.
        #expect(EmbyConvertedSourcePolicy.completedSourceFallback(
            sources, excludingSnapshotIDs: ["1", "6"], requestedHeight: 1080,
            primaryMediaSourceID: "1") == nil)
        // Even with an empty (legacy) snapshot, the original is never this job's output.
        #expect(EmbyConvertedSourcePolicy.completedSourceFallback(
            sources, excludingSnapshotIDs: [], requestedHeight: 2160,
            primaryMediaSourceID: "1")?.id != "1")
        #expect(EmbyConvertedSourcePolicy.newConvertedSource(
            sources, excludingSnapshotIDs: [], requestedHeight: 2160,
            primaryMediaSourceID: "1")?.id != "1")
        // A genuinely new source still wins.
        let withNew = try mediaSources(#"""
        { "Id": "1", "Protocol": "File", "Container": "mp4", "VideoCodec": "h264",
          "Width": 3840, "Height": 2160 },
        { "Id": "6", "Protocol": "File", "Container": "mp4", "Width": 1280, "Height": 720 },
        { "Id": "11", "Protocol": "File", "Container": "mkv", "Width": 1920, "Height": 1080 }
        """#)
        #expect(EmbyConvertedSourcePolicy.completedSourceFallback(
            withNew, excludingSnapshotIDs: ["1", "6"], requestedHeight: 1080,
            primaryMediaSourceID: "1")?.id == "11")
    }

    // B46: `embyFileSources` returns [] on error, so a transient failure persisted an EMPTY snapshot
    // and the strict pickup could select the original right after Completed. A failed or empty
    // fetch must fail the create closed (retryable) instead of becoming the snapshot.
    @Test("Pre-conversion snapshot fails closed on a failed or empty fetch and always holds the original")
    func preConversionSnapshotFailsClosed() throws {
        #expect(EmbyConvertedSourcePolicy.preConversionSnapshotIDs(
            fetched: nil, primaryMediaSourceID: "1") == nil)
        #expect(EmbyConvertedSourcePolicy.preConversionSnapshotIDs(
            fetched: [], primaryMediaSourceID: "1") == nil)
        let sources = try mediaSources(#"""
        { "Id": "1", "Protocol": "File", "Container": "mkv" },
        { "Id": "6", "Protocol": "File", "Container": "mp4" }
        """#)
        #expect(EmbyConvertedSourcePolicy.preConversionSnapshotIDs(
            fetched: sources, primaryMediaSourceID: "1") == ["1", "6"])
        // The original is excluded even when PlaybackInfo listed it under another id set.
        #expect(EmbyConvertedSourcePolicy.preConversionSnapshotIDs(
            fetched: Array(sources.suffix(1)), primaryMediaSourceID: "1") == ["1", "6"])
        #expect(EmbyConvertedSourcePolicy.preConversionSnapshotIDs(
            fetched: sources, primaryMediaSourceID: nil) == ["1", "6"])
    }

    // Post-completion pickup sanity: a fresh source with KNOWN dimensions far below what this job
    // could render (min of requested and source tier) is a foreign sibling, not our output; a
    // fresh source with unknown dimensions still passes (probe data may lag indexing).
    @Test("New-source pickup rejects known-dimension sources far below the requested tier")
    func newConvertedSourceTierSanity() throws {
        let sources = try mediaSources(#"""
        { "Id": "1", "Protocol": "File", "Container": "mkv", "Width": 3840, "Height": 2160 },
        { "Id": "9", "Protocol": "File", "Container": "mp4", "Width": 1920, "Height": 1080 },
        { "Id": "17", "Protocol": "File", "Container": "mp4", "Width": 852, "Height": 480 }
        """#)
        // 480p is two bands below the 1080p request → rejected even though its id is newest.
        #expect(EmbyConvertedSourcePolicy.newConvertedSource(sources,
                                                             excludingSnapshotIDs: ["1"],
                                                             requestedHeight: 1080,
                                                             primaryMediaSourceID: "1")?.id == "9")
        // The bounded fallback applies the same gate: with the 1080p source in the snapshot, the
        // only new source is the 480p foreigner, which is rejected; the snapshot sibling is never
        // adopted either (B46).
        #expect(EmbyConvertedSourcePolicy.completedSourceFallback(sources,
                                                                  excludingSnapshotIDs: ["1", "9"],
                                                                  requestedHeight: 1080,
                                                                  primaryMediaSourceID: "1") == nil)
        // Unknown dimensions pass the gate — the freshly indexed output may not be probed yet.
        let unprobed = try mediaSources(#"""
        { "Id": "1", "Protocol": "File", "Container": "mkv", "Width": 3840, "Height": 2160 },
        { "Id": "12", "Protocol": "File", "Container": "mp4" }
        """#)
        #expect(EmbyConvertedSourcePolicy.newConvertedSource(unprobed,
                                                             excludingSnapshotIDs: ["1"],
                                                             requestedHeight: 1080,
                                                             primaryMediaSourceID: "1")?.id == "12")
    }

    @Test("Non-numeric ids fall back to PlaybackInfo position for recency")
    func nonNumericIdRecency() throws {
        let sources = try mediaSources(#"""
        { "Id": "abc", "Protocol": "File", "Container": "mp4", "Width": 1920, "Height": 1080 },
        { "Id": "def", "Protocol": "File", "Container": "mp4", "Width": 1920, "Height": 1080 }
        """#)
        #expect(EmbyConvertedSourcePolicy.newConvertedSource(sources,
                                                             excludingSnapshotIDs: [])?.id == "def")
    }

    // B45: the poll/finish chain used `item.media?.first?.id` as the primary MediaSource id. The
    // canonical MediaBrowser mapping sets `Media.id` to index + 1, and a relaunch item rebuilt from
    // metadata has no media at all, so the tier cap never found the real source and a 720p output
    // of a 720p source was rejected for an "Original" (2160) request.
    @Test("Primary source id comes from the persisted id or part key, never the synthesized Media.id")
    func primarySourceIDIgnoresSynthesizedMediaID() throws {
        let dto = try JSONDecoder().decode(EmbyBaseItemDto.self, from: Data(#"""
        { "Id": "item-1", "Name": "Item", "Type": "Movie",
          "MediaSources": [{ "Id": "5001", "Container": "mkv", "Width": 1280, "Height": 720 }] }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        // The synthesized id is the bug's input; it does not name any server source.
        #expect(item.media?.first?.id == 1)

        #expect(EmbyConvertedSourcePolicy.primaryMediaSourceID(persisted: "5001", item: item) == "5001")
        #expect(EmbyConvertedSourcePolicy.primaryMediaSourceID(persisted: nil, item: item) == "5001")
        #expect(EmbyConvertedSourcePolicy.primaryMediaSourceID(persisted: "", item: item) == "5001")
        // Relaunch rebuilds the item from metadata with no media: only the persisted id survives.
        let relaunchItem = MediaItem(ratingKey: "item-1", title: "Item", type: "movie")
        #expect(EmbyConvertedSourcePolicy.primaryMediaSourceID(persisted: "5001",
                                                               item: relaunchItem) == "5001")
        #expect(EmbyConvertedSourcePolicy.primaryMediaSourceID(persisted: nil, item: relaunchItem) == nil)

        // With the real id the tier cap is min(request, source): a 720p output of a 720p source
        // is accepted for an Original (2160) request. With the synthesized id it was rejected.
        let sources = try mediaSources(#"""
        { "Id": "5001", "Protocol": "File", "Container": "mkv", "Width": 1280, "Height": 720 },
        { "Id": "5002", "Protocol": "File", "Container": "mp4", "Width": 1280, "Height": 720 }
        """#)
        let primary = EmbyConvertedSourcePolicy.primaryMediaSourceID(persisted: nil, item: item)
        #expect(EmbyConvertedSourcePolicy.newConvertedSource(
            sources, excludingSnapshotIDs: ["5001"], requestedHeight: 2160,
            primaryMediaSourceID: primary)?.id == "5002")
        #expect(EmbyConvertedSourcePolicy.newConvertedSource(
            sources, excludingSnapshotIDs: ["5001"], requestedHeight: 2160,
            primaryMediaSourceID: (item.media?.first?.id).map(String.init)) == nil)
    }

    private func mediaSources(_ entries: String) throws -> [EmbyMediaSourceInfo] {
        let json = "{\"PlaySessionId\":\"s\",\"MediaSources\":[\n" + entries + "\n]}"
        return try EmbyPlaybackInfoResponse.decode(from: Data(json.utf8)).mediaSources
    }
}
