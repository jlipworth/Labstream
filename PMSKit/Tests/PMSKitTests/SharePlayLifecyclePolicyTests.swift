import Foundation
import Testing
@testable import PMSKit

@Suite("SharePlay leave decision")
struct SharePlayLeaveDecisionTests {
    @Test("A dismissal for a different item is ignored")
    func nonMatchingItemIsIgnored() {
        #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: false,
                                                dismissingPlayerLaunchEpoch: 1,
                                                currentLaunchEpoch: 1) == .ignore)
        #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: false,
                                                dismissingPlayerLaunchEpoch: 0,
                                                currentLaunchEpoch: 1) == .ignore)
    }

    @Test("Closing the current launch's own player is a genuine leave")
    func currentEpochDismissalLeaves() {
        #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: true,
                                                dismissingPlayerLaunchEpoch: 1,
                                                currentLaunchEpoch: 1) == .leave)
    }

    @Test("Scenario A: with no superseded player, a genuine close before first attach still leaves")
    func replacementCloseBeforeAttachLeaves() {
        // The one-shot flag mechanism swallowed this close (armed unconditionally at launch,
        // cleared only on attach), stranding a ghost participant while the first item minted.
        // The replacement player carries the current epoch from creation, so its close always
        // leaves, attached or not.
        let epochAfterLaunch: UInt64 = 1
        #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: true,
                                                dismissingPlayerLaunchEpoch: epochAfterLaunch,
                                                currentLaunchEpoch: epochAfterLaunch) == .leave)
    }

    @Test("The superseded pre-launch player's dismissal is suppressed, not left")
    func supersededDismissalIsSuppressed() {
        #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: true,
                                                dismissingPlayerLaunchEpoch: 0,
                                                currentLaunchEpoch: 1) == .suppressSupersededDismissal)
    }

    @Test("Suppression is not one-shot: the stale dismissal stays suppressed regardless of ordering")
    func staleEpochStaysSuppressed() {
        // Whether or not the replacement attached first (which used to clear the pending flag),
        // the superseded player's epoch keeps comparing unequal.
        for _ in 0..<2 {
            #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: true,
                                                    dismissingPlayerLaunchEpoch: 3,
                                                    currentLaunchEpoch: 5) == .suppressSupersededDismissal)
        }
    }

    @Test("A surface that never captured an epoch is treated as a genuine close")
    func nilEpochLeaves() {
        #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: true,
                                                dismissingPlayerLaunchEpoch: nil,
                                                currentLaunchEpoch: 4) == .leave)
    }
}

@Suite("SharePlay attachment policy")
struct SharePlayAttachmentPolicyTests {
    @Test("Only the current launch epoch's player may attach")
    func currentEpochAttaches() {
        #expect(SharePlayAttachmentPolicy.mayAttach(playerLaunchEpoch: 2, currentLaunchEpoch: 2))
    }

    @Test("Scenario B: the superseded pre-launch player cannot attach or race the replacement")
    func staleEpochCannotAttach() {
        // The old player shows the same resolved item, so item identity cannot reject it; its
        // 250ms maintenance poll would otherwise satisfy the attach the instant launch consent
        // flips, then take the fresh session down with its own dismissal.
        #expect(!SharePlayAttachmentPolicy.mayAttach(playerLaunchEpoch: 1, currentLaunchEpoch: 2))
    }

    @Test("An epoch-less surface never attaches")
    func nilEpochCannotAttach() {
        #expect(!SharePlayAttachmentPolicy.mayAttach(playerLaunchEpoch: nil, currentLaunchEpoch: 0))
    }
}

@Suite("SharePlay activation failure restoration")
struct SharePlayActivationFailurePolicyTests {
    @Test("A cancelled activation restores the failure state when no session arrived meanwhile")
    func unchangedGenerationRestores() {
        // Includes the stuck-`.resolving` case: a session that PREDATES the activation attempt
        // leaves the generation unchanged across the awaits and must not block restoration.
        #expect(SharePlayActivationFailurePolicy.shouldRestoreFailureState(
            sessionGenerationAtRequest: 7, currentSessionGeneration: 7))
    }

    @Test("A session installed during activation owns state; the failure must not stamp over it")
    func advancedGenerationSkipsRestoration() {
        #expect(!SharePlayActivationFailurePolicy.shouldRestoreFailureState(
            sessionGenerationAtRequest: 7, currentSessionGeneration: 8))
    }
}

@Suite("SharePlay started re-broadcast selection")
struct SharePlayStartedBroadcastTests {
    private let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let mid = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let high = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test("Only the lowest-id started participant re-broadcasts")
    func lowestIdRebroadcasts() {
        let started: Set<UUID> = [low, mid, high]
        #expect(SharePlayStartedBroadcast.shouldRebroadcast(localID: low, startedParticipantIDs: started))
        #expect(!SharePlayStartedBroadcast.shouldRebroadcast(localID: mid, startedParticipantIDs: started))
        #expect(!SharePlayStartedBroadcast.shouldRebroadcast(localID: high, startedParticipantIDs: started))
    }

    @Test("A participant that has not started never re-broadcasts")
    func nonStartedNeverRebroadcasts() {
        #expect(!SharePlayStartedBroadcast.shouldRebroadcast(localID: low, startedParticipantIDs: [mid, high]))
    }

    @Test("A lone started participant re-broadcasts (the initiator may have left)")
    func loneStartedParticipantRebroadcasts() {
        #expect(SharePlayStartedBroadcast.shouldRebroadcast(localID: high, startedParticipantIDs: [high]))
    }
}
