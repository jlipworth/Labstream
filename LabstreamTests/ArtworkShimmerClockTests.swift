import Testing
@testable import Labstream

@Suite("Artwork shimmer clock")
@MainActor
struct ArtworkShimmerClockTests {
    @Test func visiblePlaceholdersShareExactlyOneAnimationTask() {
        let clock = ArtworkShimmerClock(tickInterval: .seconds(60))

        let first = clock.subscribe(reduceMotion: false)
        let second = clock.subscribe(reduceMotion: false)

        #expect(first != nil)
        #expect(second != nil)
        #expect(clock.subscriberCount == 2)
        #expect(clock.animationStartCount == 1)
        #expect(clock.hasAnimationTask)

        if let first { clock.unsubscribe(first) }
        #expect(clock.subscriberCount == 1)
        #expect(clock.hasAnimationTask)

        if let second { clock.unsubscribe(second) }
        #expect(clock.subscriberCount == 0)
        #expect(!clock.hasAnimationTask)
    }

    @Test func reduceMotionDoesNotStartAnimationWork() {
        let clock = ArtworkShimmerClock(tickInterval: .seconds(60))

        let subscription = clock.subscribe(reduceMotion: true)

        #expect(subscription == nil)
        #expect(clock.subscriberCount == 0)
        #expect(clock.animationStartCount == 0)
        #expect(!clock.hasAnimationTask)
        #expect(clock.phase == -1)
    }

    @Test func duplicateReleaseCannotStopAnotherPlaceholder() throws {
        let clock = ArtworkShimmerClock(tickInterval: .seconds(60))
        let first = try #require(clock.subscribe(reduceMotion: false))
        let second = try #require(clock.subscribe(reduceMotion: false))

        clock.unsubscribe(first)
        clock.unsubscribe(first)

        #expect(clock.subscriberCount == 1)
        #expect(clock.hasAnimationTask)
        clock.unsubscribe(second)
        #expect(!clock.hasAnimationTask)
    }
}
