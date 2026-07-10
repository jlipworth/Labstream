import Foundation
import Testing
@testable import PMSKit

@Suite("Server-prep attempt tracker")
struct ServerPrepAttemptTrackerTests {
    @Test("Plex queue titles stay protected until the record is released")
    func plexQueueTitleProtection() {
        var tracker = ServerPrepAttemptTracker()
        tracker.protectQueueTitle("Movie [Labstream abc12345]", forRecordKey: "plex:1")

        #expect(tracker.queueTitle(forRecordKey: "plex:1") == "Movie [Labstream abc12345]")
        #expect(tracker.allProtectedQueueTitles == ["Movie [Labstream abc12345]"])
        #expect(tracker.releaseQueueTitle(forRecordKey: "plex:1") == "Movie [Labstream abc12345]")
        #expect(tracker.queueTitle(forRecordKey: "plex:1") == nil)
        #expect(tracker.allProtectedQueueTitles.isEmpty)
    }

    @Test("Plex poller attachment is single-owner and id-checked on detach")
    func plexPollerOwnership() throws {
        var tracker = ServerPrepAttemptTracker()
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        #expect(tracker.beginPlexPoller(forRecordKey: "plex:1", id: first) == first)
        #expect(tracker.hasPlexPoller(forRecordKey: "plex:1"))
        #expect(tracker.beginPlexPoller(forRecordKey: "plex:1", id: second) == nil)
        let wrongDetach = tracker.endPlexPoller(forRecordKey: "plex:1", id: second)
        #expect(!wrongDetach)
        let rightDetach = tracker.endPlexPoller(forRecordKey: "plex:1", id: first)
        #expect(rightDetach)
        #expect(!tracker.hasPlexPoller(forRecordKey: "plex:1"))
    }

    @Test("Poller currency survives only until pause/delete release or a newer attempt attaches")
    func plexPollerCurrencyAfterReleaseAndReattach() {
        var tracker = ServerPrepAttemptTracker()
        let old = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let new = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!

        tracker.beginPlexPoller(forRecordKey: "plex:1", id: old)
        #expect(tracker.isCurrentPlexPoller(forRecordKey: "plex:1", id: old))

        // Pause/delete tear the attempt down via releaseAll: the cancelled poller's terminal
        // handler must observe it is no longer current and skip releasing anything.
        _ = tracker.releaseAll(forRecordKey: "plex:1")
        #expect(!tracker.isCurrentPlexPoller(forRecordKey: "plex:1", id: old))

        // A quick resume attaches a NEW poller on the same key (same queue title). The
        // superseded poller must still read stale; the new one is current.
        tracker.beginPlexPoller(forRecordKey: "plex:1", id: new)
        #expect(!tracker.isCurrentPlexPoller(forRecordKey: "plex:1", id: old))
        #expect(tracker.isCurrentPlexPoller(forRecordKey: "plex:1", id: new))
    }

    @Test("Emby convert attempt UUIDs replace older async work")
    func embyAttemptReplacement() {
        var tracker = ServerPrepAttemptTracker()
        let old = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let new = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

        tracker.beginEmbyConvertAttempt(forRecordKey: "emby:1", id: old)
        #expect(tracker.isCurrentEmbyConvertAttempt(forRecordKey: "emby:1", id: old))
        tracker.beginEmbyConvertAttempt(forRecordKey: "emby:1", id: new)
        #expect(!tracker.isCurrentEmbyConvertAttempt(forRecordKey: "emby:1", id: old))
        #expect(tracker.isCurrentEmbyConvertAttempt(forRecordKey: "emby:1", id: new))
    }

    @Test("Releasing a record clears all server-prep identities atomically")
    func releaseAll() {
        var tracker = ServerPrepAttemptTracker()
        let poller = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let emby = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        tracker.protectQueueTitle("T [Labstream 12345678]", forRecordKey: "item")
        tracker.beginPlexPoller(forRecordKey: "item", id: poller)
        tracker.beginEmbyConvertAttempt(forRecordKey: "item", id: emby)

        let released = tracker.releaseAll(forRecordKey: "item")
        #expect(released.releasedQueueTitle == "T [Labstream 12345678]")
        #expect(released.clearedPlexPoller)
        #expect(released.clearedEmbyConvertAttempt)
        #expect(released.didReleaseAnything)
        #expect(tracker.allProtectedQueueTitles.isEmpty)
        #expect(!tracker.hasPlexPoller(forRecordKey: "item"))
        #expect(!tracker.isCurrentEmbyConvertAttempt(forRecordKey: "item", id: emby))
    }
}
