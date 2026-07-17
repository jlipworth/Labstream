/// Exact authority for the one current in-flight slot associated with a visible rating key.
/// Compare-release prevents a delayed attempt A from clearing replacement attempt B.
public struct DownloadInFlightAttemptTracker: Sendable, Equatable {
    private var ownerByRatingKey: [String: DownloadAttemptKey] = [:]

    public init() {}

    public var count: Int { ownerByRatingKey.count }

    public func owner(forRatingKey ratingKey: String) -> DownloadAttemptKey? {
        ownerByRatingKey[ratingKey]
    }

    public func owns(_ key: DownloadAttemptKey) -> Bool {
        ownerByRatingKey[key.ratingKey] == key
    }

    public mutating func acquire(_ key: DownloadAttemptKey) {
        ownerByRatingKey[key.ratingKey] = key
    }

    @discardableResult
    public mutating func release(ifOwnedBy key: DownloadAttemptKey) -> Bool {
        guard owns(key) else { return false }
        ownerByRatingKey.removeValue(forKey: key.ratingKey)
        return true
    }

    @discardableResult
    public mutating func repairUnownedState(forRatingKey ratingKey: String) -> DownloadAttemptKey? {
        ownerByRatingKey.removeValue(forKey: ratingKey)
    }
}
