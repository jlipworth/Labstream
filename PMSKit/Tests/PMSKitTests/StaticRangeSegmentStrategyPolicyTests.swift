import Testing
@testable import PMSKit

@Suite("Static range segment strategy policy")
struct StaticRangeSegmentStrategyPolicyTests {

    @Test("All scene phases normalize and label the continuous remainder strategy")
    func allScenePhasesPreferContinuousRemainder() {
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "inactive")
            == .init(normalizedPhase: "inactive",
                     diagnosticStrategy: "continuous_remainder"))
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "BACKGROUND")
            == .init(normalizedPhase: "background",
                     diagnosticStrategy: "continuous_remainder"))
        #expect(StaticRangeSegmentStrategyPolicy.sceneStrategy(phase: "weird")
            == .init(normalizedPhase: "weird",
                     diagnosticStrategy: "continuous_remainder"))
    }

    @Test("Default segment reason is the single remainder")
    func defaultSegmentReason() {
        #expect(StaticRangeSegmentStrategyPolicy.segmentReason == "single_remainder")
    }
}
