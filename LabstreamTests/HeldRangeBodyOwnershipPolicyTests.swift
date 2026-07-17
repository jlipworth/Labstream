import Foundation
import PMSKit
import Testing
@testable import Labstream

struct HeldRangeBodyOwnershipPolicyTests {
    private let old = URL(fileURLWithPath: "/tmp/held-old")
    private let middle = URL(fileURLWithPath: "/tmp/held-middle")
    private let newest = URL(fileURLWithPath: "/tmp/held-newest")

    @Test func failedReplacementRetainsEveryPredecessor() {
        let plan = HeldRangeBodyOwnershipPolicy.replacementPlan(
            haltKind: nil,
            manifestCommitted: false,
            newBody: newest,
            predecessors: [middle],
            alreadyRetained: [old]
        )
        #expect(plan.installNewBody)
        #expect(plan.retainPredecessors == [old, middle])
        #expect(plan.deleteBodies.isEmpty)
    }

    @Test func laterCommittedReplacementCleansEveryPredecessor() {
        let plan = HeldRangeBodyOwnershipPolicy.replacementPlan(
            haltKind: nil,
            manifestCommitted: true,
            newBody: newest,
            predecessors: [middle],
            alreadyRetained: [old]
        )
        #expect(plan.installNewBody)
        #expect(plan.retainPredecessors.isEmpty)
        #expect(plan.deleteBodies == [old, middle])
    }

    @Test func cancelRefusesInstallAndOwnsAllGenerations() {
        let plan = HeldRangeBodyOwnershipPolicy.replacementPlan(
            haltKind: .cancel,
            manifestCommitted: false,
            newBody: newest,
            predecessors: [middle],
            alreadyRetained: [old]
        )
        #expect(!plan.installNewBody)
        #expect(plan.retainPredecessors.isEmpty)
        #expect(plan.deleteBodies == [old, middle, newest])
    }

    @Test func removalAndPurgeIncludeRetainedGenerations() {
        #expect(HeldRangeBodyOwnershipPolicy.removalBodies(
            current: newest,
            persisted: middle,
            fallback: [],
            retainedPredecessors: [old]
        ) == [old, middle, newest])
        #expect(HeldRangeBodyOwnershipPolicy.purgeBodies(
            current: [newest],
            persisted: [middle],
            retainedPredecessors: [[old]]
        ) == [old, middle, newest])
    }
}
