import Foundation
import Testing
@testable import PMSKit

@Suite("Plex optimize completion policy")
struct PlexOptimizeCompletionPolicyTests {
    @Test("Completed successful queue items are distinct from active and failed work")
    func outcomes() {
        #expect(PlexOptimizeCompletionPolicy.outcome(
            state: "running", successfulCount: 0, failedCount: 0) == .active)
        #expect(PlexOptimizeCompletionPolicy.outcome(
            state: "complete", successfulCount: 1, failedCount: 0) == .succeeded)
        #expect(PlexOptimizeCompletionPolicy.outcome(
            state: "Completed", successfulCount: nil, failedCount: nil) == .succeeded)
        #expect(PlexOptimizeCompletionPolicy.outcome(
            state: "complete", successfulCount: 0, failedCount: 1) == .failed)
    }

    @Test("B42: every state the queue cleanup preserves as completed also completes the poll")
    func sharedCompletedVocabulary() {
        // The cleanup/cancel paths preserve "done" items as completed; the poll must agree, or a
        // "done" job never arms the missing-output grace and waits for the 24 h deadline.
        #expect(PlexOptimizeCompletionPolicy.outcome(
            state: "done", successfulCount: 1, failedCount: 0) == .succeeded)
        for state in BackgroundProcessingItems.completedStates {
            #expect(PlexOptimizeCompletionPolicy.outcome(
                state: state.uppercased(), successfulCount: nil, failedCount: nil) == .succeeded)
            let items = BackgroundProcessingItems(items: [.init(id: "1", title: "t", state: state)])
            #expect(items.cancellableItemID(queueTitle: "t") == nil)
        }
        #expect(BackgroundProcessingItems.completedStates
            == PlexOptimizeCompletionPolicy.completedStates)
    }

    @Test("A successful job gets a bounded metadata indexing grace period")
    func indexingGrace() {
        let observed: TimeInterval = 1_000
        #expect(PlexOptimizeCompletionPolicy.missingPartAction(
            outcome: .succeeded,
            firstSuccessObservedAt: observed,
            now: observed + PlexOptimizeCompletionPolicy.metadataIndexingGraceSeconds - 1,
            metadataInspected: true
        ) == .keepPolling)
        #expect(PlexOptimizeCompletionPolicy.missingPartAction(
            outcome: .succeeded,
            firstSuccessObservedAt: observed,
            now: observed + PlexOptimizeCompletionPolicy.metadataIndexingGraceSeconds,
            metadataInspected: true
        ) == .failMissingOutput)
    }

    @Test("The deadline cannot fire on an iteration whose metadata fetch failed")
    func metadataFetchFailureKeepsPolling() {
        let observed: TimeInterval = 1_000
        #expect(PlexOptimizeCompletionPolicy.missingPartAction(
            outcome: .succeeded,
            firstSuccessObservedAt: observed,
            now: observed + PlexOptimizeCompletionPolicy.metadataIndexingGraceSeconds * 10,
            metadataInspected: false
        ) == .keepPolling)
    }

    @Test("Active and failed states do not use the successful indexing deadline")
    func nonSuccessStates() {
        for outcome in [PlexOptimizeCompletionPolicy.Outcome.active, .failed] {
            #expect(PlexOptimizeCompletionPolicy.missingPartAction(
                outcome: outcome, firstSuccessObservedAt: 0, now: 10_000,
                metadataInspected: true) == .keepPolling)
        }
    }
}
