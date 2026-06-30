/// IO-free owner for app-level retry presentation and handoff state.
///
/// Manual/backend retries need three related but distinct markers: an async retry guard, a visible
/// "Retrying…" overlay, and a handoff sentinel that prevents refresh cleanup from treating the
/// transient `.failed` row as truly terminal before replacement work is seeded. Keeping those sets in
/// one value makes the lifecycle operations explicit and prevents call sites from clearing only part
/// of the handoff accidentally.
public struct DownloadRetryStateTracker: Sendable, Equatable {
    private var retrying: Set<String> = []
    private var presenting: Set<String> = []
    private var handoff: Set<String> = []

    public init() {}

    public var retryingKeys: Set<String> { retrying }
    public var handoffKeys: Set<String> { handoff }
    public var retryingCount: Int { retrying.count }
    public var handoffCount: Int { handoff.count }

    public func isRetrying(_ ratingKey: String) -> Bool { retrying.contains(ratingKey) }
    public func isPresentingRetry(_ ratingKey: String) -> Bool { presenting.contains(ratingKey) }
    public func isRetryHandoff(_ ratingKey: String) -> Bool { handoff.contains(ratingKey) }

    public mutating func begin(_ ratingKey: String) {
        retrying.insert(ratingKey)
        presenting.insert(ratingKey)
        handoff.insert(ratingKey)
    }

    public mutating func removeRetrying(_ ratingKey: String) {
        retrying.remove(ratingKey)
    }

    public mutating func clearHandoff(_ ratingKey: String) {
        presenting.remove(ratingKey)
        handoff.remove(ratingKey)
    }

    public mutating func markReplacementSeeded(_ ratingKey: String) {
        retrying.remove(ratingKey)
        clearHandoff(ratingKey)
    }

    public mutating func removeAll(_ ratingKey: String) {
        retrying.remove(ratingKey)
        clearHandoff(ratingKey)
    }
}
