import Foundation

/// IO-free bookkeeping for server-prep download attempts.
///
/// Plex optimize and Emby convert both have a server-side preparation phase before bytes are
/// downloaded, but their attempt identities differ: Plex gives us a queue-title marker we must
/// protect from stale-job cleanup, while Emby ignores our submitted name and has to be guarded by
/// an app-local attempt UUID. This tracker centralizes those identities so the app coordinator can
/// release them atomically with the visible download row.
public struct ServerPrepAttemptTracker: Sendable, Equatable {
    public struct ReleaseSummary: Sendable, Equatable {
        public let releasedQueueTitle: String?
        public let clearedEmbyConvertAttempt: Bool
        public let clearedPlexPoller: Bool

        public var didReleaseAnything: Bool {
            releasedQueueTitle != nil || clearedEmbyConvertAttempt || clearedPlexPoller
        }
    }

    private var protectedQueueTitles: Set<String> = []
    private var queueTitleByRecordKey: [String: String] = [:]
    private var embyConvertAttemptByRecordKey: [String: UUID] = [:]
    private var plexPollerByRecordKey: [String: UUID] = [:]

    public init() {}

    public var allProtectedQueueTitles: Set<String> { protectedQueueTitles }

    public func queueTitle(forRecordKey recordKey: String) -> String? {
        queueTitleByRecordKey[recordKey]
    }

    public mutating func protectQueueTitle(_ title: String, forRecordKey recordKey: String) {
        protectedQueueTitles.insert(title)
        queueTitleByRecordKey[recordKey] = title
    }

    @discardableResult
    public mutating func releaseQueueTitle(forRecordKey recordKey: String) -> String? {
        guard let title = queueTitleByRecordKey.removeValue(forKey: recordKey) else { return nil }
        protectedQueueTitles.remove(title)
        return title
    }

    public func hasPlexPoller(forRecordKey recordKey: String) -> Bool {
        plexPollerByRecordKey[recordKey] != nil
    }

    @discardableResult
    public mutating func beginPlexPoller(forRecordKey recordKey: String, id: UUID = UUID()) -> UUID? {
        guard plexPollerByRecordKey[recordKey] == nil else { return nil }
        plexPollerByRecordKey[recordKey] = id
        return id
    }

    @discardableResult
    public mutating func endPlexPoller(forRecordKey recordKey: String, id: UUID) -> Bool {
        guard plexPollerByRecordKey[recordKey] == id else { return false }
        plexPollerByRecordKey.removeValue(forKey: recordKey)
        return true
    }

    @discardableResult
    public mutating func clearPlexPoller(forRecordKey recordKey: String) -> Bool {
        plexPollerByRecordKey.removeValue(forKey: recordKey) != nil
    }

    @discardableResult
    public mutating func beginEmbyConvertAttempt(forRecordKey recordKey: String, id: UUID = UUID()) -> UUID {
        embyConvertAttemptByRecordKey[recordKey] = id
        return id
    }

    public func isCurrentEmbyConvertAttempt(forRecordKey recordKey: String, id: UUID) -> Bool {
        embyConvertAttemptByRecordKey[recordKey] == id
    }

    @discardableResult
    public mutating func clearEmbyConvertAttempt(forRecordKey recordKey: String) -> Bool {
        embyConvertAttemptByRecordKey.removeValue(forKey: recordKey) != nil
    }

    @discardableResult
    public mutating func releaseAll(forRecordKey recordKey: String) -> ReleaseSummary {
        let title = releaseQueueTitle(forRecordKey: recordKey)
        let clearedEmby = clearEmbyConvertAttempt(forRecordKey: recordKey)
        let clearedPoller = clearPlexPoller(forRecordKey: recordKey)
        return ReleaseSummary(releasedQueueTitle: title,
                              clearedEmbyConvertAttempt: clearedEmby,
                              clearedPlexPoller: clearedPoller)
    }
}
