import Testing
@testable import PMSKit

@Suite("Static range segment strategy policy")
struct StaticRangeSegmentStrategyPolicyTests {

    @Test("Inactive and background phases prefer one continuous remainder task")
    func scenePhasesPreferContinuousRemainder() {
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "inactive")
            == .init(normalizedPhase: "inactive",
                     preferenceReason: "scene_inactive",
                     diagnosticStrategy: "continuous_remainder",
                     shouldCountDurableCandidates: true))
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "BACKGROUND")
            == .init(normalizedPhase: "background",
                     preferenceReason: "scene_background",
                     diagnosticStrategy: "continuous_remainder",
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

        #expect(preference.kind == .continuousRemainder)
        #expect(preference.reason == "scene_background")
    }

    @Test("Background completion handoff uses one continuous remainder task")
    func backgroundCompletionHandoffUsesContinuousRemainder() {
        let preference = StaticRangeSegmentStrategyPolicy.segmentPreference(
            sceneReason: nil,
            holdBackgroundCompletionForFirstProgress: true
        )

        #expect(preference.kind == .continuousRemainder)
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

    // MARK: Foreground demotion of an in-flight remainder task

    @Test("Remainder with little temp progress demotes to bounded chunks on wake")
    func smallRemainderDemotesOnWake() {
        #expect(StaticRangeSegmentStrategyPolicy.foregroundDemotionDecision(
            segmentKind: .continuousRemainder,
            chunkBytesWritten: 10 * 1_024 * 1_024,
            hasRequest: true,
            maxDiscardBytes: 64 * 1_024 * 1_024
        ) == .demoteToBounded)
    }

    @Test("Remainder with substantial temp progress keeps running on wake")
    func largeRemainderKeepsRunningOnWake() {
        #expect(StaticRangeSegmentStrategyPolicy.foregroundDemotionDecision(
            segmentKind: .continuousRemainder,
            chunkBytesWritten: 65 * 1_024 * 1_024,
            hasRequest: true,
            maxDiscardBytes: 64 * 1_024 * 1_024
        ) == .keepRunning)
    }

    @Test("Demotion boundary: exactly maxDiscardBytes still demotes")
    func remainderAtBoundaryDemotes() {
        #expect(StaticRangeSegmentStrategyPolicy.foregroundDemotionDecision(
            segmentKind: .continuousRemainder,
            chunkBytesWritten: 64 * 1_024 * 1_024,
            hasRequest: true,
            maxDiscardBytes: 64 * 1_024 * 1_024
        ) == .demoteToBounded)
    }

    @Test("Adopted remainder without a rebuildable request keeps running")
    func adoptedRemainderWithoutRequestKeepsRunning() {
        #expect(StaticRangeSegmentStrategyPolicy.foregroundDemotionDecision(
            segmentKind: .continuousRemainder,
            chunkBytesWritten: 0,
            hasRequest: false,
            maxDiscardBytes: 64 * 1_024 * 1_024
        ) == .keepRunning)
    }

    @Test("Bounded segments are never demotion candidates")
    func boundedSegmentsNeverDemote() {
        for kind in [RangeTransferSegmentKind.boundedCheckpoint, .backgroundCheckpoint] {
            #expect(StaticRangeSegmentStrategyPolicy.foregroundDemotionDecision(
                segmentKind: kind,
                chunkBytesWritten: 0,
                hasRequest: true,
                maxDiscardBytes: 64 * 1_024 * 1_024
            ) == .keepRunning)
        }
    }
}
