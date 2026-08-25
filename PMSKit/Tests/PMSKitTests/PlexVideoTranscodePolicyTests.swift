import Testing
@testable import PMSKit

@Suite("Plex video transcode policy")
struct PlexVideoTranscodePolicyTests {
    @Test func initialDirectPlayMaximumPreservesCopyLane() {
        #expect(!PlexVideoTranscodePolicy.shouldForceVideoTranscode(
            selectedQualityKbps: StreamingQuality.maximumOriginalKbps,
            directPlayProductionFallback: false,
            dolbyVisionGuardActive: false))
    }

    @Test func directPlayProductionFallbackCannotRepeatRejectedCopyLane() {
        #expect(PlexVideoTranscodePolicy.shouldForceVideoTranscode(
            selectedQualityKbps: StreamingQuality.maximumOriginalKbps,
            directPlayProductionFallback: true,
            dolbyVisionGuardActive: false))
    }

    @Test func maximumHLSIsAnExplicitVideoTranscode() {
        #expect(PlexVideoTranscodePolicy.shouldForceVideoTranscode(
            selectedQualityKbps: StreamingQuality.maxTranscodedKbps,
            directPlayProductionFallback: false,
            dolbyVisionGuardActive: false))
    }

    @Test func ordinaryCapReliesOnTheBitrateLimit() {
        #expect(!PlexVideoTranscodePolicy.shouldForceVideoTranscode(
            selectedQualityKbps: 20_000,
            directPlayProductionFallback: false,
            dolbyVisionGuardActive: false))
    }

    @Test func dolbyVisionGuardStillForcesEveryQuality() {
        #expect(PlexVideoTranscodePolicy.shouldForceVideoTranscode(
            selectedQualityKbps: 20_000,
            directPlayProductionFallback: false,
            dolbyVisionGuardActive: true))
    }
}
