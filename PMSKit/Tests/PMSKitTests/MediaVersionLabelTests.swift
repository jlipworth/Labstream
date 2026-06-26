import Testing
@testable import PMSKit

@Suite("Media version labels")
struct MediaVersionLabelTests {
    @Test("Version label includes shared width-aware resolution, codec, and bitrate")
    func versionLabelUsesSharedResolutionBucketing() {
        let media = Media(id: 1,
                          bitrate: 9_000,
                          width: 1_280,
                          height: 536,
                          videoCodec: "h264",
                          audioCodec: "aac",
                          container: "mp4",
                          part: [])

        #expect(MediaVersionLabel.resolutionLabel(for: media) == "720p")
        #expect(MediaVersionLabel.versionLabel(for: media) == "720p · H264 · 9.0 Mbps")
    }

    @Test("Spec badges include audio and container while omitting empty values")
    func specBadgesIncludeDetailedTokens() {
        let media = Media(id: 2,
                          bitrate: 24_000,
                          width: 3_840,
                          height: 1_600,
                          videoCodec: "hevc",
                          audioCodec: "eac3",
                          container: "mkv",
                          part: [])

        #expect(MediaVersionLabel.specBadges(for: media) == ["4K", "HEVC", "EAC3", "24.0 Mbps", "MKV"])
    }

    @Test("Empty media falls back to generic version label")
    func emptyMediaFallsBackToGenericVersion() {
        let media = Media(id: 3, part: [])

        #expect(MediaVersionLabel.resolutionLabel(for: media) == nil)
        #expect(MediaVersionLabel.versionLabel(for: media) == "Version")
        #expect(MediaVersionLabel.specBadges(for: media).isEmpty)
    }
}
