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
        #expect(EmbyConvertedSourcePolicy.completedSourceFallback(sources,
                                                                  excludingSnapshotIDs: ["1", "7", "8"])?.id == "8")
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
        // The bounded fallback applies the same gate: with the 1080p output already in the
        // snapshot it prefers the most-recent SANE converted source over the fresh 480p foreigner.
        #expect(EmbyConvertedSourcePolicy.completedSourceFallback(sources,
                                                                  excludingSnapshotIDs: ["1", "9"],
                                                                  requestedHeight: 1080,
                                                                  primaryMediaSourceID: "1")?.id == "9")
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

    private func mediaSources(_ entries: String) throws -> [EmbyMediaSourceInfo] {
        let json = "{\"PlaySessionId\":\"s\",\"MediaSources\":[\n" + entries + "\n]}"
        return try EmbyPlaybackInfoResponse.decode(from: Data(json.utf8)).mediaSources
    }
}
