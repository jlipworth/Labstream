import Testing
@testable import PMSKit

@Suite("Video Now Playing command policy")
struct VideoNowPlayingCommandPolicyTests {
    @Test func clampsInvalidAndNegativePositionsToStart() {
        #expect(VideoNowPlayingCommandPolicy.clampedPositionMilliseconds(positionTime: -.infinity,
                                                                        durationMilliseconds: 10_000) == 0)
        #expect(VideoNowPlayingCommandPolicy.clampedPositionMilliseconds(positionTime: -12,
                                                                        durationMilliseconds: 10_000) == 0)
        #expect(VideoNowPlayingCommandPolicy.clampedPositionMilliseconds(positionTime: .nan,
                                                                        durationMilliseconds: 10_000) == 0)
    }

    @Test func convertsSecondsToMillisecondsAndClampsToDuration() {
        #expect(VideoNowPlayingCommandPolicy.clampedPositionMilliseconds(positionTime: 12.345,
                                                                        durationMilliseconds: 60_000) == 12_345)
        #expect(VideoNowPlayingCommandPolicy.clampedPositionMilliseconds(positionTime: 90,
                                                                        durationMilliseconds: 60_000) == 60_000)
    }

    @Test func allowsOpenEndedDurations() {
        #expect(VideoNowPlayingCommandPolicy.clampedPositionMilliseconds(positionTime: 90,
                                                                        durationMilliseconds: nil) == 90_000)
    }

    @Test func hugeFinitePositionsDoNotTrapTheIntConversion() {
        // System-supplied positionTime is untrusted; finite values past Int.max/1000
        // used to fatal-trap in Int(_:). They must clamp, never crash.
        #expect(VideoNowPlayingCommandPolicy.clampedPositionMilliseconds(positionTime: 1e16,
                                                                        durationMilliseconds: 60_000) == 60_000)
        #expect(VideoNowPlayingCommandPolicy.clampedPositionMilliseconds(positionTime: .greatestFiniteMagnitude,
                                                                        durationMilliseconds: nil) == Int.max)
    }
}
