import Testing
@testable import PMSKit

@Test func timelineSendCoalescerKeepsNewestQueuedHeartbeat() {
    var queue = TimelineSendCoalescer<String>()

    queue.enqueue("playing-10", kind: .timeline(.playing))
    queue.enqueue("paused-11", kind: .timeline(.paused))
    queue.enqueue("playing-12", kind: .timeline(.playing))

    #expect(queue.count == 1)
    let next = queue.popFirst()
    #expect(next?.event == "playing-12")
    #expect(next?.kind == .timeline(.playing))
    #expect(queue.isEmpty)
}

@Test func timelineSendCoalescerTreatsScrobbleAsOrderingBarrier() {
    var queue = TimelineSendCoalescer<String>()

    queue.enqueue("playing-before", kind: .timeline(.playing))
    queue.enqueue("scrobble", kind: .scrobble)
    queue.enqueue("paused-after", kind: .timeline(.paused))
    queue.enqueue("playing-after", kind: .timeline(.playing))

    #expect(queue.popFirst()?.event == "playing-before")
    #expect(queue.popFirst()?.event == "scrobble")
    let latestAfterBarrier = queue.popFirst()
    #expect(latestAfterBarrier?.event == "playing-after")
    #expect(latestAfterBarrier?.kind == .timeline(.playing))
    #expect(queue.isEmpty)
}

@Test func timelineSendCoalescerMakesStoppedFinalButStillAllowsScrobble() {
    var queue = TimelineSendCoalescer<String>()

    queue.enqueue("playing", kind: .timeline(.playing))
    queue.enqueue("paused", kind: .timeline(.paused))
    let acceptedStopped = queue.enqueue("stopped", kind: .timeline(.stopped))
    let acceptedLatePlaying = queue.enqueue("late-playing", kind: .timeline(.playing))
    let acceptedDuplicateStopped = queue.enqueue("duplicate-stopped", kind: .timeline(.stopped))
    let acceptedScrobble = queue.enqueue("scrobble-after-stop", kind: .scrobble)
    #expect(acceptedStopped)
    #expect(!acceptedLatePlaying)
    #expect(!acceptedDuplicateStopped)
    #expect(acceptedScrobble)

    let stopped = queue.popFirst()
    #expect(stopped?.event == "stopped")
    #expect(stopped?.kind == .timeline(.stopped))
    let scrobble = queue.popFirst()
    #expect(scrobble?.event == "scrobble-after-stop")
    #expect(scrobble?.kind == .scrobble)
    #expect(queue.isEmpty)
}
