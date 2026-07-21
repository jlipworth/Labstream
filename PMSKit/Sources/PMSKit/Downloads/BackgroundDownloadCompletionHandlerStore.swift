import Foundation

/// Stable identity for one app-delegate completion handler supplied by the system.
public struct BackgroundDownloadCompletionHandlerToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// The exact handlers owned by one `urlSessionDidFinishEvents` transition.
///
/// Tokens are captured when the completion gate observes the finish event, before any persistence
/// wait begins. A later release therefore cannot consume a handler supplied for a newer wake cycle
/// that happens to use the same stable URLSession identifier.
public struct BackgroundDownloadCompletionReleaseBatch: Equatable, Sendable {
    public let identifier: String
    public let tokens: [BackgroundDownloadCompletionHandlerToken]

    public init(
        identifier: String,
        tokens: [BackgroundDownloadCompletionHandlerToken]
    ) {
        self.identifier = identifier
        self.tokens = tokens
    }
}

/// Stores every app-delegate completion handler supplied for a background URLSession wake.
///
/// The system can deliver more than one handler for the same stable session identifier before
/// `urlSessionDidFinishEvents` releases that identifier. Each handler receives a unique token so a
/// delayed release can drain only the exact batch claimed by its gate transition.
public struct BackgroundDownloadCompletionHandlerStore {
    public typealias Handler = () -> Void

    private struct Entry {
        let token: BackgroundDownloadCompletionHandlerToken
        let handler: Handler
    }

    private var entriesByIdentifier: [String: [Entry]] = [:]

    public init() {}

    public var totalCount: Int {
        entriesByIdentifier.values.reduce(into: 0) { $0 += $1.count }
    }

    public func count(for identifier: String) -> Int {
        entriesByIdentifier[identifier]?.count ?? 0
    }

    public func hasHandlers(for identifier: String) -> Bool {
        count(for: identifier) > 0
    }

    public func pendingTokens(
        for identifier: String
    ) -> [BackgroundDownloadCompletionHandlerToken] {
        entriesByIdentifier[identifier]?.map(\.token) ?? []
    }

    @discardableResult
    public mutating func append(
        identifier: String,
        handler: @escaping Handler
    ) -> BackgroundDownloadCompletionHandlerToken {
        let token = BackgroundDownloadCompletionHandlerToken()
        entriesByIdentifier[identifier, default: []].append(Entry(token: token, handler: handler))
        return token
    }

    /// Removes and returns only the handlers claimed by `batch`, in their original supply order.
    /// Tokens supplied after the batch was formed remain pending for the next release cycle.
    public mutating func drain(
        batch: BackgroundDownloadCompletionReleaseBatch
    ) -> [Handler] {
        guard let entries = entriesByIdentifier[batch.identifier], !entries.isEmpty else {
            return []
        }
        let claimedTokens = Set(batch.tokens)
        var claimedHandlers: [Handler] = []
        var remainingEntries: [Entry] = []
        claimedHandlers.reserveCapacity(min(entries.count, claimedTokens.count))
        remainingEntries.reserveCapacity(entries.count)
        for entry in entries {
            if claimedTokens.contains(entry.token) {
                claimedHandlers.append(entry.handler)
            } else {
                remainingEntries.append(entry)
            }
        }
        if remainingEntries.isEmpty {
            entriesByIdentifier.removeValue(forKey: batch.identifier)
        } else {
            entriesByIdentifier[batch.identifier] = remainingEntries
        }
        return claimedHandlers
    }
}
