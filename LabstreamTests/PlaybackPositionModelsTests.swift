import Testing
@testable import Labstream

struct PlaybackPositionModelsTests {
    @Test func transientZeroDoesNotReplaceMeaningfulPendingEvidence() {
        let pending = PlaybackPositionSample(positionMs: 60_000,
                                             capturedAt: 10,
                                             cause: .load)

        #expect(PlaybackPositionResolver.isTransientNearZero(
            0,
            seekHold: PlaybackSeekHold(),
            pending: pending,
            lastTrustworthy: nil,
            savedOffsetMs: nil))
    }

    @Test func explicitSeekToZeroOverridesOlderNonzeroEvidence() {
        var hold = PlaybackSeekHold()
        hold.begin(targetMs: 0, now: 20)
        let trusted = PlaybackPositionSample(positionMs: 60_000,
                                             capturedAt: 10,
                                             cause: .periodicLive)

        #expect(!PlaybackPositionResolver.isTransientNearZero(
            0,
            seekHold: hold,
            pending: nil,
            lastTrustworthy: trusted,
            savedOffsetMs: 60_000))
        #expect(PlaybackPositionResolver.terminalPosition(
            live: nil,
            liveIsTrustworthy: false,
            seekHold: hold,
            lastTrustworthy: trusted,
            savedOffsetMs: 60_000) == 0)
    }

    @Test func seekHoldIsGenerationFencedAndRearmedFromLatestTarget() {
        var hold = PlaybackSeekHold()
        hold.begin(targetMs: 10_000, now: 1)
        let firstGeneration = hold.generation
        hold.begin(targetMs: 20_000, now: 10)

        let staleClear = hold.clear(ifGeneration: firstGeneration)
        #expect(!staleClear)
        #expect(hold.target?.positionMs == 20_000)
        #expect(!hold.exceeded(maxSeconds: 12, now: 21.9))
        #expect(hold.exceeded(maxSeconds: 12, now: 22))
        let activeGeneration = hold.generation
        let activeClear = hold.clear(ifGeneration: activeGeneration)
        #expect(activeClear)
        #expect(!hold.isActive)
    }

    @Test func fallbackUsesFreshTypedEvidenceWithoutNearZeroRegression() {
        let oldPending = PlaybackPositionSample(positionMs: 55_000,
                                                capturedAt: 5,
                                                cause: .load)
        let transientNewer = PlaybackPositionSample(positionMs: 0,
                                                    capturedAt: 10,
                                                    cause: .currentItemChangedLive)
        let explicitNewer = PlaybackPositionSample(positionMs: 0,
                                                   capturedAt: 10,
                                                   cause: .userSeekTarget,
                                                   permitsNearZero: true)

        #expect(PlaybackPositionResolver.bestKnownFallback(
            pending: transientNewer,
            lastTrustworthy: oldPending)?.positionMs == 55_000)
        #expect(PlaybackPositionResolver.bestKnownFallback(
            pending: explicitNewer,
            lastTrustworthy: oldPending)?.positionMs == 0)
    }

    @Test func terminalPositionDoesNotRegressToDetachedLiveZero() {
        let live = PlaybackPositionSample(positionMs: 0,
                                          capturedAt: 20,
                                          cause: .currentResumeLive)
        let trusted = PlaybackPositionSample(positionMs: 45_000,
                                             capturedAt: 10,
                                             cause: .periodicLive)

        #expect(PlaybackPositionResolver.terminalPosition(
            live: live,
            liveIsTrustworthy: false,
            seekHold: PlaybackSeekHold(),
            lastTrustworthy: trusted,
            savedOffsetMs: 30_000) == 45_000)
    }
}
