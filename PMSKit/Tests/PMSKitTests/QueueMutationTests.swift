import Testing
import Foundation
@testable import PMSKit

/// Pure-bookkeeping tests for the queue mutation helpers (MUSIC-DESIGN §4.3 —
/// the judge-mandated gate before `MusicPlayerController` wiring). The model
/// under test: `queue` = display order, `playOrder` = traversal (indices into
/// `queue`), `currentIndex` = playing track's queue index.

private typealias S = QueueMutation.State<String>

// MARK: - playNext

@Test func playNextInsertsAfterCurrentInBothOrders() {
    // Unshuffled: identity traversal, playing B.
    let s = S(queue: ["A", "B", "C"], playOrder: [0, 1, 2], currentIndex: 1)
    let out = QueueMutation.playNext(["X", "Y"], in: s)
    #expect(out.queue == ["A", "B", "X", "Y", "C"])
    #expect(out.currentIndex == 1)
    #expect(out.playOrder == [0, 1, 2, 3, 4])
}

@Test func playNextUnderShuffleFollowsTraversalNotDisplay() {
    // Shuffled traversal [2,0,3,1], playing A (queue index 0, traversal pos 1).
    let s = S(queue: ["A", "B", "C", "D"], playOrder: [2, 0, 3, 1], currentIndex: 0)
    let out = QueueMutation.playNext(["X"], in: s)
    // X lands at queue index 1 (right after A in display order)…
    #expect(out.queue == ["A", "X", "B", "C", "D"])
    #expect(out.currentIndex == 0)
    // …and right after A in the traversal; old entries ≥1 shifted up by one.
    #expect(out.playOrder == [3, 0, 1, 4, 2])
}

@Test func playNextWithNothingCurrentLeadsTheQueue() {
    let s = S(queue: ["A", "B"], playOrder: [0, 1], currentIndex: nil)
    let out = QueueMutation.playNext(["X"], in: s)
    #expect(out.queue == ["X", "A", "B"])
    #expect(out.playOrder == [0, 1, 2])
    #expect(out.currentIndex == nil)
}

@Test func playNextIntoEmptyState() {
    let out = QueueMutation.playNext(["X", "Y"], in: S(queue: [], playOrder: [], currentIndex: nil))
    #expect(out.queue == ["X", "Y"])
    #expect(out.playOrder == [0, 1])
    #expect(out.currentIndex == nil)
}

@Test func playNextWithNoItemsIsIdentity() {
    let s = S(queue: ["A"], playOrder: [0], currentIndex: 0)
    #expect(QueueMutation.playNext([], in: s) == s)
}

@Test func playNextAtQueueTail() {
    // Playing the LAST track: insertion lands at the queue end.
    let s = S(queue: ["A", "B"], playOrder: [0, 1], currentIndex: 1)
    let out = QueueMutation.playNext(["X"], in: s)
    #expect(out.queue == ["A", "B", "X"])
    #expect(out.playOrder == [0, 1, 2])
    #expect(out.currentIndex == 1)
}

// MARK: - addToQueue

@Test func addToQueueAppendsToBothTails() {
    let s = S(queue: ["A", "B"], playOrder: [1, 0], currentIndex: 1)
    let out = QueueMutation.addToQueue(["X", "Y"], in: s)
    #expect(out.queue == ["A", "B", "X", "Y"])
    // Appended to the TRAVERSAL tail too — even under shuffle, deliberately.
    #expect(out.playOrder == [1, 0, 2, 3])
    #expect(out.currentIndex == 1)
}

@Test func addToQueueWithNoItemsIsIdentity() {
    let s = S(queue: ["A"], playOrder: [0], currentIndex: 0)
    #expect(QueueMutation.addToQueue([], in: s) == s)
}

// MARK: - remove

@Test func removeBeforeCurrentShiftsCurrentDown() {
    let s = S(queue: ["A", "B", "C"], playOrder: [0, 1, 2], currentIndex: 2)
    let (out, effect) = QueueMutation.remove(at: 0, from: s)
    #expect(effect == .none)
    #expect(out.queue == ["B", "C"])
    #expect(out.currentIndex == 1)
    #expect(out.playOrder == [0, 1])
}

@Test func removeAfterCurrentLeavesCurrentAlone() {
    let s = S(queue: ["A", "B", "C"], playOrder: [0, 1, 2], currentIndex: 0)
    let (out, effect) = QueueMutation.remove(at: 2, from: s)
    #expect(effect == .none)
    #expect(out.queue == ["A", "B"])
    #expect(out.currentIndex == 0)
    #expect(out.playOrder == [0, 1])
}

@Test func removeCurrentAdvancesToTraversalSuccessor() {
    let s = S(queue: ["A", "B", "C"], playOrder: [0, 1, 2], currentIndex: 1)
    let (out, effect) = QueueMutation.remove(at: 1, from: s)
    // C was queue index 2; after the removal it's index 1.
    #expect(effect == .playTrack(queueIndex: 1))
    #expect(out.queue == ["A", "C"])
    #expect(out.currentIndex == 1)
    #expect(out.playOrder == [0, 1])
}

@Test func removeCurrentUnderShuffleFollowsTraversal() {
    // Traversal says D follows B, even though display order says C does.
    let s = S(queue: ["A", "B", "C", "D"], playOrder: [1, 3, 0, 2], currentIndex: 1)
    let (out, effect) = QueueMutation.remove(at: 1, from: s)
    // D was queue index 3 → 2 after the removal.
    #expect(effect == .playTrack(queueIndex: 2))
    #expect(out.queue == ["A", "C", "D"])
    #expect(out.currentIndex == 2)
    #expect(out.playOrder == [2, 0, 1])
}

@Test func removeCurrentAtTraversalEndStops() {
    // B is LAST in the traversal even though C follows it in display order.
    let s = S(queue: ["A", "B", "C"], playOrder: [2, 0, 1], currentIndex: 1)
    let (out, effect) = QueueMutation.remove(at: 1, from: s)
    #expect(effect == .stopPlayback)
    #expect(out.queue == ["A", "C"])
    #expect(out.currentIndex == nil)
    #expect(out.playOrder == [1, 0])
}

@Test func removeOnlyTrackStopsAndEmpties() {
    let s = S(queue: ["A"], playOrder: [0], currentIndex: 0)
    let (out, effect) = QueueMutation.remove(at: 0, from: s)
    #expect(effect == .stopPlayback)
    #expect(out.queue.isEmpty)
    #expect(out.playOrder.isEmpty)
    #expect(out.currentIndex == nil)
}

@Test func removeOutOfRangeIsIdentity() {
    let s = S(queue: ["A"], playOrder: [0], currentIndex: 0)
    let (out, effect) = QueueMutation.remove(at: 5, from: s)
    #expect(effect == .none)
    #expect(out == s)
}

@Test func removeWithNothingPlayingJustDrops() {
    let s = S(queue: ["A", "B"], playOrder: [0, 1], currentIndex: nil)
    let (out, effect) = QueueMutation.remove(at: 0, from: s)
    #expect(effect == .none)
    #expect(out.queue == ["B"])
    #expect(out.currentIndex == nil)
    #expect(out.playOrder == [0])
}

// MARK: - move

@Test func moveDownRemapsCurrentAndRebuildsIdentity() {
    // onMove semantics: moving row 0 below row 1 → toOffset 2.
    let s = S(queue: ["A", "B", "C"], playOrder: [0, 1, 2], currentIndex: 0)
    let out = QueueMutation.move(fromOffsets: IndexSet(integer: 0), toOffset: 2, in: s)
    #expect(out.queue == ["B", "A", "C"])
    #expect(out.currentIndex == 1)
    #expect(out.playOrder == [0, 1, 2])
}

@Test func moveUpLeavesUnrelatedCurrentTracked() {
    // Move C above B while A plays.
    let s = S(queue: ["A", "B", "C"], playOrder: [0, 1, 2], currentIndex: 0)
    let out = QueueMutation.move(fromOffsets: IndexSet(integer: 2), toOffset: 1, in: s)
    #expect(out.queue == ["A", "C", "B"])
    #expect(out.currentIndex == 0)
    #expect(out.playOrder == [0, 1, 2])
}

@Test func moveWithNothingPlayingKeepsNilCurrent() {
    let s = S(queue: ["A", "B"], playOrder: [0, 1], currentIndex: nil)
    let out = QueueMutation.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, in: s)
    #expect(out.queue == ["B", "A"])
    #expect(out.currentIndex == nil)
}

// MARK: - clearUpcoming

@Test func clearUpcomingKeepsOnlyCurrent() {
    let s = S(queue: ["A", "B", "C"], playOrder: [2, 1, 0], currentIndex: 1)
    let out = QueueMutation.clearUpcoming(in: s)
    #expect(out.queue == ["B"])
    #expect(out.playOrder == [0])
    #expect(out.currentIndex == 0)
}

@Test func clearUpcomingWithNothingPlayingEmpties() {
    let s = S(queue: ["A", "B"], playOrder: [0, 1], currentIndex: nil)
    let out = QueueMutation.clearUpcoming(in: s)
    #expect(out.queue.isEmpty)
    #expect(out.playOrder.isEmpty)
    #expect(out.currentIndex == nil)
}
