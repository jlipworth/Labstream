import Testing
@testable import PMSKit

@Suite("Video Now Playing command policy")
struct VideoNowPlayingCommandPolicyTests {
    @Test func rejectsMissingNonFiniteAndNegativePositions() {
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: nil,
                                                        durationMilliseconds: 10_000) == nil)
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: -.infinity,
                                                        durationMilliseconds: 10_000) == nil)
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: .infinity,
                                                        durationMilliseconds: 10_000) == nil)
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: -12,
                                                        durationMilliseconds: 10_000) == nil)
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: .nan,
                                                        durationMilliseconds: 10_000) == nil)
    }

    @Test func convertsSecondsToMillisecondsAndClampsToDuration() {
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: 0,
                                                        durationMilliseconds: 60_000) == .seek(toMilliseconds: 0))
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: 12.345,
                                                        durationMilliseconds: 60_000) == .seek(toMilliseconds: 12_345))
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: 90,
                                                        durationMilliseconds: 60_000) == .seek(toMilliseconds: 60_000))
    }

    @Test func allowsOpenEndedDurations() {
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: 90,
                                                        durationMilliseconds: nil) == .seek(toMilliseconds: 90_000))
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: 90,
                                                        durationMilliseconds: 0) == .seek(toMilliseconds: 90_000))
    }

    @Test func hugeFinitePositionsDoNotTrapTheIntConversion() {
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: 1e16,
                                                        durationMilliseconds: 60_000) == .seek(toMilliseconds: 60_000))
        #expect(VideoNowPlayingCommandPolicy.seekIntent(positionTime: .greatestFiniteMagnitude,
                                                        durationMilliseconds: nil) == .seek(toMilliseconds: Int.max))
    }

    @Test func missingSkipUsesFallbackInTheRequestedDirection() {
        #expect(VideoNowPlayingCommandPolicy.skipIntent(interval: nil,
                                                        fallbackSeconds: 30,
                                                        direction: .forward) == .skip(bySeconds: 30))
        #expect(VideoNowPlayingCommandPolicy.skipIntent(interval: nil,
                                                        fallbackSeconds: 10,
                                                        direction: .backward) == .skip(bySeconds: -10))
    }

    @Test func validatesAndRoundsSuppliedSkipIntervals() {
        #expect(VideoNowPlayingCommandPolicy.skipIntent(interval: 15.6,
                                                        fallbackSeconds: 30,
                                                        direction: .forward) == .skip(bySeconds: 16))
        #expect(VideoNowPlayingCommandPolicy.skipIntent(interval: 0.25,
                                                        fallbackSeconds: 30,
                                                        direction: .backward) == .skip(bySeconds: -1))
    }

    @Test func rejectsMalformedSkipInsteadOfUsingFallback() {
        for malformed in [Double.nan, .infinity, -.infinity, -1, 0,
                          Double(Int.max / 1000) + 1] {
            #expect(VideoNowPlayingCommandPolicy.skipIntent(interval: malformed,
                                                            fallbackSeconds: 30,
                                                            direction: .forward) == nil)
        }
        #expect(VideoNowPlayingCommandPolicy.skipIntent(interval: nil,
                                                        fallbackSeconds: .nan,
                                                        direction: .forward) == nil)
    }
}
