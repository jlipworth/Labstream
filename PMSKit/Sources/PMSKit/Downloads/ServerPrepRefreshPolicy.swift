import Foundation

/// Pure refresh-time decisions for server-preparation rows.
///
/// Plex optimize and Emby convert jobs both have a period where the server is doing work but the
/// app has no URLSession transfer yet. `DownloadManager.refreshRecords()` still owns store updates,
/// diagnostics, and task launches; this policy keeps the fragile reattach/queue-pause predicates in
/// one tested place so relaunch recovery does not depend on duplicated inline filters.
public enum ServerPrepRefreshPolicy {
    public struct BackendCounts: Equatable, Sendable {
        public let plex: Int
        public let emby: Int

        public init(plex: Int = 0, emby: Int = 0) {
            self.plex = plex
            self.emby = emby
        }
    }

    public struct RefreshPlan: Equatable, Sendable {
        /// Unattached Plex/Emby server-prep rows that were found on this refresh turn.
        public let candidateKeys: [String]
        /// Rows that should be parked while the global queue is paused.
        public let parkWhileQueuePausedKeys: [String]
        /// Emby convert rows that should keep their server-side poller attached while queue-paused.
        public let pollEmbyWhileQueuePausedKeys: [String]
        /// Whether this refresh turn should schedule a resume/poller kick.
        public let shouldScheduleKick: Bool
        /// If `true`, the queue-paused kick should only resume Emby convert polling; otherwise it
        /// should run the normal server-prep scanner.
        public let kickEmbyOnly: Bool
        public let parkedCounts: BackendCounts
        public let kickCounts: BackendCounts

        public init(candidateKeys: [String] = [],
                    parkWhileQueuePausedKeys: [String] = [],
                    pollEmbyWhileQueuePausedKeys: [String] = [],
                    shouldScheduleKick: Bool = false,
                    kickEmbyOnly: Bool = false,
                    parkedCounts: BackendCounts = BackendCounts(),
                    kickCounts: BackendCounts = BackendCounts()) {
            self.candidateKeys = candidateKeys
            self.parkWhileQueuePausedKeys = parkWhileQueuePausedKeys
            self.pollEmbyWhileQueuePausedKeys = pollEmbyWhileQueuePausedKeys
            self.shouldScheduleKick = shouldScheduleKick
            self.kickEmbyOnly = kickEmbyOnly
            self.parkedCounts = parkedCounts
            self.kickCounts = kickCounts
        }
    }

    public static func isUnattachedServerPrepRow(_ record: DownloadRecord,
                                                 hasPlexPoller: Bool,
                                                 isActiveJob: Bool) -> Bool {
        if DownloadRetryPolicy.isPlexServerPrepResumeCandidate(record) {
            return !hasPlexPoller
        }
        return shouldPollEmbyServerPrepWhileQueuePaused(record) && !isActiveJob
    }

    /// Queue pause stops new transfers, but an already-created Emby server-side convert job should
    /// keep polling until it hands off/finishes. Otherwise a global pause can strand persistent Emby
    /// Sync work in `.preparing` even though no bytes are being downloaded locally.
    public static func shouldPollEmbyServerPrepWhileQueuePaused(_ record: DownloadRecord) -> Bool {
        let backend = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
        return record.status == .preparing
            && backend == .emby
            && record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .serverPrepThenStatic
            && record.metadata?.resolvedDownloadLane() == .optimize
            && record.metadata?.embyConvertJobID != nil
    }

    public static func refreshPlan(records: [DownloadRecord],
                                   isQueuePaused: Bool,
                                   refreshKickScheduled: Bool,
                                   refreshKickRecent: Bool,
                                   hasPlexPoller: (String) -> Bool,
                                   isActiveJob: (String) -> Bool) -> RefreshPlan {
        let candidates = records.filter { record in
            isUnattachedServerPrepRow(record,
                                      hasPlexPoller: hasPlexPoller(record.ratingKey),
                                      isActiveJob: isActiveJob(record.ratingKey))
        }
        guard !candidates.isEmpty else { return RefreshPlan() }

        let canKick = !refreshKickScheduled && !refreshKickRecent
        if isQueuePaused {
            let pollEmby = candidates.filter(shouldPollEmbyServerPrepWhileQueuePaused)
            let park = candidates.filter { !shouldPollEmbyServerPrepWhileQueuePaused($0) }
            return RefreshPlan(candidateKeys: candidates.map(\.ratingKey),
                               parkWhileQueuePausedKeys: park.map(\.ratingKey),
                               pollEmbyWhileQueuePausedKeys: pollEmby.map(\.ratingKey),
                               shouldScheduleKick: canKick && !pollEmby.isEmpty,
                               kickEmbyOnly: true,
                               parkedCounts: backendCounts(for: park),
                               kickCounts: backendCounts(for: pollEmby))
        }

        return RefreshPlan(candidateKeys: candidates.map(\.ratingKey),
                           shouldScheduleKick: canKick,
                           kickEmbyOnly: false,
                           kickCounts: backendCounts(for: candidates))
    }

    private static func backendCounts(for records: [DownloadRecord]) -> BackendCounts {
        var plex = 0
        var emby = 0
        for record in records {
            switch record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
                ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey) {
            case .plex:
                plex += 1
            case .emby:
                emby += 1
            case .jellyfin:
                break
            }
        }
        return BackendCounts(plex: plex, emby: emby)
    }
}
