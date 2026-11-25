import Foundation

/// Pure decision for whether the app-level download watchdog should be running, and when the one
/// refresh that expires a silent row's speed should run.
///
/// The watchdog periodically refreshes records for work that really needs polling: forward-only
/// MediaBrowser streams that need stall detection, and server-prep rows that need poller
/// reconciliation. A transferring row's speed and ETA are recomputed only by a refresh, so a row
/// whose callbacks stop silently kept its last speed on screen (#488, TLA+ Status-S2). That needs
/// one refresh when the row's rate evidence goes stale, not a loop: polling every 15 s for as long
/// as a static row stayed transferring rebuilt the library on the main actor for ever (#488
/// review). `nextRateEvidenceExpiry` picks that moment. The app layer owns the timer Tasks; this
/// policy pins the row predicates, the expiry and the cadence.
public enum DownloadWatchdogPolicy {
    public static let refreshIntervalSeconds: Double = 15.0

    /// Past the stale deadline, so the expiry refresh lands after the estimator's cutoff.
    public static let rateExpirySlackSeconds: Double = 0.25

    public static func requiresWatchdog(_ record: DownloadRecord) -> Bool {
        DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(record)
            || record.status == .preparing
    }

    public static func requiresWatchdog(records: some Sequence<DownloadRecord>) -> Bool {
        records.contains(where: requiresWatchdog)
    }

    /// The one-shot refresh that removes a silent row's speed and ETA: the earliest stale deadline
    /// still ahead of `now` among the rows that show rate evidence, plus the slack. `nil` once
    /// every deadline has passed, so a row that stays silent costs one refresh, not a loop. A
    /// new forward byte moves the row's deadline and arms it again.
    public static func nextRateEvidenceExpiry(staleDeadlines: some Sequence<Date>, now: Date) -> Date? {
        staleDeadlines.filter { $0 > now }.min().map { $0.addingTimeInterval(rateExpirySlackSeconds) }
    }
}
