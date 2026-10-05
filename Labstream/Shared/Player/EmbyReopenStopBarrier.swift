import Foundation

/// Owns an exact-session stop until acknowledgement, independently of cancelled viewers.
@MainActor
final class EmbyReopenStopBarrier {
    private var operation: (() async -> Bool)?
    private var pending: Task<Bool, Never>?
    private var finalRetryAttempted = false
    private var latestTicket: Task<Bool, Never>?

    var hasAuthority: Bool { operation != nil || pending != nil }
    /// Includes a completed failed ticket; observing it never silently retries a stop.
    var currentTicket: Task<Bool, Never>? { hasAuthority ? (pending ?? latestTicket) : nil }

    /// Overlapping callers join the same ticket; a failed ticket retains authority for retry.
    func begin(stop: inout (() async -> Bool)?) -> Task<Bool, Never> {
        if let pending {
            precondition(stop == nil, "A distinct stop ticket cannot replace in-flight session authority")
            return pending
        }
        precondition(operation == nil || stop == nil, "A failed stop ticket retains exact-session authority")
        if operation == nil, let owned = stop {
            operation = owned
            finalRetryAttempted = false
            stop = nil
        }
        guard let operation else { return Task { false } }
        let task = Task { @MainActor in
            let acknowledged = await operation()
            if acknowledged { self.operation = nil }
            self.pending = nil
            return acknowledged
        }
        pending = task
        latestTicket = task
        return task
    }
    /// Teardown joins in-flight work or retries a failed ticket once, never an automatic loop.
    func beginFinalStop() -> Task<Bool, Never>? {
        if let pending { return pending }
        guard operation != nil, !finalRetryAttempted else { return nil }
        finalRetryAttempted = true
        var stop: (() async -> Bool)?
        return begin(stop: &stop)
    }

}
