import Foundation
import Testing
@testable import PMSKit

@Suite("SharePlay leave decision")
struct SharePlayLeaveDecisionTests {
    @Test("A dismissal for a different item is ignored")
    func nonMatchingItemIsIgnored() {
        #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: false,
                                                supersededDismissalPending: false) == .ignore)
        #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: false,
                                                supersededDismissalPending: true) == .ignore)
    }

    @Test("A matching dismissal leaves the session when nothing is being superseded")
    func matchingDismissalLeaves() {
        #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: true,
                                                supersededDismissalPending: false) == .leave)
    }

    @Test("The coordinator's own superseded-player dismissal is suppressed, not left")
    func supersededDismissalIsSuppressed() {
        #expect(SharePlayLeaveDecision.evaluate(resolvedMatchesItem: true,
                                                supersededDismissalPending: true) == .suppressSupersededDismissal)
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
