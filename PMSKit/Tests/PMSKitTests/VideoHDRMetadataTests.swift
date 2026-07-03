import Testing
import Foundation
@testable import PMSKit

// GH #195 — backend-neutral HDR classification. The precedence order matters:
// Dolby Vision beats HDR10+ beats PQ/HLG transfer beats generic "HDR" range
// strings, and SDR is only claimed on positive SDR evidence.

@Suite("VideoHDRMetadata classification")
struct VideoHDRMetadataClassificationTests {

    @Test func dolbyVisionWithHDR10FallbackWins() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: "smpte2084",
            colorPrimaries: "bt2020",
            colorSpace: "bt2020nc",
            colorRange: nil,
            bitDepth: 10,
            dolbyVision: VideoDolbyVisionInfo(profile: 8, level: 6, blCompatibilityID: 1,
                                              rpuPresent: true, elPresent: false, blPresent: true),
            hdr10PlusPresent: nil,
            rangeDescribesHDR: nil)
        #expect(hdr?.format == .dolbyVision)
        #expect(hdr?.dolbyVision?.profile == 8)
        #expect(hdr?.bitDepth == 10)
    }

    @Test func dolbyVisionProfile5NoFallback() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: nil,
            colorPrimaries: nil,
            colorSpace: nil,
            colorRange: nil,
            bitDepth: 10,
            dolbyVision: VideoDolbyVisionInfo(profile: 5, level: 6, blCompatibilityID: 0,
                                              rpuPresent: true, elPresent: false, blPresent: true),
            hdr10PlusPresent: nil,
            rangeDescribesHDR: nil)
        #expect(hdr?.format == .dolbyVision)
        #expect(hdr?.displayLabel.contains("no fallback") == true)
    }

    @Test func hdr10PlusFlagBeatsPlainPQ() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: "smpte2084",
            colorPrimaries: "bt2020",
            colorSpace: nil,
            colorRange: nil,
            bitDepth: 10,
            dolbyVision: nil,
            hdr10PlusPresent: true,
            rangeDescribesHDR: nil)
        #expect(hdr?.format == .hdr10Plus)
    }

    @Test func pqTransferClassifiesHDR10() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: "smpte2084",
            colorPrimaries: "bt2020",
            colorSpace: "bt2020nc",
            colorRange: "tv",
            bitDepth: 10,
            dolbyVision: nil,
            hdr10PlusPresent: nil,
            rangeDescribesHDR: nil)
        #expect(hdr?.format == .hdr10)
    }

    @Test func hlgTransferClassifiesHLG() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: "arib-std-b67",
            colorPrimaries: "bt2020",
            colorSpace: nil,
            colorRange: nil,
            bitDepth: 10,
            dolbyVision: nil,
            hdr10PlusPresent: nil,
            rangeDescribesHDR: nil)
        #expect(hdr?.format == .hlg)
    }

    @Test func genericHDRRangeWithoutTransferIsUnknownHDR() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: nil,
            colorPrimaries: nil,
            colorSpace: nil,
            colorRange: nil,
            bitDepth: nil,
            dolbyVision: nil,
            hdr10PlusPresent: nil,
            rangeDescribesHDR: true)
        #expect(hdr?.format == .unknownHDR)
    }

    @Test func bt709TransferClassifiesSDR() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: "bt709",
            colorPrimaries: "bt709",
            colorSpace: "bt709",
            colorRange: "tv",
            bitDepth: 8,
            dolbyVision: nil,
            hdr10PlusPresent: nil,
            rangeDescribesHDR: nil)
        #expect(hdr?.format == .sdr)
    }

    @Test func explicitSDRRangeClassifiesSDR() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: nil,
            colorPrimaries: nil,
            colorSpace: nil,
            colorRange: nil,
            bitDepth: 8,
            dolbyVision: nil,
            hdr10PlusPresent: nil,
            rangeDescribesHDR: false)
        #expect(hdr?.format == .sdr)
    }

    @Test func nothingKnownReturnsNil() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: nil,
            colorPrimaries: nil,
            colorSpace: nil,
            colorRange: nil,
            bitDepth: nil,
            dolbyVision: nil,
            hdr10PlusPresent: nil,
            rangeDescribesHDR: nil)
        #expect(hdr == nil)
    }

    @Test func tenBitAloneIsNotClaimedAsHDR() {
        // 10-bit SDR encodes exist; bit depth alone must not flip the label to HDR.
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: nil,
            colorPrimaries: nil,
            colorSpace: nil,
            colorRange: nil,
            bitDepth: 10,
            dolbyVision: nil,
            hdr10PlusPresent: nil,
            rangeDescribesHDR: nil)
        #expect(hdr == nil)
    }
}

@Suite("VideoHDRMetadata labels")
struct VideoHDRMetadataLabelTests {

    @Test func dolbyVisionLabelIncludesProfileAndFallback() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: "smpte2084",
            colorPrimaries: "bt2020",
            colorSpace: nil,
            colorRange: nil,
            bitDepth: 10,
            dolbyVision: VideoDolbyVisionInfo(profile: 8, level: 6, blCompatibilityID: 1,
                                              rpuPresent: true, elPresent: false, blPresent: true),
            hdr10PlusPresent: nil,
            rangeDescribesHDR: nil)
        #expect(hdr?.displayLabel == "Dolby Vision P8 (HDR10 fallback)")
        #expect(hdr?.shortLabel == "DV P8")
    }

    @Test func hdr10LabelIncludesTransferPrimariesAndDepth() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: "smpte2084",
            colorPrimaries: "bt2020",
            colorSpace: nil,
            colorRange: nil,
            bitDepth: 10,
            dolbyVision: nil,
            hdr10PlusPresent: nil,
            rangeDescribesHDR: nil)
        #expect(hdr?.displayLabel == "HDR10 · PQ · BT.2020 · 10-bit")
        #expect(hdr?.shortLabel == "HDR10")
    }

    @Test func hdr10PlusLabel() {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: "smpte2084",
            colorPrimaries: "bt2020",
            colorSpace: nil,
            colorRange: nil,
            bitDepth: 10,
            dolbyVision: nil,
            hdr10PlusPresent: true,
            rangeDescribesHDR: nil)
        #expect(hdr?.displayLabel == "HDR10+ · PQ · BT.2020 · 10-bit")
        #expect(hdr?.shortLabel == "HDR10+")
    }

    @Test func hlgAndSDRLabels() {
        let hlg = VideoHDRMetadata.classify(
            colorTransfer: "arib-std-b67", colorPrimaries: nil, colorSpace: nil, colorRange: nil,
            bitDepth: nil, dolbyVision: nil, hdr10PlusPresent: nil, rangeDescribesHDR: nil)
        #expect(hlg?.displayLabel == "HLG")
        let sdr = VideoHDRMetadata.classify(
            colorTransfer: "bt709", colorPrimaries: nil, colorSpace: nil, colorRange: nil,
            bitDepth: 8, dolbyVision: nil, hdr10PlusPresent: nil, rangeDescribesHDR: nil)
        #expect(sdr?.displayLabel == "SDR · 8-bit")
        #expect(sdr?.shortLabel == "SDR")
    }

    @Test func dolbyVisionFallbackNamesFromCompatibilityID() {
        func label(_ compat: Int?, profile: Int? = 8) -> String? {
            VideoHDRMetadata.classify(
                colorTransfer: nil, colorPrimaries: nil, colorSpace: nil, colorRange: nil,
                bitDepth: nil,
                dolbyVision: VideoDolbyVisionInfo(profile: profile, level: nil, blCompatibilityID: compat,
                                                  rpuPresent: nil, elPresent: nil, blPresent: nil),
                hdr10PlusPresent: nil, rangeDescribesHDR: nil)?.displayLabel
        }
        #expect(label(1) == "Dolby Vision P8 (HDR10 fallback)")
        #expect(label(6) == "Dolby Vision P8 (HDR10 fallback)")
        #expect(label(2) == "Dolby Vision P8 (SDR fallback)")
        #expect(label(4) == "Dolby Vision P8 (HLG fallback)")
        #expect(label(nil) == "Dolby Vision P8")
        #expect(label(0, profile: 5) == "Dolby Vision P5 (no fallback)")
    }
}
