import Testing
import Foundation
@testable import PMSKit

// GH #195 — backend-neutral HDR classification. The precedence order matters:
// Dolby Vision beats HDR10+ beats PQ/HLG transfer beats generic "HDR" range
// strings, and SDR is only claimed on positive SDR evidence.

@Suite("VideoHDRMetadata classification")
struct VideoHDRMetadataClassificationTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        var transfer: String? = nil
        var primaries: String? = nil
        var colorSpace: String? = nil
        var colorRange: String? = nil
        var bitDepth: Int? = nil
        var dolbyVision: VideoDolbyVisionInfo? = nil
        var hdr10Plus: Bool? = nil
        var rangeDescribesHDR: Bool? = nil
        /// nil means classify must decline to claim any format.
        let expected: VideoHDRFormat?
        /// Also pin that the DV profile and bit depth pass through unchanged.
        var checksPassThrough = false

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "Dolby Vision with HDR10 fallback wins",
             transfer: "smpte2084", primaries: "bt2020", colorSpace: "bt2020nc",
             bitDepth: 10,
             dolbyVision: VideoDolbyVisionInfo(profile: 8, level: 6, blCompatibilityID: 1,
                                               rpuPresent: true, elPresent: false, blPresent: true),
             expected: .dolbyVision, checksPassThrough: true),
        Case(name: "Dolby Vision profile 5 without fallback",
             bitDepth: 10,
             dolbyVision: VideoDolbyVisionInfo(profile: 5, level: 6, blCompatibilityID: 0,
                                               rpuPresent: true, elPresent: false, blPresent: true),
             expected: .dolbyVision),
        Case(name: "HDR10+ flag beats plain PQ",
             transfer: "smpte2084", primaries: "bt2020", bitDepth: 10, hdr10Plus: true,
             expected: .hdr10Plus),
        Case(name: "PQ transfer classifies HDR10",
             transfer: "smpte2084", primaries: "bt2020", colorSpace: "bt2020nc", colorRange: "tv",
             bitDepth: 10,
             expected: .hdr10),
        Case(name: "HLG transfer classifies HLG",
             transfer: "arib-std-b67", primaries: "bt2020", bitDepth: 10,
             expected: .hlg),
        Case(name: "generic HDR range without transfer is unknown HDR",
             rangeDescribesHDR: true,
             expected: .unknownHDR),
        Case(name: "bt709 transfer classifies SDR",
             transfer: "bt709", primaries: "bt709", colorSpace: "bt709", colorRange: "tv",
             bitDepth: 8,
             expected: .sdr),
        Case(name: "explicit SDR range classifies SDR",
             bitDepth: 8, rangeDescribesHDR: false,
             expected: .sdr),
        Case(name: "nothing known returns nil",
             expected: nil),
        // 10-bit SDR encodes exist; bit depth alone must not flip the label to HDR.
        Case(name: "10-bit alone is not claimed as HDR",
             bitDepth: 10,
             expected: nil),
    ]

    @Test(arguments: cases)
    func classify(_ c: Case) {
        let hdr = VideoHDRMetadata.classify(
            colorTransfer: c.transfer,
            colorPrimaries: c.primaries,
            colorSpace: c.colorSpace,
            colorRange: c.colorRange,
            bitDepth: c.bitDepth,
            dolbyVision: c.dolbyVision,
            hdr10PlusPresent: c.hdr10Plus,
            rangeDescribesHDR: c.rangeDescribesHDR)
        if let expected = c.expected {
            #expect(hdr?.format == expected)
        } else {
            #expect(hdr == nil)
        }
        if c.checksPassThrough {
            #expect(hdr?.dolbyVision?.profile == c.dolbyVision?.profile)
            #expect(hdr?.bitDepth == c.bitDepth)
        }
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
