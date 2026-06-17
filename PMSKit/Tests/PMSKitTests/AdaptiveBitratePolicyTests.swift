import Testing
@testable import PMSKit

private let fastConfig = AdaptiveBitratePolicy.Configuration(
    minimumSecondsBetweenChanges: 10,
    minimumSecondsAfterDownshiftBeforeUpshift: 60,
    healthyPlaybackWindowSeconds: 30,
    minimumBufferedAheadForUpshift: 20,
    requiredObservedHeadroom: 1.25,
    maxChangesPerWindow: 3,
    changeWindowSeconds: 120)

@Test func adaptiveFallbackStepsDownOneRungAtATime() {
    let policy = AdaptiveBitratePolicy()

    #expect(policy.fallbackBitrateKbps(afterStallAt: 8_000, userSelectedMaximumKbps: 8_000) == 4_000)
    #expect(policy.fallbackBitrateKbps(afterStallAt: 4_000, userSelectedMaximumKbps: 8_000) == 3_000)
    #expect(policy.fallbackBitrateKbps(afterStallAt: 3_000, userSelectedMaximumKbps: 8_000) == 2_000)
    #expect(policy.fallbackBitrateKbps(afterStallAt: 2_000, userSelectedMaximumKbps: 8_000) == nil)
}

@Test func adaptiveFallbackMapsMaximumSentinelsToHighestBoundedRung() {
    let policy = AdaptiveBitratePolicy()

    #expect(policy.fallbackBitrateKbps(afterStallAt: 0, userSelectedMaximumKbps: 0) == 40_000)
    #expect(policy.fallbackBitrateKbps(afterStallAt: 200_000, userSelectedMaximumKbps: 200_000) == 40_000)
}

@Test func adaptiveFallbackHandlesOffLadderCapsAndSanitizesRungs() {
    let policy = AdaptiveBitratePolicy(transcodedRungsKbps: [4_000, 2_000, 4_000, -1, 8_000])

    #expect(policy.transcodedRungsKbps == [2_000, 4_000, 8_000])
    #expect(policy.fallbackBitrateKbps(afterStallAt: 3_500, userSelectedMaximumKbps: 8_000) == 2_000)
    #expect(policy.fallbackBitrateKbps(afterStallAt: 9_000, userSelectedMaximumKbps: 8_000) == 8_000)
}

@Test func upshiftRequiresStableHealthyPlaybackWindow() {
    var policy = AdaptiveBitratePolicy(configuration: fastConfig)

    #expect(policy.recordHealthyPlayback(now: 0, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 25, likelyToKeepUp: true) == nil)
    #expect(policy.recordHealthyPlayback(now: 29, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 25, likelyToKeepUp: true) == nil)
    #expect(policy.recordHealthyPlayback(now: 30, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 25, likelyToKeepUp: true) == .init(direction: .up,
                                                                                                  targetKbps: 8_000,
                                                                                                  reason: "sustained_healthy_playback"))
}

@Test func unhealthySampleResetsUpshiftWindow() {
    var policy = AdaptiveBitratePolicy(configuration: fastConfig)

    #expect(policy.recordHealthyPlayback(now: 0, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 25, likelyToKeepUp: true) == nil)
    #expect(policy.recordHealthyPlayback(now: 5, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 5, likelyToKeepUp: true) == nil)
    #expect(policy.recordHealthyPlayback(now: 35, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 25, likelyToKeepUp: true) == nil)
    #expect(policy.recordHealthyPlayback(now: 65, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 25, likelyToKeepUp: true)?.targetKbps == 8_000)
}

@Test func noImmediateUpshiftAfterDownshiftEvenWithHealthyBuffer() {
    var policy = AdaptiveBitratePolicy(configuration: fastConfig)

    #expect(policy.recordStall(now: 0, currentKbps: 8_000, userSelectedMaximumKbps: 8_000)?.targetKbps == 4_000)
    #expect(policy.recordHealthyPlayback(now: 30, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 60, likelyToKeepUp: true,
                                         observedBitrateKbps: 20_000) == nil)
    #expect(policy.recordHealthyPlayback(now: 59, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 60, likelyToKeepUp: true,
                                         observedBitrateKbps: 20_000) == nil)
    #expect(policy.recordHealthyPlayback(now: 60, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 60, likelyToKeepUp: true,
                                         observedBitrateKbps: 20_000)?.targetKbps == 8_000)
}

@Test func observedBitrateMustHaveHeadroomBeforeUpshiftWhenAvailable() {
    var policy = AdaptiveBitratePolicy(configuration: fastConfig)

    #expect(policy.recordHealthyPlayback(now: 0, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 60, likelyToKeepUp: true,
                                         observedBitrateKbps: 9_000) == nil)
    #expect(policy.recordHealthyPlayback(now: 31, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 60, likelyToKeepUp: true,
                                         observedBitrateKbps: 9_000) == nil)
    #expect(policy.recordHealthyPlayback(now: 32, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 60, likelyToKeepUp: true,
                                         observedBitrateKbps: 10_000)?.targetKbps == 8_000)
}

@Test func alternatingStallAndHealthySignalsDoNotOscillateImmediately() {
    var policy = AdaptiveBitratePolicy(configuration: fastConfig)

    #expect(policy.recordStall(now: 0, currentKbps: 8_000, userSelectedMaximumKbps: 8_000)?.targetKbps == 4_000)
    #expect(policy.recordHealthyPlayback(now: 3, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 60, likelyToKeepUp: true,
                                         observedBitrateKbps: 20_000) == nil)
    #expect(policy.recordStall(now: 5, currentKbps: 4_000, userSelectedMaximumKbps: 8_000) == nil)
    #expect(policy.recordHealthyPlayback(now: 35, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 60, likelyToKeepUp: true,
                                         observedBitrateKbps: 20_000) == nil)
    #expect(policy.recordHealthyPlayback(now: 45, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 60, likelyToKeepUp: true,
                                         observedBitrateKbps: 20_000) == nil)
    #expect(policy.recordHealthyPlayback(now: 65, currentKbps: 4_000, userSelectedMaximumKbps: 8_000,
                                         bufferedAheadSeconds: 60, likelyToKeepUp: true,
                                         observedBitrateKbps: 20_000)?.direction == .up)
    #expect(policy.recordStall(now: 70, currentKbps: 8_000, userSelectedMaximumKbps: 8_000) == nil)
}

@Test func automaticChangesRespectLowerAndUserSelectedUpperBounds() {
    var policy = AdaptiveBitratePolicy(configuration: fastConfig)

    #expect(policy.recordStall(now: 0, currentKbps: 2_000, userSelectedMaximumKbps: 4_000) == nil)
    #expect(policy.upshiftBitrateKbps(afterHealthyPlaybackAt: 4_000, userSelectedMaximumKbps: 4_000) == nil)
    #expect(policy.upshiftBitrateKbps(afterHealthyPlaybackAt: 2_000, userSelectedMaximumKbps: 4_000) == 3_000)
    #expect(policy.boundedRungs(userSelectedMaximumKbps: 4_000) == [2_000, 3_000, 4_000])
}

@Test func frequencyCapLimitsAutomaticChangesWithinWindow() {
    var policy = AdaptiveBitratePolicy(configuration: fastConfig)

    #expect(policy.recordStall(now: 0, currentKbps: 40_000, userSelectedMaximumKbps: 40_000)?.targetKbps == 20_000)
    #expect(policy.recordStall(now: 10, currentKbps: 20_000, userSelectedMaximumKbps: 40_000)?.targetKbps == 12_000)
    #expect(policy.recordStall(now: 20, currentKbps: 12_000, userSelectedMaximumKbps: 40_000)?.targetKbps == 10_000)
    #expect(policy.recordStall(now: 30, currentKbps: 10_000, userSelectedMaximumKbps: 40_000) == nil)
    #expect(policy.recordStall(now: 121, currentKbps: 10_000, userSelectedMaximumKbps: 40_000)?.targetKbps == 8_000)
}
