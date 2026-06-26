import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser playback policies")
struct MediaBrowserPlaybackPolicyTests {
    @Test func qualityPolicyKeepsUnlimitedAtServerMaximumWithoutCaps() {
        let policy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: 0)

        #expect(policy.maxStreamingBitrateBps == 200_000_000)
        #expect(policy.maxWidth == nil)
        #expect(policy.maxHeight == nil)
        #expect(policy.audioBitrateBps == nil)
    }

    @Test func qualityPolicyMapsFourMbpsTo720pAndAudioCap() {
        let policy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: 4_000)

        #expect(policy.maxStreamingBitrateBps == 4_000_000)
        #expect(policy.maxWidth == 1280)
        #expect(policy.maxHeight == 720)
        #expect(policy.audioBitrateBps == 256_000)
    }

    @Test func qualityPolicyMapsTwentyMbpsTo1080pAndAudioCap() {
        let policy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: 20_000)

        #expect(policy.maxStreamingBitrateBps == 20_000_000)
        #expect(policy.maxWidth == 1920)
        #expect(policy.maxHeight == 1080)
        #expect(policy.audioBitrateBps == 640_000)
    }

    @Test func qualityPolicyMapsFortyMbpsTo4KWithoutAudioCap() {
        let policy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: 40_000)

        #expect(policy.maxStreamingBitrateBps == 40_000_000)
        #expect(policy.maxWidth == 3840)
        #expect(policy.maxHeight == 2160)
        #expect(policy.audioBitrateBps == nil)
    }

    @Test func qualityPolicyConvertsMillisecondsToTicks() {
        #expect(MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: nil) == nil)
        #expect(MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: 1) == 10_000)
        #expect(MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: 123_456) == 1_234_560_000)
    }

    @Test func activeEncodingStopPolicyConfirmsOnlySuccessfulOrGoneStatuses() {
        for status in [200, 204, 299, 400, 404, 410] {
            #expect(MediaBrowserActiveEncodingStopPolicy.isConfirmedStopped(httpStatus: status))
        }
        for status in [nil, 300, 401, 403, 409, 429, 500, 503] as [Int?] {
            #expect(!MediaBrowserActiveEncodingStopPolicy.isConfirmedStopped(httpStatus: status))
        }
    }
}
