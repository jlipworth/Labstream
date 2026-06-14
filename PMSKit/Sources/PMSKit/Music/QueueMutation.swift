import Foundation

/// Pure queue / playOrder / currentIndex index math behind
/// `MusicPlayerController`'s queue-mutation API (MUSIC-DESIGN §4.3).
///
/// The controller's model: `queue` holds tracks in DISPLAY order (what the
/// Up Next list shows); `playOrder` is the traversal — indices into `queue`
/// (identity when unshuffled; with shuffle on, the current track leads and the
/// rest are randomized); `currentIndex` is the playing track's queue index.
///
/// Everything here is value-in / value-out with no playback side effects, so the
/// bookkeeping is unit-testable without an AVPlayer (the judge-mandated gate
/// before controller wiring). Semantics are deliberately dead simple:
/// Play Next = immediately after current; Add to Queue = append at the tail.
public enum QueueMutation {

    /// Value snapshot of the controller's queue bookkeeping. Generic so tests
    /// can drive it with plain strings.
    public struct State<Element> {
        /// Tracks in display order.
        public var queue: [Element]
        /// Traversal order: indices into `queue`.
        public var playOrder: [Int]
        /// Queue index of the playing track; `nil` when nothing is loaded.
        public var currentIndex: Int?

        public init(queue: [Element], playOrder: [Int], currentIndex: Int?) {
            self.queue = queue
            self.playOrder = playOrder
            self.currentIndex = currentIndex
        }
    }

    /// What playback should do after `remove(at:from:)`.
    public enum RemovalEffect: Equatable, Sendable {
        /// The playing track is unaffected (its index may have shifted).
        case none
        /// The playing track was removed; start the track now at this queue
        /// index (the returned state's `currentIndex` already points at it).
        case playTrack(queueIndex: Int)
        /// The playing track was removed with nothing after it in the traversal
        /// (no wrap — mirrors the failure-advance rule), or the queue emptied:
        /// stop playback.
        case stopPlayback
    }

    // MARK: - Insert

    /// "Play Next": insert `items` immediately after the current track in BOTH
    /// display order and traversal order. With no current track they go to the
    /// front of the queue and the head of the traversal.
    public static func playNext<E>(_ items: [E], in state: State<E>) -> State<E> {
        guard !items.isEmpty else { return state }
        var s = state

        let insertAt = s.currentIndex.map { $0 + 1 } ?? 0
        s.queue.insert(contentsOf: items, at: insertAt)
        // Existing traversal entries at or past the insertion point shift up.
        s.playOrder = s.playOrder.map { $0 >= insertAt ? $0 + items.count : $0 }

        // New indices slot into the traversal right after the current track's
        // position (or lead it when nothing is current).
        let traversalPos: Int
        if let current = s.currentIndex, let pos = s.playOrder.firstIndex(of: current) {
            traversalPos = pos + 1
        } else {
            traversalPos = 0
        }
        s.playOrder.insert(contentsOf: insertAt ..< insertAt + items.count, at: traversalPos)
        return s
    }

    /// "Add to Queue": append `items` to the END of both display order and
    /// traversal order — even under shuffle, deliberately (no Plexamp
    /// "after the previously added block" subtlety).
    public static func addToQueue<E>(_ items: [E], in state: State<E>) -> State<E> {
        guard !items.isEmpty else { return state }
        var s = state
        let start = s.queue.count
        s.queue.append(contentsOf: items)
        s.playOrder.append(contentsOf: start ..< start + items.count)
        return s
    }

    // MARK: - Remove

    /// Remove the track at display position `index`. Removing the playing track
    /// advances to whatever follows it in TRAVERSAL order (no wrap); the
    /// returned effect tells the caller what playback should do.
    public static func remove<E>(at index: Int, from state: State<E>)
        -> (state: State<E>, effect: RemovalEffect) {
        guard state.queue.indices.contains(index) else { return (state, .none) }
        var s = state

        // Resolve the effect against the OLD indices before any remapping.
        var effect: RemovalEffect = .none
        if state.currentIndex == index {
            if let pos = state.playOrder.firstIndex(of: index),
               pos + 1 < state.playOrder.count {
                let nextOld = state.playOrder[pos + 1]
                let nextNew = nextOld > index ? nextOld - 1 : nextOld
                s.currentIndex = nextNew
                effect = .playTrack(queueIndex: nextNew)
            } else {
                s.currentIndex = nil
                effect = .stopPlayback
            }
        } else if let current = state.currentIndex, current > index {
            s.currentIndex = current - 1
        }

        s.queue.remove(at: index)
        s.playOrder = s.playOrder.compactMap {
            if $0 == index { return nil }
            return $0 > index ? $0 - 1 : $0
        }
        return (s, effect)
    }

    // MARK: - Move

    /// Display-order reorder with `List.onMove` offset semantics; `currentIndex`
    /// follows its track. The returned `playOrder` is rebuilt as the IDENTITY
    /// traversal — correct for shuffle-off; with shuffle ON the caller must
    /// rebuild its shuffled traversal afterwards (randomness stays out of this
    /// pure helper).
    public static func move<E>(fromOffsets source: IndexSet, toOffset destination: Int,
                               in state: State<E>) -> State<E> {
        var s = state
        // Mirror the move on an identity array to learn old → new positions.
        var positions = Array(s.queue.indices)
        applyMove(&s.queue, fromOffsets: source, toOffset: destination)
        applyMove(&positions, fromOffsets: source, toOffset: destination)
        if let current = s.currentIndex {
            s.currentIndex = positions.firstIndex(of: current)
        }
        s.playOrder = Array(s.queue.indices)
        return s
    }

    /// `MutableCollection.move(fromOffsets:toOffset:)` semantics (the SwiftUI
    /// `List.onMove` contract: `destination` is an offset into the ORIGINAL
    /// array), reimplemented here because the real one ships in SwiftUI, which
    /// PMSKit doesn't link.
    private static func applyMove<T>(_ array: inout [T],
                                     fromOffsets source: IndexSet,
                                     toOffset destination: Int) {
        let valid = source.filter { array.indices.contains($0) }
        guard !valid.isEmpty, destination >= 0, destination <= array.count else { return }
        let moving = valid.map { array[$0] }
        for index in valid.sorted(by: >) { array.remove(at: index) }
        let adjusted = destination - valid.filter { $0 < destination }.count
        array.insert(contentsOf: moving, at: adjusted)
    }

    // MARK: - Clear

    /// "Clear queue": drop everything except the current track. With nothing
    /// playing the queue empties entirely.
    public static func clearUpcoming<E>(in state: State<E>) -> State<E> {
        guard let current = state.currentIndex, state.queue.indices.contains(current) else {
            return State(queue: [], playOrder: [], currentIndex: nil)
        }
        return State(queue: [state.queue[current]], playOrder: [0], currentIndex: 0)
    }
}

extension QueueMutation.State: Equatable where Element: Equatable {}
extension QueueMutation.State: Sendable where Element: Sendable {}
