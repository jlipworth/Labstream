import Testing
@testable import PMSKit

struct DownloadInFlightAttemptTrackerTests {
    @Test func staleReleaseCannotClearReplacementOwner() {
        var tracker = DownloadInFlightAttemptTracker()
        let a = key("item", "A")
        let b = key("item", "B")
        tracker.acquire(a)
        tracker.acquire(b)

        let staleReleased = tracker.release(ifOwnedBy: a)
        #expect(!staleReleased)
        #expect(tracker.owner(forRatingKey: "item") == b)
        let currentReleased = tracker.release(ifOwnedBy: b)
        #expect(currentReleased)
        #expect(tracker.owner(forRatingKey: "item") == nil)
    }

    private func key(_ ratingKey: String, _ id: String) -> DownloadAttemptKey {
        DownloadAttemptKey(ratingKey: ratingKey, attemptID: DownloadAttemptID(rawValue: id)!)
    }
}
