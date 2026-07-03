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

    @Test("Spec badges insert the HDR short label after the video codec (#195)")
    func specBadgesIncludeHDRBadge() {
        let dvStream = Stream(id: 10, streamType: 1, codec: "hevc",
                              bitDepth: 10, colorPrimaries: "bt2020", colorTrc: "smpte2084",
                              doviPresent: true, doviProfile: 8, doviBLCompatID: 1)
        let media = Media(id: 4,
                          bitrate: 62_800,
                          width: 3_840,
                          height: 1_600,
                          videoCodec: "hevc",
                          audioCodec: "truehd",
                          container: "mkv",
                          part: [Part(id: 1, key: "/library/parts/1", streams: [dvStream])])

        #expect(MediaVersionLabel.specBadges(for: media)
                == ["4K", "HEVC", "DV P8", "TRUEHD", "62.8 Mbps", "MKV"])
    }

    @Test("Spec badges omit the HDR badge for SDR and factless streams (#195)")
    func specBadgesOmitSDRBadge() {
        let sdrStream = Stream(id: 11, streamType: 1, codec: "h264", bitDepth: 8, colorTrc: "bt709")
        let media = Media(id: 5,
                          bitrate: 9_000,
                          width: 1_920,
                          height: 1_080,
                          videoCodec: "h264",
                          audioCodec: "aac",
                          container: "mp4",
                          part: [Part(id: 1, key: "/library/parts/1", streams: [sdrStream])])

        #expect(MediaVersionLabel.specBadges(for: media)
                == ["1080p", "H264", "AAC", "9.0 Mbps", "MP4"])
    }

    @Test("Empty media falls back to generic version label")
    func emptyMediaFallsBackToGenericVersion() {
        let media = Media(id: 3, part: [])

        #expect(MediaVersionLabel.resolutionLabel(for: media) == nil)
        #expect(MediaVersionLabel.versionLabel(for: media) == "Version")
        #expect(MediaVersionLabel.specBadges(for: media).isEmpty)
    }
}
