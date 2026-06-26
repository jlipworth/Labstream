/// Small ordering/coalescing helper for playback timeline sends.
///
/// The app still owns the network transport and diagnostics, but this pure helper pins the
/// lifecycle rules in PMSKit tests:
/// - timeline heartbeats waiting behind an in-flight request coalesce to the newest state;
/// - scrobble requests are ordering barriers and are never dropped here;
/// - the first `.stopped` timeline request is terminal for the reporter/session, drops any
///   older queued heartbeat, and rejects later timeline states.
public struct TimelineSendCoalescer<Event: Sendable>: Sendable {
    public enum Kind: Sendable, Equatable {
        case timeline(TimelineRequest.State)
        case scrobble

        var isTimeline: Bool {
            if case .timeline = self { return true }
            return false
        }

        var isCoalescibleTimeline: Bool {
            switch self {
            case .timeline(.stopped), .scrobble:
                return false
            case .timeline:
                return true
            }
        }
    }

    public struct Queued: Sendable {
        public let event: Event
        public let kind: Kind

        init(event: Event, kind: Kind) {
            self.event = event
            self.kind = kind
        }
    }

    private var queued: [Queued] = []
    private var hasFinalStoppedTimeline = false

    public init() {}

    /// Enqueue an event, applying heartbeat coalescing and final-stopped semantics.
    ///
    /// - Returns: `true` when the event was accepted; `false` when it was ignored because a
    ///   final `.stopped` timeline request has already been accepted for this queue.
    @discardableResult
    public mutating func enqueue(_ event: Event, kind: Kind) -> Bool {
        switch kind {
        case .timeline(.stopped):
            guard !hasFinalStoppedTimeline else { return false }
            hasFinalStoppedTimeline = true
            queued.removeAll { $0.kind.isTimeline }
            queued.append(Queued(event: event, kind: kind))
            return true

        case .timeline:
            guard !hasFinalStoppedTimeline else { return false }
            coalesceTimeline(event, kind: kind)
            return true

        case .scrobble:
            queued.append(Queued(event: event, kind: kind))
            return true
        }
    }

    /// Pop the next serialized send, if any.
    public mutating func popFirst() -> Queued? {
        guard !queued.isEmpty else { return nil }
        return queued.removeFirst()
    }

    public var isEmpty: Bool { queued.isEmpty }
    public var count: Int { queued.count }

    private mutating func coalesceTimeline(_ event: Event, kind: Kind) {
        let new = Queued(event: event, kind: kind)
        let barrierIndex = queued.lastIndex { !$0.kind.isCoalescibleTimeline }
        let searchStart = barrierIndex.map { queued.index(after: $0) } ?? queued.startIndex
        if searchStart < queued.endIndex,
           let existingIndex = queued[searchStart...].lastIndex(where: { $0.kind.isCoalescibleTimeline }) {
            queued[existingIndex] = new
        } else {
            queued.append(new)
        }
    }
}
