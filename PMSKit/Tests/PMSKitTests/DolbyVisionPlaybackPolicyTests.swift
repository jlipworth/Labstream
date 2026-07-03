import Testing
@testable import PMSKit

@Suite("Dolby Vision playback policy (P5 guard)")
struct DolbyVisionPlaybackPolicyTests {
    private func dvMetadata(profile: Int?, blCompatibilityID: Int?) -> VideoHDRMetadata {
        VideoHDRMetadata.classify(
            colorTransfer: nil, colorPrimaries: "bt2020", colorSpace: nil, colorRange: nil,
            bitDepth: 10,
            dolbyVision: VideoDolbyVisionInfo(profile: profile, level: 6,
                                              blCompatibilityID: blCompatibilityID,
                                              rpuPresent: true, elPresent: false, blPresent: true),
            hdr10PlusPresent: nil, rangeDescribesHDR: true)!
    }

    @Test func p5NoFallbackIsForced() {
        let verdict = DolbyVisionPlaybackPolicy.verdict(
            for: dvMetadata(profile: 5, blCompatibilityID: 0),
            experimentalDVSignallingEnabled: false)
        guard case .forceToneMapTranscode(let reason) = verdict else {
            Issue.record("expected forceToneMapTranscode, got \(verdict)")
            return
        }
        #expect(reason.contains("P5"))
    }

    @Test func p5UnknownCompatIsForced() {
        // Emby DoviProfile5x may omit compat; profile 5 alone means no fallback layer.
        let verdict = DolbyVisionPlaybackPolicy.verdict(
            for: dvMetadata(profile: 5, blCompatibilityID: nil),
            experimentalDVSignallingEnabled: false)
        #expect(verdict != .allowCopyLanes)
    }

    @Test func unknownProfileCompatZeroIsForced() {
        // Compat 0 = no fallback regardless of which profile the backend failed to report.
        let verdict = DolbyVisionPlaybackPolicy.verdict(
            for: dvMetadata(profile: nil, blCompatibilityID: 0),
            experimentalDVSignallingEnabled: false)
        #expect(verdict != .allowCopyLanes)
    }

    @Test func p7WithHDR10FallbackAllowsCopy() {
        let verdict = DolbyVisionPlaybackPolicy.verdict(
            for: dvMetadata(profile: 7, blCompatibilityID: 6),
            experimentalDVSignallingEnabled: false)
        #expect(verdict == .allowCopyLanes)
    }

    @Test func p8WithHDR10FallbackAllowsCopy() {
        let verdict = DolbyVisionPlaybackPolicy.verdict(
            for: dvMetadata(profile: 8, blCompatibilityID: 1),
            experimentalDVSignallingEnabled: false)
        #expect(verdict == .allowCopyLanes)
    }

    @Test func unknownProfileUnknownCompatAllowsCopy() {
        // No positive evidence of a fallback-less stream — stay out of the way.
        let verdict = DolbyVisionPlaybackPolicy.verdict(
            for: dvMetadata(profile: nil, blCompatibilityID: nil),
            experimentalDVSignallingEnabled: false)
        #expect(verdict == .allowCopyLanes)
    }

    @Test func nilMetadataAllowsCopy() {
        #expect(DolbyVisionPlaybackPolicy.verdict(for: nil,
                                                  experimentalDVSignallingEnabled: false)
            == .allowCopyLanes)
    }

    @Test func nonDVHDRAllowsCopy() {
        let hdr10 = VideoHDRMetadata.classify(
            colorTransfer: "smpte2084", colorPrimaries: "bt2020", colorSpace: nil,
            colorRange: nil, bitDepth: 10, dolbyVision: nil, hdr10PlusPresent: nil,
            rangeDescribesHDR: nil)!
        #expect(DolbyVisionPlaybackPolicy.verdict(for: hdr10,
                                                  experimentalDVSignallingEnabled: false)
            == .allowCopyLanes)
    }

    @Test func experimentalSignallingDefersTheGuard() {
        // User opted into the DV lane; the guard must not force a transcode it would contradict.
        let verdict = DolbyVisionPlaybackPolicy.verdict(
            for: dvMetadata(profile: 5, blCompatibilityID: 0),
            experimentalDVSignallingEnabled: true)
        #expect(verdict == .allowCopyLanes)
    }
}
