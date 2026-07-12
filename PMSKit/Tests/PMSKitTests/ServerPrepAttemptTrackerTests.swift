import Foundation
import Testing
@testable import PMSKit

@Suite("Server-prep attempt tracker")
struct ServerPrepAttemptTrackerTests {
    @Test("Plex queue titles stay protected until the record is released")
    func plexQueueTitleProtection() {
        var tracker = ServerPrepAttemptTracker()
        let attempt = key("plex:1", "attempt")
        tracker.protectQueueTitle("Movie [Labstream abc12345]", for: attempt)

        #expect(tracker.queueTitle(for: attempt) == "Movie [Labstream abc12345]")
        #expect(tracker.allProtectedQueueTitles == ["Movie [Labstream abc12345]"])
        #expect(tracker.releaseQueueTitle(for: attempt) == "Movie [Labstream abc12345]")
        #expect(tracker.queueTitle(for: attempt) == nil)
        #expect(tracker.allProtectedQueueTitles.isEmpty)
    }

    @Test("Plex poller attachment is single-owner and id-checked on detach")
    func plexPollerOwnership() throws {
        var tracker = ServerPrepAttemptTracker()
        let attempt = key("plex:1", "attempt")
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        #expect(tracker.beginPlexPoller(for: attempt, id: first) == first)
        #expect(tracker.hasPlexPoller(for: attempt))
        #expect(tracker.beginPlexPoller(for: attempt, id: second) == nil)
        let wrongDetach = tracker.endPlexPoller(for: attempt, id: second)
        #expect(!wrongDetach)
        let rightDetach = tracker.endPlexPoller(for: attempt, id: first)
        #expect(rightDetach)
        #expect(!tracker.hasPlexPoller(for: attempt))
    }

    @Test("Poller currency survives only until pause/delete release or a newer attempt attaches")
    func plexPollerCurrencyAfterReleaseAndReattach() {
        var tracker = ServerPrepAttemptTracker()
        let attempt = key("plex:1", "attempt")
        let old = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let new = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!

        tracker.beginPlexPoller(for: attempt, id: old)
        #expect(tracker.isCurrentPlexPoller(for: attempt, id: old))

        // Pause/delete tear the attempt down via releaseAll: the cancelled poller's terminal
        // handler must observe it is no longer current and skip releasing anything.
        _ = tracker.releaseAll(for: attempt)
        #expect(!tracker.isCurrentPlexPoller(for: attempt, id: old))

        // A quick resume attaches a NEW poller on the same key (same queue title). The
        // superseded poller must still read stale; the new one is current.
        tracker.beginPlexPoller(for: attempt, id: new)
        #expect(!tracker.isCurrentPlexPoller(for: attempt, id: old))
        #expect(tracker.isCurrentPlexPoller(for: attempt, id: new))
    }

    @Test("Emby convert attempt UUIDs replace older async work")
    func embyAttemptReplacement() {
        var tracker = ServerPrepAttemptTracker()
        let attempt = key("emby:1", "attempt")
        let old = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let new = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

        tracker.beginEmbyConvertAttempt(for: attempt, id: old)
        #expect(tracker.isCurrentEmbyConvertAttempt(for: attempt, id: old))
        tracker.beginEmbyConvertAttempt(for: attempt, id: new)
        #expect(!tracker.isCurrentEmbyConvertAttempt(for: attempt, id: old))
        #expect(tracker.isCurrentEmbyConvertAttempt(for: attempt, id: new))
    }

    @Test("Releasing a record clears all server-prep identities atomically")
    func releaseAll() {
        var tracker = ServerPrepAttemptTracker()
        let attempt = key("item", "attempt")
        let poller = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let emby = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        tracker.protectQueueTitle("T [Labstream 12345678]", for: attempt)
        tracker.beginPlexPoller(for: attempt, id: poller)
        tracker.beginEmbyConvertAttempt(for: attempt, id: emby)

        let released = tracker.releaseAll(for: attempt)
        #expect(released.releasedQueueTitle == "T [Labstream 12345678]")
        #expect(released.clearedPlexPoller)
        #expect(released.clearedEmbyConvertAttempt)
        #expect(released.didReleaseAnything)
        #expect(tracker.allProtectedQueueTitles.isEmpty)
        #expect(!tracker.hasPlexPoller(for: attempt))
        #expect(!tracker.isCurrentEmbyConvertAttempt(for: attempt, id: emby))
    }

    @Test("Releasing attempt A preserves replacement attempt B resources")
    func exactAttemptReleaseIsolation() {
        var tracker = ServerPrepAttemptTracker()
        let attemptA = key("plex:1", "attempt-A")
        let attemptB = key("plex:1", "attempt-B")
        let pollerA = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let pollerB = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        tracker.protectQueueTitle("A [Labstream 11111111]", for: attemptA)
        tracker.protectQueueTitle("B [Labstream 22222222]", for: attemptB)
        tracker.beginPlexPoller(for: attemptA, id: pollerA)
        tracker.beginPlexPoller(for: attemptB, id: pollerB)

        _ = tracker.releaseAll(for: attemptA)

        #expect(!tracker.isCurrentPlexPoller(for: attemptA, id: pollerA))
        #expect(tracker.isCurrentPlexPoller(for: attemptB, id: pollerB))
        #expect(tracker.queueTitle(for: attemptB) == "B [Labstream 22222222]")
        #expect(tracker.allProtectedQueueTitles == ["B [Labstream 22222222]"])
    }

    private func key(_ ratingKey: String, _ id: String) -> DownloadAttemptKey {
        DownloadAttemptKey(ratingKey: ratingKey, attemptID: DownloadAttemptID(rawValue: id)!)
    }
}
