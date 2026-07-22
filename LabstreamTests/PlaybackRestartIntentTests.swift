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

        for intent in intents {
            let plan = intent.plan
            #expect(plan.preparationSteps == [
                .resetFinalTarget,
                .rearmStartupDeadlineRetry,
                .removeObservers,
            ])
            #expect(plan.plexControlClient == .preserve)
            #expect(plan.remoteBuffering == .standard)
            #expect(!plan.remoteBuffering.prefersShortBuffer)
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
        #expect(plan.remoteBuffering == .standard)
    }

    @Test func everyRestartIntentHasAnExplicitPlan() {
        #expect(PlaybackRestartIntent.allCases.count == 5)
        #expect(PlaybackRestartIntent.allCases.allSatisfy {
            $0.plan.preparationSteps.contains(.resetFinalTarget)
                && $0.plan.preparationSteps.contains(.rearmStartupDeadlineRetry)
                && $0.plan.preparationSteps.contains(.removeObservers)
        })
    }
}
