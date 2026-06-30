import Testing
@testable import PMSKit

@Suite("Download retry state tracker")
struct DownloadRetryStateTrackerTests {

    @Test("Begin marks async guard presentation and handoff together")
    func beginMarksAllRetryState() {
        var tracker = DownloadRetryStateTracker()
        tracker.begin("row")
        #expect(tracker.isRetrying("row"))
        #expect(tracker.isPresentingRetry("row"))
        #expect(tracker.isRetryHandoff("row"))
        #expect(tracker.retryingKeys == ["row"])
        #expect(tracker.handoffKeys == ["row"])
        #expect(tracker.retryingCount == 1)
        #expect(tracker.handoffCount == 1)
    }

    @Test("Clearing handoff preserves the async retry guard")
    func clearHandoffPreservesRetrying() {
        var tracker = DownloadRetryStateTracker()
        tracker.begin("row")
        tracker.clearHandoff("row")
        #expect(tracker.isRetrying("row"))
        #expect(!tracker.isPresentingRetry("row"))
        #expect(!tracker.isRetryHandoff("row"))
    }

    @Test("Replacement seeded clears retry presentation and guard")
    func replacementSeededClearsAll() {
        var tracker = DownloadRetryStateTracker()
        tracker.begin("row")
        tracker.markReplacementSeeded("row")
        #expect(!tracker.isRetrying("row"))
        #expect(!tracker.isPresentingRetry("row"))
        #expect(!tracker.isRetryHandoff("row"))
    }

    @Test("Removing retrying only leaves presentation handoff for refresh cleanup")
    func removeRetryingOnly() {
        var tracker = DownloadRetryStateTracker()
        tracker.begin("row")
        tracker.removeRetrying("row")
        #expect(!tracker.isRetrying("row"))
        #expect(tracker.isPresentingRetry("row"))
        #expect(tracker.isRetryHandoff("row"))
    }

    @Test("Remove all clears every marker")
    func removeAll() {
        var tracker = DownloadRetryStateTracker()
        tracker.begin("row")
        tracker.removeAll("row")
        #expect(!tracker.isRetrying("row"))
        #expect(!tracker.isPresentingRetry("row"))
        #expect(!tracker.isRetryHandoff("row"))
    }
}
