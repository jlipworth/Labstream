import Testing
@testable import Labstream

struct PlaybackRestartIntentTests {
    @Test func ordinaryRestartsShareTheExactExistingPreparationRecipe() {
        let intents: [PlaybackRestartIntent] = [
            .subtitleTrackChange,
            .audioTrackChange,
            .qualityChange,
            .adaptiveBitrate,
        ]
        // Ordinary intents plus explicitRetry; a new case must get its own exact plan test.
        #expect(PlaybackRestartIntent.allCases.count == 5)

        for intent in intents {
            let plan = intent.plan
            #expect(plan.preparationSteps == [
                .resetFinalTarget,
                .rearmStartupDeadlineRetry,
                .removeObservers,
            ])
            #expect(plan.plexControlClient == .preserve)
        }
    }

    @Test func explicitRetryRetainsItsAdditionalRecoveryPreparation() {
        let plan = PlaybackRestartIntent.explicitRetry.plan

        #expect(plan.preparationSteps == [
            .resetFinalTarget,
            .resetAdaptiveBitrate,
            .rearmStartupDeadlineRetry,
            .clearPlaybackError,
            .removeObservers,
        ])
        #expect(plan.plexControlClient == .refreshForRecovery)
    }
}
