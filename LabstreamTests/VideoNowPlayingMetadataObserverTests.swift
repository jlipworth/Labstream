import Testing
@testable import Labstream

@MainActor
@Suite("Video Now Playing event observer")
struct VideoNowPlayingMetadataObserverTests {
    @Test func publishesExactDynamicOverrides() {
        let registry = VideoNowPlayingMetadataObserverRegistry()
        var received: [VideoNowPlayingMetadataUpdate] = []
        registry.observe { received.append($0) }

        registry.publish(.init(elapsedMillisecondsOverride: 12_345,
                               playbackRateOverride: 1.25))

        #expect(received == [.init(elapsedMillisecondsOverride: 12_345,
                                  playbackRateOverride: 1.25)])
    }

    @Test func staleRemovalCannotUnregisterReplacementObserver() {
        let registry = VideoNowPlayingMetadataObserverRegistry()
        var received: [String] = []
        let stale = registry.observe { _ in received.append("stale") }
        let current = registry.observe { _ in received.append("current") }

        registry.remove(stale)
        registry.publish(.init(elapsedMillisecondsOverride: nil, playbackRateOverride: 0))
        registry.remove(current)
        registry.publish(.init(elapsedMillisecondsOverride: nil, playbackRateOverride: 1))

        #expect(received == ["current"])
    }
}
