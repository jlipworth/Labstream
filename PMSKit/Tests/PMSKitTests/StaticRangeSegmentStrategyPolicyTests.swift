import Testing
@testable import PMSKit

@Suite("Static range segment strategy policy")
struct StaticRangeSegmentStrategyPolicyTests {

    @Test("Inactive and background phases prefer background checkpoint chunks")
    func scenePhasesPreferBackgroundCheckpoints() {
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "inactive")
            == .init(normalizedPhase: "inactive",
                     preferenceReason: "scene_inactive",
                     diagnosticStrategy: "background_checkpoint",
                     shouldCountDurableCandidates: true))
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "BACKGROUND")
            == .init(normalizedPhase: "background",
                     preferenceReason: "scene_background",
                     diagnosticStrategy: "background_checkpoint",
                     shouldCountDurableCandidates: true))
    }

    @Test("Active and unknown phases use foreground bounded checkpoints")
    func activeAndUnknownPhasesUseBoundedCheckpoints() {
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "active")
            == .init(normalizedPhase: "active",
                     preferenceReason: nil,
                     diagnosticStrategy: "bounded_checkpoint",
                     shouldCountDurableCandidates: false))
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "weird")
            == .init(normalizedPhase: "weird",
                     preferenceReason: nil,
                     diagnosticStrategy: "bounded_checkpoint",
                     shouldCountDurableCandidates: false))
    }

    @Test("Scene reason wins over background completion handoff reason")
    func sceneReasonWins() {
        let preference = StaticRangeSegmentStrategyPolicy.segmentPreference(
            sceneReason: "scene_background",
            holdBackgroundCompletionForFirstProgress: true
        )

        #expect(preference.kind == .backgroundCheckpoint)
        #expect(preference.reason == "scene_background")
    }

    @Test("Background completion handoff uses background checkpoint chunks")
    func backgroundCompletionHandoffUsesBackgroundCheckpoint() {
        let preference = StaticRangeSegmentStrategyPolicy.segmentPreference(
            sceneReason: nil,
            holdBackgroundCompletionForFirstProgress: true
        )

        #expect(preference.kind == .backgroundCheckpoint)
        #expect(preference.reason == "background_events")
    }

    @Test("No background pressure uses bounded checkpoint chunks")
    func noBackgroundPressureUsesBoundedCheckpoint() {
        let preference = StaticRangeSegmentStrategyPolicy.segmentPreference(
            sceneReason: nil,
            holdBackgroundCompletionForFirstProgress: false
        )

        #expect(preference.kind == .boundedCheckpoint)
        #expect(preference.reason == nil)
    }
}
