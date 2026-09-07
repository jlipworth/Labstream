#if !os(tvOS)
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct SeasonPlanDraftTests {
    @Test func admissionRejectsDeletionReplacementAndPause() throws {
        let original = try #require(DownloadAttemptID(rawValue: "original"))
        let replacement = try #require(DownloadAttemptID(rawValue: "replacement"))
        #expect(SeasonPlanAdmissionAuthority.accepts(expected: original, current: original, status: .queued))
        #expect(!SeasonPlanAdmissionAuthority.accepts(expected: original, current: nil, status: nil))
        #expect(!SeasonPlanAdmissionAuthority.accepts(expected: original, current: replacement, status: .queued))
        #expect(!SeasonPlanAdmissionAuthority.accepts(expected: original, current: original, status: .paused))
        #expect(!SeasonPlanAdmissionAuthority.accepts(expected: nil, current: nil, status: .queued))
    }

    @Test func suspendedAdmissionRejectsDeletedRowAndSkipsDeletedBatchSuccessor() async {
        var exists = true
        var held: CheckedContinuation<Int, Never>?
        let first = Task { @MainActor in
            await SeasonPlanAdmissionAuthority.refresh(isCurrent: { exists }) {
                await withCheckedContinuation { held = $0 }
            }
        }
        while held == nil { await Task.yield() }
        exists = false // Completed deletion while metadata is held.
        held?.resume(returning: 1)
        #expect(await first.value == nil)
        var requestedSuccessor = false
        let next = await SeasonPlanAdmissionAuthority.refresh(isCurrent: { exists }) {
            requestedSuccessor = true
            return 2
        }
        #expect(next == nil)
        #expect(!requestedSuccessor)
        exists = true
        let unchanged = await SeasonPlanAdmissionAuthority.refresh(isCurrent: { exists }) { 3 }
        #expect(unchanged == 3)
    }

    @Test func draftRetainsExactRetryAttemptOwnership() throws {
        let attempt = DownloadAttemptKey(
            ratingKey: "emby:episode-1",
            attemptID: try #require(DownloadAttemptID(rawValue: "reviewed-attempt")))
        let draft = SeasonPlanDraft(newPlans: [], retryAttempts: [attempt])

        #expect(draft.retryAttempts == [attempt])
    }

    @Test func cancelledResolutionDoesNotPublishPartialOutputOrStartNextEpisode() async {
        var visited: [Int] = []
        let resolution = Task { @MainActor in
            await SeasonPlanResolutionSequence.map(
                indices: [0, 1, 2], elements: [10, 20, 30]) { value in
                    visited.append(value)
                    if value == 20 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return value * 2
                }
        }
        let result = await resolution.value

        #expect(result == nil)
        #expect(visited == [10, 20])
    }

    @Test func activeResolutionPublishesCompleteOrderedOutput() async {
        let result = await SeasonPlanResolutionSequence.map(
            indices: [2, 0], elements: [10, 20, 30]) { $0 * 2 }
        #expect(result == [60, 20])
    }
}
#endif
