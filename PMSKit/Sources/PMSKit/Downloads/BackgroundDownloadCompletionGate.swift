import Foundation

/// Pure state machine for deciding when a background URLSession completion batch can be fired.
///
/// The app delegate's completion handlers must be held while finished download callbacks are still
/// being durably appended/finalized. Releasing them too early can let the OS suspend the app between
/// receipt of a temp file and the write/status update that makes the download recoverable.
public struct BackgroundDownloadCompletionGate: Sendable, Equatable {
    private var pendingOperations = 0
    private var awaitingTokensByIdentifier:
        [String: [BackgroundDownloadCompletionHandlerToken]] = [:]
    private var deferredBatches: [BackgroundDownloadCompletionReleaseBatch] = []

    public init() {}

    public var pendingOperationCount: Int { pendingOperations }
    public var awaitingFinishIdentifierCount: Int { awaitingTokensByIdentifier.count }
    public var awaitingFinishHandlerCount: Int {
        awaitingTokensByIdentifier.values.reduce(into: 0) { $0 += $1.count }
    }
    public var pendingHandlerCount: Int {
        awaitingFinishHandlerCount + deferredBatches.reduce(into: 0) {
            $0 += $1.tokens.count
        }
    }
    public var deferredIdentifierCount: Int {
        Set(deferredBatches.map(\.identifier)).count
    }

    public var hasPendingHandler: Bool {
        pendingHandlerCount > 0
    }

    public mutating func beginOperation() {
        pendingOperations += 1
    }

    /// Marks one durable/finalization operation finished.
    ///
    /// Returns exact deferred handler batches that are now safe to fire. Extra `endOperation`
    /// calls are clamped at zero so duplicate cleanup paths cannot underflow the gate.
    public mutating func endOperation() -> [BackgroundDownloadCompletionReleaseBatch] {
        pendingOperations = max(0, pendingOperations - 1)
        guard pendingOperations == 0 else { return [] }
        let batches = deferredBatches
        deferredBatches.removeAll()
        return batches
    }

    public mutating func storeHandler(
        identifier: String,
        token: BackgroundDownloadCompletionHandlerToken
    ) {
        var tokens = awaitingTokensByIdentifier[identifier, default: []]
        guard !tokens.contains(token),
              !deferredBatches.contains(where: { $0.tokens.contains(token) }) else { return }
        tokens.append(token)
        awaitingTokensByIdentifier[identifier] = tokens
    }

    /// Notes that URLSession finished delivering events for `identifier`.
    ///
    /// The transition atomically claims every handler token supplied for the current wake cycle.
    /// A handler stored afterward starts a new awaiting batch and cannot be swept by this release.
    public mutating func finishEvents(
        identifier: String
    ) -> [BackgroundDownloadCompletionReleaseBatch] {
        guard let tokens = awaitingTokensByIdentifier.removeValue(forKey: identifier),
              !tokens.isEmpty else { return [] }
        let batch = BackgroundDownloadCompletionReleaseBatch(
            identifier: identifier,
            tokens: tokens
        )
        if pendingOperations > 0 {
            deferredBatches.append(batch)
            return []
        }
        return [batch]
    }

    /// Fail-closed startup may be unable to instantiate/admit the background session, so no
    /// `urlSessionDidFinishEvents` callback can arrive. After the startup durability attempt has
    /// failed or timed out observably, release every stored handler rather than retaining an OS
    /// wake indefinitely. This is deliberately destructive and only for terminal startup failure.
    public mutating func abortAwaitingHandlers() -> [BackgroundDownloadCompletionReleaseBatch] {
        var batches = deferredBatches
        for identifier in awaitingTokensByIdentifier.keys.sorted() {
            guard let tokens = awaitingTokensByIdentifier[identifier], !tokens.isEmpty else {
                continue
            }
            batches.append(BackgroundDownloadCompletionReleaseBatch(
                identifier: identifier,
                tokens: tokens
            ))
        }
        awaitingTokensByIdentifier.removeAll()
        deferredBatches.removeAll()
        pendingOperations = 0
        return batches
    }
}
