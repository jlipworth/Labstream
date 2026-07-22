#if !os(tvOS)
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct SeasonPlanDraftTests {
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
