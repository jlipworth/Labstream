import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin download source plan")
struct JellyfinDownloadSourcePlanTests {
    @Test("Static originals are range resumable and source-sized")
    func staticOriginal() {
        let plan = JellyfinDownloadSourcePlan.staticOriginal(sourcePartBytes: 1_234)
        #expect(plan.route == .staticOriginal)
        #expect(plan.expectedBytes == 1_234)
        #expect(plan.playSessionID == nil)
        #expect(plan.mediaSourceID == nil)
        #expect(plan.metadataLaneOverride == nil)
        #expect(plan.route.usesByteRangeCheckpoint)
    }

    @Test("Bitrate transcodes are forward-only and estimated from profile")
    func transcode() {
        let profile = DownloadPresetPolicy.jellyfinTranscodeProfile(named: "720p 4 Mbps")
        let plan = JellyfinDownloadSourcePlan.transcode(decision: decision(videoCodec: "hevc", audioCodec: "dts", container: "mkv"),
                                                        durationMs: 10_000,
                                                        profile: profile)
        #expect(plan.route == .transcode)
        #expect(plan.route.isLiveForwardOnly)
        #expect(plan.expectedBytes == TranscodeSizeEstimator.bytes(durationMs: 10_000,
                                                                   videoBitrateBps: 4_000_000))
        #expect(plan.mediaSourceID == "source-1")
        #expect(plan.playSessionID == "play-1")
        #expect(plan.metadataLaneOverride == nil)
    }

    @Test("Compatible copyable sources stay remux and source-sized")
    func compatibleRemux() throws {
        let plan = JellyfinDownloadSourcePlan.compatible(decision: decision(videoCodec: "hevc",
                                                                            audioCodec: "aac",
                                                                            container: "mkv",
                                                                            size: 4_321),
                                                         sourcePartBytes: 1_234,
                                                         durationMs: 10_000,
                                                         fallbackProfile: DownloadPresetPolicy.jellyfinTranscodeProfile(named: "1080p 8 Mbps"))
        #expect(plan.route == .compatibleRemux)
        #expect(plan.isCompatibleRemux)
        #expect(plan.expectedBytes == 4_321)
        #expect(plan.metadataLaneOverride == nil)
        let eligibility = try #require(plan.compatibleEligibility)
        #expect(eligibility.videoCodec == "hevc")
        #expect(eligibility.copiesAudio)
    }

    @Test("Compatible unsafe sources fall back to transcode and restamp metadata lane")
    func compatibleFallbackTranscode() {
        let plan = JellyfinDownloadSourcePlan.compatible(decision: decision(videoCodec: "mpeg2video",
                                                                            audioCodec: "aac",
                                                                            container: "mpeg"),
                                                         sourcePartBytes: 1_234,
                                                         durationMs: 10_000,
                                                         fallbackProfile: DownloadPresetPolicy.jellyfinTranscodeProfile(named: "1080p 8 Mbps"))
        #expect(plan.route == .transcode)
        #expect(plan.expectedBytes == TranscodeSizeEstimator.bytes(durationMs: 10_000,
                                                                   videoBitrateBps: 8_000_000))
        #expect(plan.metadataLaneOverride == .optimize)
        #expect(plan.metadataOptimizeTargetNameOverride == DownloadPresetPolicy.jellyfinDefaultDownloadPreset)
        #expect(plan.compatibleEligibility?.isEligible == false)
    }

    private func decision(videoCodec: String?,
                          audioCodec: String?,
                          container: String?,
                          size: Int? = nil) -> JellyfinDownloadPlaybackDecision {
        JellyfinDownloadPlaybackDecision(playSessionId: "play-1",
                                         mediaSourceId: "source-1",
                                         supportsDirectPlay: false,
                                         supportsDirectStream: true,
                                         transcodingURL: nil,
                                         size: size,
                                         container: container,
                                         bitrate: nil,
                                         videoCodec: videoCodec,
                                         audioCodec: audioCodec,
                                         transcodeReasons: [])
    }
}
