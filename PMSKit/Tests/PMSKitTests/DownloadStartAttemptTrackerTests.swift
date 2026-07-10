import Foundation
import Testing
@testable import PMSKit

@Suite("Download start-attempt tracker")
struct DownloadStartAttemptTrackerTests {

    @Test("Minted token is current until cleared or replaced")
    func tokenLifecycle() {
        var tracker = DownloadStartAttemptTracker()
        let first = tracker.begin("plex:1")
        #expect(tracker.isCurrent("plex:1", id: first))

        // Delete/pause path: releaseInFlight clears the token → the awaited chain is stale.
        let clearedLiveToken = tracker.clear("plex:1")
        #expect(clearedLiveToken)
        #expect(!tracker.isCurrent("plex:1", id: first))
        let clearedAgain = tracker.clear("plex:1")
        #expect(!clearedAgain)

        // Delete→re-download: a NEW start mints a new token; the old chain must stay stale even
        // though the key is active again.
        let second = tracker.begin("plex:1")
        #expect(!tracker.isCurrent("plex:1", id: first))
        #expect(tracker.isCurrent("plex:1", id: second))
    }

    @Test("Tokens are per-key")
    func perKeyIsolation() {
        var tracker = DownloadStartAttemptTracker()
        let a = tracker.begin("jf:a")
        let b = tracker.begin("emby:b")
        #expect(tracker.isCurrent("jf:a", id: a))
        #expect(tracker.isCurrent("emby:b", id: b))
        tracker.clear("jf:a")
        #expect(!tracker.isCurrent("jf:a", id: a))
        #expect(tracker.isCurrent("emby:b", id: b))
    }
}

@Suite("Download start guard policy")
struct DownloadStartGuardPolicyTests {

    @Test("Happy path proceeds")
    func proceeds() {
        // Fresh enqueue: no row existed at entry; still none (seed happens after the guard).
        #expect(DownloadStartGuardPolicy.verdict(tokenIsCurrent: true,
                                                 hasActiveSlot: true,
                                                 enteredWithExistingRow: false,
                                                 rowIsPresent: false,
                                                 rowStatus: nil) == .proceed)
        // Retry path: entered with a row that is still there in an active status.
        #expect(DownloadStartGuardPolicy.verdict(tokenIsCurrent: true,
                                                 hasActiveSlot: true,
                                                 enteredWithExistingRow: true,
                                                 rowIsPresent: true,
                                                 rowStatus: .queued) == .proceed)
    }

    @Test("Superseded token aborts even when the slot is re-held by a newer start")
    func supersededToken() {
        let verdict = DownloadStartGuardPolicy.verdict(tokenIsCurrent: false,
                                                       hasActiveSlot: true,
                                                       enteredWithExistingRow: true,
                                                       rowIsPresent: true,
                                                       rowStatus: .queued)
        #expect(verdict == .superseded(reason: .tokenSuperseded))
    }

    @Test("Released slot (delete/pause during the await) aborts")
    func slotReleased() {
        let verdict = DownloadStartGuardPolicy.verdict(tokenIsCurrent: true,
                                                       hasActiveSlot: false,
                                                       enteredWithExistingRow: false,
                                                       rowIsPresent: false,
                                                       rowStatus: nil)
        #expect(verdict == .superseded(reason: .slotReleased))
    }

    @Test("Row removed mid-await aborts only chains that entered with a row")
    func rowRemoved() {
        #expect(DownloadStartGuardPolicy.verdict(tokenIsCurrent: true,
                                                 hasActiveSlot: true,
                                                 enteredWithExistingRow: true,
                                                 rowIsPresent: false,
                                                 rowStatus: nil)
            == .superseded(reason: .rowRemoved))
        // A fresh enqueue with no row yet is the normal pre-seed state, not a removal.
        #expect(DownloadStartGuardPolicy.verdict(tokenIsCurrent: true,
                                                 hasActiveSlot: true,
                                                 enteredWithExistingRow: false,
                                                 rowIsPresent: false,
                                                 rowStatus: nil) == .proceed)
    }

    @Test("A row parked .paused during the await must not be clobbered back to active")
    func rowPaused() {
        // Queue-pause parking can set `.paused` WITHOUT releasing the in-flight slot, so this
        // reason must fire on its own.
        let verdict = DownloadStartGuardPolicy.verdict(tokenIsCurrent: true,
                                                       hasActiveSlot: true,
                                                       enteredWithExistingRow: true,
                                                       rowIsPresent: true,
                                                       rowStatus: .paused)
        #expect(verdict == .superseded(reason: .rowPaused))
    }
}
