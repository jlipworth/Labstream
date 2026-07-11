import Foundation

/// Pure state machine for deciding when a background URLSession completion handler can be fired.
///
/// The app delegate's completion handler must be held while finished download callbacks are still
/// being durably appended/finalized. Releasing it too early can let the OS suspend the app between
/// receipt of a temp file and the write/status update that makes the download recoverable.
public struct BackgroundDownloadCompletionGate: Sendable, Equatable {
    private var pendingOperations = 0
    private var awaitingFinishIdentifiers: Set<String> = []
    private var deferredIdentifiers: Set<String> = []

    public init() {}

    public var pendingOperationCount: Int { pendingOperations }
    public var awaitingFinishIdentifierCount: Int { awaitingFinishIdentifiers.count }
    public var deferredIdentifierCount: Int { deferredIdentifiers.count }

    public var hasPendingHandler: Bool {
        !awaitingFinishIdentifiers.isEmpty || !deferredIdentifiers.isEmpty
    }

    public mutating func beginOperation() {
        pendingOperations += 1
    }

    /// Marks one durable/finalization operation finished.
    ///
    /// Returns deferred URLSession identifiers that are now safe to fire. Extra `endOperation`
    /// calls are clamped at zero so duplicate cleanup paths cannot underflow the gate.
    public mutating func endOperation() -> [String] {
        pendingOperations = max(0, pendingOperations - 1)
        guard pendingOperations == 0 else { return [] }
        let identifiers = Array(deferredIdentifiers).sorted()
        deferredIdentifiers.removeAll()
        return identifiers
    }

    public mutating func storeHandler(identifier: String) {
        awaitingFinishIdentifiers.insert(identifier)
    }

    /// Notes that URLSession finished delivering events for `identifier`.
    ///
    /// Returns `[identifier]` when the app delegate completion handler can be fired immediately,
    /// otherwise returns `[]` and defers it until `endOperation()` drains the pending work.
    public mutating func finishEvents(identifier: String) -> [String] {
        // Duplicate/stale URLSession callbacks must not manufacture a release. The session
        // identifier is stable across app launches, so replaying one could consume a handler
        // stored for a later background delivery cycle.
        guard awaitingFinishIdentifiers.remove(identifier) != nil else { return [] }
        if pendingOperations > 0 {
            deferredIdentifiers.insert(identifier)
            return []
        }
        return [identifier]
    }
}
