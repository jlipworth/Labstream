import Testing
@testable import PMSKit

@Suite("Video Now Playing command profile")
struct VideoNowPlayingCommandProfileTests {
    @Test func processWidePreservesAdvertisedIntervalsAndSelectedFallback() {
        let mobile = VideoNowPlayingCommandProfile.processWide(fallbackSeconds: 10)
        let mac = VideoNowPlayingCommandProfile.processWide(fallbackSeconds: 30)

        #expect(mobile.backwardFallbackSeconds == 10)
        #expect(mobile.forwardFallbackSeconds == 10)
        #expect(mac.backwardFallbackSeconds == 30)
        #expect(mac.forwardFallbackSeconds == 30)
        #expect(mobile.advertisedBackwardIntervals == [10, 30])
        #expect(mobile.advertisedForwardIntervals == [10, 30])
        #expect(mac.advertisedBackwardIntervals == [10, 30])
        #expect(mac.advertisedForwardIntervals == [10, 30])
    }

    @Test func playbackScopedPreservesDirectionSpecificIntervals() {
        let profile = VideoNowPlayingCommandProfile.playbackScoped

        #expect(profile.backwardFallbackSeconds == 10)
        #expect(profile.forwardFallbackSeconds == 30)
        #expect(profile.advertisedBackwardIntervals == [10])
        #expect(profile.advertisedForwardIntervals == [30])
    }
}
