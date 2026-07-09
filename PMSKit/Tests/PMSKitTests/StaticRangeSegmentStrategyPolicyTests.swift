import Testing
@testable import PMSKit

@Suite("Static range segment strategy policy")
struct StaticRangeSegmentStrategyPolicyTests {

    @Test("All scene phases prefer one continuous remainder task")
    func allScenePhasesPreferContinuousRemainder() {
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "inactive")
            == .init(normalizedPhase: "inactive",
                     preferenceReason: "scene_inactive",
                     diagnosticStrategy: "continuous_remainder",
                     shouldCountDurableCandidates: false))
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "BACKGROUND")
            == .init(normalizedPhase: "background",
                     preferenceReason: "scene_background",
                     diagnosticStrategy: "continuous_remainder",
                     shouldCountDurableCandidates: false))
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "active")
            == .init(normalizedPhase: "active",
                     preferenceReason: "single_remainder",
                     diagnosticStrategy: "continuous_remainder",
                     shouldCountDurableCandidates: false))
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "weird")
            == .init(normalizedPhase: "weird",
                     preferenceReason: "single_remainder",
                     diagnosticStrategy: "continuous_remainder",
                     shouldCountDurableCandidates: false))
    }

    @Test("Scene reason still uses one continuous remainder task")
    func sceneReasonUsesContinuousRemainder() {
        let preference = StaticRangeSegmentStrategyPolicy.segmentPreference(
            sceneReason: "scene_background"
        )

        #expect(preference.kind == .continuousRemainder)
        #expect(preference.reason == "scene_background")
    }

    @Test("No scene reason still uses one continuous remainder task")
    func noSceneReasonUsesContinuousRemainder() {
        let preference = StaticRangeSegmentStrategyPolicy.segmentPreference(sceneReason: nil)

        #expect(preference.kind == .continuousRemainder)
        #expect(preference.reason == "single_remainder")
    }
}
