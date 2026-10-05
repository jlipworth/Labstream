import Testing
@testable import Labstream

struct PlaybackRelativeSeekPolicyTests {
    @Test func rapidOppositeJumpsComposeAgainstOutstandingTarget() {
        let forward = PlaybackRelativeSeekPolicy.target(heldMs: nil, liveMs: 571_000,
            explicitBaseMs: nil, fallbackMs: 0, deltaSeconds: 30, durationMs: nil)
        #expect(forward == 601_000)
        let backward = PlaybackRelativeSeekPolicy.target(heldMs: forward, liveMs: 571_000,
            explicitBaseMs: 571_000, fallbackMs: 0, deltaSeconds: -30, durationMs: nil)
        #expect(backward == 571_000)
    }

    @Test func clearedHoldUsesAdvancingLiveClockThenExplicitBaseThenFallback() {
        #expect(PlaybackRelativeSeekPolicy.target(heldMs: nil, liveMs: 610_000,
            explicitBaseMs: 571_000, fallbackMs: 1, deltaSeconds: 10, durationMs: nil) == 620_000)
        #expect(PlaybackRelativeSeekPolicy.target(heldMs: nil, liveMs: nil,
            explicitBaseMs: 571_000, fallbackMs: 1, deltaSeconds: 10, durationMs: nil) == 581_000)
        #expect(PlaybackRelativeSeekPolicy.target(heldMs: nil, liveMs: nil,
            explicitBaseMs: nil, fallbackMs: 571_000, deltaSeconds: 10, durationMs: nil) == 581_000)
    }

    @Test func zeroHoldIsAuthoritativeAndFallbackIsLazy() {
        var fallbackCalls = 0
        func fallback() -> Int { fallbackCalls += 1; return 600_000 }
        #expect(PlaybackRelativeSeekPolicy.target(heldMs: 0, liveMs: 571_000,
            explicitBaseMs: nil, fallbackMs: fallback(), deltaSeconds: 10, durationMs: nil) == 10_000)
        #expect(fallbackCalls == 0)
    }

    @Test func clampsAndOverflowRetainSafeBounds() {
        #expect(PlaybackRelativeSeekPolicy.target(heldMs: nil, liveMs: 1000,
            explicitBaseMs: nil, fallbackMs: 0, deltaSeconds: -30, durationMs: 6000) == 0)
        #expect(PlaybackRelativeSeekPolicy.target(heldMs: nil, liveMs: 1000,
            explicitBaseMs: nil, fallbackMs: 0, deltaSeconds: 30, durationMs: 6000) == 6000)
        #expect(PlaybackRelativeSeekPolicy.target(heldMs: nil, liveMs: Int.max,
            explicitBaseMs: nil, fallbackMs: 0, deltaSeconds: Int.max, durationMs: nil) == Int.max)
        #expect(PlaybackRelativeSeekPolicy.target(heldMs: nil, liveMs: 1000,
            explicitBaseMs: nil, fallbackMs: 0, deltaSeconds: Int.min, durationMs: nil) == 0)
    }
}
