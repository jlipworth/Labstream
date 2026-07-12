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

    private var queueTitleByAttempt: [DownloadAttemptKey: String] = [:]
    private var embyConvertAttemptByAttempt: [DownloadAttemptKey: UUID] = [:]
    private var plexPollerByAttempt: [DownloadAttemptKey: UUID] = [:]

    public init() {}

    public var allProtectedQueueTitles: Set<String> { Set(queueTitleByAttempt.values) }

    public func queueTitle(for key: DownloadAttemptKey) -> String? {
        queueTitleByAttempt[key]
    }

    public mutating func protectQueueTitle(_ title: String, for key: DownloadAttemptKey) {
        queueTitleByAttempt[key] = title
    }

    @discardableResult
    public mutating func releaseQueueTitle(for key: DownloadAttemptKey) -> String? {
        guard let title = queueTitleByAttempt.removeValue(forKey: key) else { return nil }
        return title
    }

    public func hasPlexPoller(for key: DownloadAttemptKey) -> Bool {
        plexPollerByAttempt[key] != nil
    }

    @discardableResult
    public mutating func beginPlexPoller(for key: DownloadAttemptKey, id: UUID = UUID()) -> UUID? {
        guard plexPollerByAttempt[key] == nil else { return nil }
        plexPollerByAttempt[key] = id
        return id
    }

    /// True while `id` is still the ATTACHED Plex poller for this record key. Cancelled pollers
    /// (pause/delete run `releaseAll`, a quick resume then begins a NEW poller id) must check
    /// this before running terminal cleanup: an unconditional release from a superseded poller's
    /// catch handler would strip the new attempt's slot/queue-title and cancel its poller.
    public func isCurrentPlexPoller(for key: DownloadAttemptKey, id: UUID) -> Bool {
        plexPollerByAttempt[key] == id
    }

    @discardableResult
    public mutating func endPlexPoller(for key: DownloadAttemptKey, id: UUID) -> Bool {
        guard plexPollerByAttempt[key] == id else { return false }
        plexPollerByAttempt.removeValue(forKey: key)
        return true
    }

    @discardableResult
    public mutating func clearPlexPoller(for key: DownloadAttemptKey) -> Bool {
        plexPollerByAttempt.removeValue(forKey: key) != nil
    }

    @discardableResult
    public mutating func beginEmbyConvertAttempt(for key: DownloadAttemptKey, id: UUID = UUID()) -> UUID {
        embyConvertAttemptByAttempt[key] = id
        return id
    }

    public func isCurrentEmbyConvertAttempt(for key: DownloadAttemptKey, id: UUID) -> Bool {
        embyConvertAttemptByAttempt[key] == id
    }

    @discardableResult
    public mutating func clearEmbyConvertAttempt(for key: DownloadAttemptKey) -> Bool {
        embyConvertAttemptByAttempt.removeValue(forKey: key) != nil
    }

    @discardableResult
    public mutating func releaseAll(for key: DownloadAttemptKey) -> ReleaseSummary {
        let title = releaseQueueTitle(for: key)
        let clearedEmby = clearEmbyConvertAttempt(for: key)
        let clearedPoller = clearPlexPoller(for: key)
        return ReleaseSummary(releasedQueueTitle: title,
                              clearedEmbyConvertAttempt: clearedEmby,
                              clearedPlexPoller: clearedPoller)
    }
}
