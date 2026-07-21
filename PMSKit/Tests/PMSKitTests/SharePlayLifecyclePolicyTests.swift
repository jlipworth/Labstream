import Foundation
import Testing
@testable import PMSKit

private actor SharePlayMessageTestRecorder {
    private var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
    func snapshot() -> [Int] { values }
}

private actor SharePlayMessageTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

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

@Suite("SharePlay message session fencing")
struct SharePlayMessageSessionPolicyTests {
    @Test("Buffered receive work from a replacement session is rejected")
    func replacementSessionRejectsBufferedReceive() {
        #expect(!SharePlayMessageSessionPolicy.accepts(
            capturedSessionGeneration: 4,
            currentSessionGeneration: 5))
    }

    @Test("Queued send work may publish only while its exact session generation is current")
    func queuedSendRequiresCurrentSession() {
        #expect(SharePlayMessageSessionPolicy.accepts(
            capturedSessionGeneration: 9,
            currentSessionGeneration: 9))
        #expect(!SharePlayMessageSessionPolicy.accepts(
            capturedSessionGeneration: 9,
            currentSessionGeneration: 10))
    }
}

@Suite("SharePlay message revisions")
struct SharePlayMessageRevisionTests {
    @Test("Outbound revisions preserve enqueue order")
    func outboundRevisionsAreOrdered() {
        var revisions = SharePlayOutboundMessageRevisions()

        #expect(revisions.issue() == 1)
        #expect(revisions.issue() == 2)
        #expect(revisions.issue() == 3)
    }

    @Test("A replacement session starts an independent revision sequence")
    func replacementSessionResetsRevisions() {
        var replacedSession = SharePlayOutboundMessageRevisions()
        _ = replacedSession.issue()
        _ = replacedSession.issue()

        var replacementSession = SharePlayOutboundMessageRevisions()
        #expect(replacementSession.issue() == 1)
    }

    @Test("Duplicate and stale inbound revisions are rejected")
    func staleInboundRevisionIsRejected() {
        #expect(SharePlayInboundMessageRevisionPolicy.accepts(
            incomingRevision: 8,
            lastAcceptedRevision: 7))
        #expect(!SharePlayInboundMessageRevisionPolicy.accepts(
            incomingRevision: 7,
            lastAcceptedRevision: 7))
        #expect(!SharePlayInboundMessageRevisionPolicy.accepts(
            incomingRevision: 6,
            lastAcceptedRevision: 7))
    }

    @Test("An older participant remains compatible until revisioned delivery establishes a fence")
    func legacyMessageDoesNotAdvanceFence() {
        #expect(SharePlayInboundMessageRevisionPolicy.accepts(
            incomingRevision: nil,
            lastAcceptedRevision: nil))
        #expect(!SharePlayInboundMessageRevisionPolicy.accepts(
            incomingRevision: nil,
            lastAcceptedRevision: 7))
        #expect(SharePlayInboundMessageRevisionPolicy.accepts(
            incomingRevision: 8,
            lastAcceptedRevision: 7))
    }
}

@Suite("SharePlay ordered delivery tail")
struct SharePlayOrderedDeliveryTailTests {
    @Test("A suspended send prevents its queued successor from overtaking it")
    @MainActor
    func sendOrderIsSerialized() async {
        let tail = SharePlayOrderedDeliveryTail()
        let recorder = SharePlayMessageTestRecorder()
        let gate = SharePlayMessageTestGate()

        tail.enqueue {
            await recorder.append(1)
            await gate.wait()
            await recorder.append(2)
        }
        tail.enqueue { await recorder.append(3) }

        var started = false
        for _ in 0..<100 where !started {
            started = await recorder.snapshot() == [1]
            if !started { await Task.yield() }
        }
        #expect(started)
        let whileSuspended = await recorder.snapshot()
        #expect(whileSuspended == [1])

        await gate.open()
        await tail.drain()
        let delivered = await recorder.snapshot()
        #expect(delivered == [1, 2, 3])
    }

    @Test("Cancellation reaches an in-flight predecessor and every queued successor")
    @MainActor
    func cancellationCoversWholeChain() async {
        let tail = SharePlayOrderedDeliveryTail()
        let recorder = SharePlayMessageTestRecorder()
        let gate = SharePlayMessageTestGate()

        tail.enqueue {
            await recorder.append(1)
            await gate.wait()
            guard !Task.isCancelled else { return }
            await recorder.append(2)
        }
        tail.enqueue { await recorder.append(3) }

        var started = false
        for _ in 0..<100 where !started {
            started = await recorder.snapshot() == [1]
            if !started { await Task.yield() }
        }
        #expect(started)

        let cancellation = Task { @MainActor in await tail.cancelAllAndDrain() }
        await Task.yield()
        await gate.open()
        await cancellation.value

        let delivered = await recorder.snapshot()
        #expect(delivered == [1])
    }
}

@Suite("SharePlay participant message fencing")
struct SharePlayParticipantMessagePolicyTests {
    private let participantID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    @Test("A legitimate initial status waits for the first authoritative roster")
    func preRosterMessageIsBuffered() {
        #expect(SharePlayParticipantMessagePolicy.disposition(
            sourceParticipantID: participantID,
            hasObservedRoster: false,
            activeParticipantIDs: []) == .bufferUntilRosterUpdate)
    }

    @Test("Unknown sources wait for the next roster while known sources apply immediately")
    func unknownSourceIsBuffered() {
        #expect(SharePlayParticipantMessagePolicy.disposition(
            sourceParticipantID: participantID,
            hasObservedRoster: true,
            activeParticipantIDs: []) == .bufferUntilRosterUpdate)
        #expect(SharePlayParticipantMessagePolicy.disposition(
            sourceParticipantID: participantID,
            hasObservedRoster: true,
            activeParticipantIDs: [participantID]) == .accept)
    }

    @Test("An absent roster does not discard a message before the source-present roster arrives")
    func bufferedMessageSurvivesInterveningRoster() {
        let buffered: Set<UUID> = [participantID]
        #expect(SharePlayBufferedParticipantMessages.readySourceIDs(
            bufferedSourceIDs: buffered,
            activeParticipantIDs: []).isEmpty)
        #expect(SharePlayBufferedParticipantMessages.readySourceIDs(
            bufferedSourceIDs: buffered,
            activeParticipantIDs: [participantID]) == [participantID])
    }
}

@Suite("SharePlay bounded terminal fallback")
struct SharePlayBoundedFallbackTests {
    @Test("A never-resuming delivery cannot prevent the independent leave fallback")
    @MainActor
    func fallbackDoesNotWaitForDeliveryTail() async {
        let tail = SharePlayOrderedDeliveryTail()
        let gate = SharePlayMessageTestGate()
        let recorder = SharePlayMessageTestRecorder()
        let fallback = SharePlayBoundedFallback()

        tail.enqueue { await gate.wait() }
        fallback.schedule(after: .zero) { await recorder.append(1) }
        await fallback.drain()
        let values = await recorder.snapshot()
        #expect(values == [1])

        tail.cancelAll()
        await gate.open()
    }
}
