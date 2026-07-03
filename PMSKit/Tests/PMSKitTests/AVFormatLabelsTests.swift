import Testing
import Foundation
@testable import PMSKit

// GH #195 — friendly AV format names for the Stats panel: marketing audio names
// (Dolby Digital Plus, DTS-HD MA, TrueHD/Atmos…) with channel layout, and video
// codec + HDR/DV info on one line.

@Suite("AVFormatLabels audio")
struct AVFormatLabelsAudioTests {

    @Test func dolbyFamilyNames() {
        #expect(AVFormatLabels.audioDisplayName(codec: "ac3", channels: 6) == "Dolby Digital (AC-3) 5.1")
        #expect(AVFormatLabels.audioDisplayName(codec: "eac3", channels: 6) == "Dolby Digital Plus (E-AC-3) 5.1")
        #expect(AVFormatLabels.audioDisplayName(codec: "truehd", channels: 8) == "Dolby TrueHD 7.1")
    }

    @Test func atmosDetectedFromProfile() {
        #expect(AVFormatLabels.audioDisplayName(codec: "truehd", channels: 8,
                                                profile: "Dolby TrueHD + Dolby Atmos")
                == "Dolby TrueHD Atmos 7.1")
        #expect(AVFormatLabels.audioDisplayName(codec: "eac3", channels: 6,
                                                profile: "Dolby Digital Plus + Dolby Atmos")
                == "Dolby Digital Plus (E-AC-3) Atmos 5.1")
    }

    @Test func dtsFamilyNames() {
        #expect(AVFormatLabels.audioDisplayName(codec: "dca", channels: 6) == "DTS 5.1")
        #expect(AVFormatLabels.audioDisplayName(codec: "dts", channels: 6) == "DTS 5.1")
        #expect(AVFormatLabels.audioDisplayName(codec: "dca", channels: 8, profile: "ma") == "DTS-HD MA 7.1")
        #expect(AVFormatLabels.audioDisplayName(codec: "dts", channels: 8, profile: "DTS-HD MA") == "DTS-HD MA 7.1")
        #expect(AVFormatLabels.audioDisplayName(codec: "dts", channels: 8, profile: "DTS:X") == "DTS:X 7.1")
        #expect(AVFormatLabels.audioDisplayName(codec: "dca", channels: 6, profile: "hra") == "DTS-HD HRA 5.1")
    }

    @Test func commonCodecs() {
        #expect(AVFormatLabels.audioDisplayName(codec: "aac", channels: 2) == "AAC 2.0")
        #expect(AVFormatLabels.audioDisplayName(codec: "flac", channels: 2) == "FLAC 2.0")
        #expect(AVFormatLabels.audioDisplayName(codec: "opus", channels: 6) == "Opus 5.1")
        #expect(AVFormatLabels.audioDisplayName(codec: "mp3", channels: 2) == "MP3 2.0")
        #expect(AVFormatLabels.audioDisplayName(codec: "pcm_s16le", channels: 1) == "PCM Mono")
    }

    @Test func unknownCodecFallsThroughUppercased() {
        #expect(AVFormatLabels.audioDisplayName(codec: "wma2", channels: 2) == "WMA2 2.0")
        #expect(AVFormatLabels.audioDisplayName(codec: "cook", channels: nil) == "COOK")
        #expect(AVFormatLabels.audioDisplayName(codec: nil, channels: 6) == nil)
    }

    @Test func channelLayouts() {
        #expect(AVFormatLabels.channelLayoutName(1) == "Mono")
        #expect(AVFormatLabels.channelLayoutName(2) == "2.0")
        #expect(AVFormatLabels.channelLayoutName(6) == "5.1")
        #expect(AVFormatLabels.channelLayoutName(8) == "7.1")
        #expect(AVFormatLabels.channelLayoutName(7) == "6.1")
        #expect(AVFormatLabels.channelLayoutName(nil) == nil)
    }
}

@Suite("AVFormatLabels video")
struct AVFormatLabelsVideoTests {

    private var dvHDR: VideoHDRMetadata? {
        VideoHDRMetadata.classify(
            colorTransfer: "smpte2084", colorPrimaries: "bt2020", colorSpace: nil, colorRange: nil,
            bitDepth: 10,
            dolbyVision: VideoDolbyVisionInfo(profile: 8, level: 6, blCompatibilityID: 1,
                                              rpuPresent: true, elPresent: false, blPresent: true),
            hdr10PlusPresent: nil, rangeDescribesHDR: nil)
    }

    @Test func videoNameCombinesCodecAndHDR() {
        #expect(AVFormatLabels.videoDisplayName(codec: "hevc", hdr: dvHDR)
                == "HEVC · Dolby Vision P8 (HDR10 fallback)")
        #expect(AVFormatLabels.videoDisplayName(codec: "h264", hdr: nil) == "H.264")
        #expect(AVFormatLabels.videoDisplayName(codec: "av1", hdr: nil) == "AV1")
        #expect(AVFormatLabels.videoDisplayName(codec: nil, hdr: nil) == nil)
    }

    @Test func hdrOnlyWhenCodecMissing() {
        #expect(AVFormatLabels.videoDisplayName(codec: nil, hdr: dvHDR)
                == "Dolby Vision P8 (HDR10 fallback)")
    }
}
