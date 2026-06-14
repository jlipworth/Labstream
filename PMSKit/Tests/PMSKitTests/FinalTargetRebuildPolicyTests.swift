import Testing
import Foundation
@testable import PMSKit

@Test func finalTargetRebuildPolicyCoalescesRapidInputsToLatestTarget() {
    var policy = FinalTargetRebuildPolicy()

    policy.recordFinalTarget(offsetMs: 100_000)
    policy.recordFinalTarget(offsetMs: 250_000)
    policy.recordFinalTarget(offsetMs: 900_000)

    #expect(policy.consumePendingTarget() == 900_000)
    #expect(policy.consumePendingTarget() == nil)
}

@Test func finalTargetRebuildPolicyRejectsConcurrentRebuilds() {
    var policy = FinalTargetRebuildPolicy()

    #expect(policy.beginRebuild(offsetMs: 100_000, now: 0) == .start(generation: 1, offsetMs: 100_000))
    #expect(policy.beginRebuild(offsetMs: 200_000, now: 1) == .alreadyRebuilding(generation: 1))

    policy.finishRebuild(generation: 1)
    #expect(policy.beginRebuild(offsetMs: 200_000, now: 10) == .start(generation: 2, offsetMs: 200_000))
}

@Test func finalTargetRebuildPolicyDefaultAllowsSeveralCommittedScrubsBeforeEscalating() {
    var policy = FinalTargetRebuildPolicy()

    for i in 0..<5 {
        #expect(policy.beginRebuild(offsetMs: 100_000 * (i + 1), now: TimeInterval(i * 6)) ==
            .start(generation: i + 1, offsetMs: 100_000 * (i + 1)))
        policy.finishRebuild(generation: i + 1)
    }

    #expect(policy.beginRebuild(offsetMs: 600_000, now: 35) == .escalate(recentCount: 5))
}

@Test func finalTargetRebuildPolicyEscalatesInsteadOfAllowingRestartStorm() {
    var policy = FinalTargetRebuildPolicy(budget: SeekRestartBudget(cooldownSeconds: 0,
                                                                    burstLimit: 2,
                                                                    burstWindowSeconds: 60))

    #expect(policy.beginRebuild(offsetMs: 100_000, now: 0) == .start(generation: 1, offsetMs: 100_000))
    policy.finishRebuild(generation: 1)
    #expect(policy.beginRebuild(offsetMs: 200_000, now: 10) == .start(generation: 2, offsetMs: 200_000))
    policy.finishRebuild(generation: 2)

    #expect(policy.beginRebuild(offsetMs: 300_000, now: 20) == .escalate(recentCount: 2))
}

@Test func finalTargetRebuildPolicyIgnoresStaleFinishes() {
    var policy = FinalTargetRebuildPolicy()

    #expect(policy.beginRebuild(offsetMs: 100_000, now: 0) == .start(generation: 1, offsetMs: 100_000))
    policy.cancelRebuild(generation: 1)
    policy.finishRebuild(generation: 1)

    #expect(policy.beginRebuild(offsetMs: 200_000, now: 10) == .start(generation: 2, offsetMs: 200_000))
}
