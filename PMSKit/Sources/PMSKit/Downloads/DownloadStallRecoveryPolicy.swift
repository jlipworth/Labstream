import Foundation

/// Pure policy for deciding when a visible MediaBrowser forward-only download has stopped making
/// byte progress long enough that the app should do what the user currently does manually: cancel
/// the stale encoder stream and retry from a fresh server-minted URL/session (#189).
public enum DownloadStallRecoveryPolicy {
    /// Long enough to avoid racing normal encoder pauses or short Wi-Fi blips, short enough to recover
    /// from the observed "active-looking, zero-bandwidth forever" network-switch wedge without an
    /// overnight soak.
    public static let defaultForwardOnlyStallTimeout: TimeInterval = 90

    /// Bound automatic restarts per visible row. Forward-only streams restart from byte 0, so repeated
    /// restarts would waste server CPU/network and can mask a real outage. Past the cap the next stall
    /// fails the row (`shouldFailForwardOnlyStream`); manual retry remains.
    public static let defaultMaxAutomaticRestarts = 2

    /// Only forward-only MediaBrowser streams should be auto-restarted. Static byte-range downloads
    /// already have durable checkpoint/range recovery, and Plex optimize phase 2 is a static Part once
    /// it exists.
    ///
    /// B61: classified from the persisted route (`liveForwardOnly`), not the display classifier.
    /// The display classifier hides compatible-remux rows that report a Content-Length, which left
    /// a stalled remux with a known size outside the watchdog.
    public static func isForwardOnlyMediaBrowserStream(_ record: DownloadRecord) -> Bool {
        guard record.status == .downloading else { return false }
        let backend = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
        guard backend == .jellyfin || backend == .emby else { return false }
        return record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey) == .liveForwardOnly
    }

    public static func shouldRestartForwardOnlyStream(record: DownloadRecord,
                                                      active: Bool,
                                                      lastForwardProgressAt: Date?,
                                                      now: Date,
                                                      restartAttempts: Int,
                                                      stallTimeout: TimeInterval = defaultForwardOnlyStallTimeout,
                                                      maxRestartAttempts: Int = defaultMaxAutomaticRestarts) -> Bool {
        guard active,
              isForwardOnlyMediaBrowserStream(record),
              restartAttempts < maxRestartAttempts,
              let lastForwardProgressAt else { return false }
        return now.timeIntervalSince(lastForwardProgressAt) >= stallTimeout
    }

    /// #497 (TLA+ Status-S5): the stall verdict once the automatic restarts are spent. The row would
    /// otherwise stay `downloading` at zero bytes for ever and, as a silent member of the batch, hold
    /// "Updating speed…" up for the rows that move. It fails as stalled and waits for a user Retry.
    public static func shouldFailForwardOnlyStream(record: DownloadRecord,
                                                   active: Bool,
                                                   lastForwardProgressAt: Date?,
                                                   now: Date,
                                                   restartAttempts: Int,
                                                   stallTimeout: TimeInterval = defaultForwardOnlyStallTimeout,
                                                   maxRestartAttempts: Int = defaultMaxAutomaticRestarts) -> Bool {
        guard active,
              isForwardOnlyMediaBrowserStream(record),
              restartAttempts >= maxRestartAttempts,
              let lastForwardProgressAt else { return false }
        return now.timeIntervalSince(lastForwardProgressAt) >= stallTimeout
    }

    /// TLA+ Status-S8 (#501): whether a queued stall verdict may still act. The verdict is decided in
    /// `refreshRecords` but runs later as a manager operation, and delegate callbacks keep moving
    /// the row in between. It acts only on the same attempt, still a forward-only stream, whose
    /// bytes have not moved since the observation that queued it; otherwise it would cancel a
    /// stream that is moving again (and, for a restart, start it over from byte 0).
    ///
    /// This is the manager's early read only. `.finalizing` also shows as `.downloading`, and the
    /// delegate can move the bytes after this read, so the verdict acts only through
    /// `stallVerdictMayCommit`, which the store checks atomically with the commit.
    public static func queuedStallVerdictStillWarranted(observed: DownloadRecord,
                                                        current: DownloadRecord) -> Bool {
        guard isForwardOnlyMediaBrowserStream(current),
              current.attemptID == observed.attemptID else { return false }
        // A record built outside the store carries no lifecycle; the store's check still decides.
        return stallVerdictMayCommit(lifecycle: current.lifecycle ?? .transferring, bytes: current.bytes,
                                     observedBytes: observed.bytes)
    }

    /// Review of PR #505 (#501 follow-up): the store's conditional accept of a stall verdict,
    /// evaluated on the exact attempt under the store lock in the same hold as the `stallDetected`
    /// commit and before any cancel. A body that finished (`.finalizing`) or bytes that moved past
    /// the observation reject it, so the manager never cancels the session work of a stream that
    /// finished or moved again, nor overwrites its error.
    public static func stallVerdictMayCommit(lifecycle: DownloadLifecycle, bytes: Int,
                                             observedBytes: Int) -> Bool {
        lifecycle == .transferring && bytes <= observedBytes
    }
}
