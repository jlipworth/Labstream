import Foundation

/// IO-free owner for app-level retry presentation and handoff state.
///
/// Manual/backend retries need three related but distinct markers: an async retry guard, a visible
/// "Retrying…" overlay, and a handoff sentinel that prevents refresh cleanup from treating the
/// transient `.failed` row as truly terminal before replacement work is seeded. Keeping those sets in
/// one value makes the lifecycle operations explicit and prevents call sites from clearing only part
/// of the handoff accidentally.
public struct DownloadRetryStateTracker: Sendable, Equatable {
    /// Attempt-scoped (lens 6 F5): each `begin` mints a UUID and async retry continuations verify
    /// THEIR token via `isCurrentRetryAttempt`. A bare membership check let pause→resume revive a
    /// superseded chain — pause removed the key, resume re-inserted it, and the OLD chain's
    /// `isRetrying` went true again mid-flight.
    private var retrying: [String: UUID] = [:]
    private var presenting: Set<String> = []
    private var handoff: Set<String> = []

    public init() {}

    public var retryingKeys: Set<String> { Set(retrying.keys) }
    public var handoffKeys: Set<String> { handoff }
    public var retryingCount: Int { retrying.count }
    public var handoffCount: Int { handoff.count }

    public func isRetrying(_ ratingKey: String) -> Bool { retrying[ratingKey] != nil }
    public func isCurrentRetryAttempt(_ ratingKey: String, id: UUID) -> Bool {
        retrying[ratingKey] == id
    }
    public func isPresentingRetry(_ ratingKey: String) -> Bool { presenting.contains(ratingKey) }
    public func isRetryHandoff(_ ratingKey: String) -> Bool { handoff.contains(ratingKey) }

    @discardableResult
    public mutating func begin(_ ratingKey: String, id: UUID = UUID()) -> UUID {
        retrying[ratingKey] = id
        presenting.insert(ratingKey)
        handoff.insert(ratingKey)
        return id
    }

    public mutating func removeRetrying(_ ratingKey: String) {
        retrying.removeValue(forKey: ratingKey)
    }

    public mutating func clearHandoff(_ ratingKey: String) {
        presenting.remove(ratingKey)
        handoff.remove(ratingKey)
    }

    public mutating func markReplacementSeeded(_ ratingKey: String) {
        retrying.removeValue(forKey: ratingKey)
        clearHandoff(ratingKey)
    }

    public mutating func removeAll(_ ratingKey: String) {
        retrying.removeValue(forKey: ratingKey)
        clearHandoff(ratingKey)
    }
}
