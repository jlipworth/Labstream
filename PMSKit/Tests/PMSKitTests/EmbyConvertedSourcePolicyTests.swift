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

    @Test("TV profile tiers may reuse lower non-ladder converted output")
    func reusableTVTierFallback() throws {
        let sources = try mediaSources(#"""
        { "Id": "4", "Protocol": "File", "Container": "mp4", "Width": 720, "Height": 404 },
        { "Id": "5", "Protocol": "File", "Container": "mp4", "Width": 3840, "Height": 2160 }
        """#)
        let source = EmbyConvertedSourcePolicy.reusableSource(sources,
                                                              requestedHeight: 1080,
                                                              primaryMediaSourceID: nil)
        #expect(source?.id == "4")
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

    private func mediaSources(_ entries: String) throws -> [EmbyMediaSourceInfo] {
        let json = "{\"PlaySessionId\":\"s\",\"MediaSources\":[\n" + entries + "\n]}"
        return try EmbyPlaybackInfoResponse.decode(from: Data(json.utf8)).mediaSources
    }
}
