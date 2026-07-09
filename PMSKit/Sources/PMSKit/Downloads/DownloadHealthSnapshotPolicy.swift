import Foundation

/// Session-owned download work counts used by the health snapshot diagnostic.
///
/// This mirrors the app's `BackgroundDownloadSession` diagnostic surface without making the pure
/// policy depend on URLSession/delegate state. The manager adapts its live session snapshot into
/// this value, then the policy owns row counting, work detection, throttle cadence, and field names.
public struct DownloadHealthSessionSnapshot: Equatable, Sendable {
    public var opaqueInflightCount: Int
    public var rangeInflightCount: Int
    public var haltedRangeKeyCount: Int
    public var pendingBackgroundCompletionOperationCount: Int
    public var deferredBackgroundCompletionIdentifierCount: Int
    public var backgroundCompletionHandlerCount: Int
    public var finalizingRatingKeyCount: Int
    public var pendingTempCleanupBytes: Int

    public init(opaqueInflightCount: Int = 0,
                rangeInflightCount: Int = 0,
                haltedRangeKeyCount: Int = 0,
                pendingBackgroundCompletionOperationCount: Int = 0,
                deferredBackgroundCompletionIdentifierCount: Int = 0,
                backgroundCompletionHandlerCount: Int = 0,
                finalizingRatingKeyCount: Int = 0,
                pendingTempCleanupBytes: Int = 0) {
        self.opaqueInflightCount = opaqueInflightCount
        self.rangeInflightCount = rangeInflightCount
        self.haltedRangeKeyCount = haltedRangeKeyCount
        self.pendingBackgroundCompletionOperationCount = pendingBackgroundCompletionOperationCount
        self.deferredBackgroundCompletionIdentifierCount = deferredBackgroundCompletionIdentifierCount
        self.backgroundCompletionHandlerCount = backgroundCompletionHandlerCount
        self.finalizingRatingKeyCount = finalizingRatingKeyCount
        self.pendingTempCleanupBytes = pendingTempCleanupBytes
    }

    public var hasSessionWork: Bool {
        opaqueInflightCount > 0
            || rangeInflightCount > 0
            || finalizingRatingKeyCount > 0
            || pendingBackgroundCompletionOperationCount > 0
    }
}

/// Fully derived, privacy-safe counts for the periodic `downloads.health_snapshot` event.
public struct DownloadHealthRuntimeSnapshot: Equatable, Sendable {
    public var recordCount: Int
    public var activeRecordCount: Int
    public var queuedCount: Int
    public var preparingCount: Int
    public var downloadingCount: Int
    public var activeJobCount: Int
    public var retryingCount: Int
    public var retryHandoffCount: Int
    public var pendingStaticResumeCount: Int
    public var finalizingStaticRecoveryCount: Int
    public var serverPrepPollerCount: Int
    public var jellyfinKeepaliveCount: Int
    public var forwardStallWatchCount: Int
    public var session: DownloadHealthSessionSnapshot

    public var hasWork: Bool {
        activeRecordCount > 0 || session.hasSessionWork
    }
}

/// Pure policy for the low-frequency download health diagnostic.
public enum DownloadHealthSnapshotPolicy {
    public static let diagnosticIntervalSeconds: TimeInterval = 60

    public static func makeSnapshot(records: [DownloadRecord],
                                    activeJobCount: Int,
                                    retryingCount: Int,
                                    retryHandoffCount: Int,
                                    pendingStaticResumeCount: Int,
                                    finalizingStaticRecoveryCount: Int,
                                    serverPrepPollerCount: Int,
                                    jellyfinKeepaliveCount: Int,
                                    forwardStallWatchCount: Int,
                                    session: DownloadHealthSessionSnapshot) -> DownloadHealthRuntimeSnapshot {
        let jobSnapshots = records.map(DownloadJobSnapshot.init(record:))
        return DownloadHealthRuntimeSnapshot(
            recordCount: records.count,
            activeRecordCount: jobSnapshots.filter { $0.persistedPhase.isActiveWork }.count,
            queuedCount: jobSnapshots.filter { $0.status == .queued }.count,
            preparingCount: jobSnapshots.filter { $0.status == .preparing }.count,
            downloadingCount: jobSnapshots.filter { $0.status == .downloading }.count,
            activeJobCount: activeJobCount,
            retryingCount: retryingCount,
            retryHandoffCount: retryHandoffCount,
            pendingStaticResumeCount: pendingStaticResumeCount,
            finalizingStaticRecoveryCount: finalizingStaticRecoveryCount,
            serverPrepPollerCount: serverPrepPollerCount,
            jellyfinKeepaliveCount: jellyfinKeepaliveCount,
            forwardStallWatchCount: forwardStallWatchCount,
            session: session)
    }

    public static func shouldRecord(snapshot: DownloadHealthRuntimeSnapshot,
                                    lastRecordedAt: Date?,
                                    now: Date) -> Bool {
        guard snapshot.hasWork else { return false }
        guard let lastRecordedAt else { return true }
        return now.timeIntervalSince(lastRecordedAt) >= diagnosticIntervalSeconds
    }

    public static func diagnosticFields(for snapshot: DownloadHealthRuntimeSnapshot) -> [String: DiagnosticFieldValue] {
        [
            "record_count": .int(snapshot.recordCount),
            "active_record_count": .int(snapshot.activeRecordCount),
            "queued_count": .int(snapshot.queuedCount),
            "preparing_count": .int(snapshot.preparingCount),
            "downloading_count": .int(snapshot.downloadingCount),
            "active_job_count": .int(snapshot.activeJobCount),
            "retrying_count": .int(snapshot.retryingCount),
            "retry_handoff_count": .int(snapshot.retryHandoffCount),
            "pending_static_resume_count": .int(snapshot.pendingStaticResumeCount),
            "finalizing_static_recovery_count": .int(snapshot.finalizingStaticRecoveryCount),
            "server_prep_poller_count": .int(snapshot.serverPrepPollerCount),
            "jellyfin_keepalive_count": .int(snapshot.jellyfinKeepaliveCount),
            "forward_stall_watch_count": .int(snapshot.forwardStallWatchCount),
            "session_inflight_count": .int(snapshot.session.opaqueInflightCount),
            "session_range_inflight_count": .int(snapshot.session.rangeInflightCount),
            "session_halted_range_count": .int(snapshot.session.haltedRangeKeyCount),
            "session_finalizing_count": .int(snapshot.session.finalizingRatingKeyCount),
            "session_pending_background_ops": .int(snapshot.session.pendingBackgroundCompletionOperationCount),
            "session_deferred_background_handlers": .int(snapshot.session.deferredBackgroundCompletionIdentifierCount),
            "session_background_handlers": .int(snapshot.session.backgroundCompletionHandlerCount),
            "session_pending_temp_cleanup_bytes": .int(snapshot.session.pendingTempCleanupBytes),
        ]
    }

}
