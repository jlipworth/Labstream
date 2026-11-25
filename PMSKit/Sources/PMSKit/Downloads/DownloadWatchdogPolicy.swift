import Foundation

/// Pure decision for whether the app-level download watchdog should be running.
///
/// The watchdog periodically refreshes records for work with no steady URLSession progress callback:
/// forward-only MediaBrowser streams that need stall detection, server-prep rows that need poller
/// reconciliation, and any transferring row, whose callbacks stop when it stalls silently (#488,
/// TLA+ Status-S2): a row's speed and ETA are recomputed only by a refresh, so without the loop a
/// stalled row kept its last speed on screen. The app layer owns the timer Task; this policy pins
/// the row predicates and cadence.
public enum DownloadWatchdogPolicy {
    public static let refreshIntervalSeconds: Double = 15.0

    public static func requiresWatchdog(_ record: DownloadRecord) -> Bool {
        DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(record)
            || record.status == .preparing
            || record.lifecycle == .transferring
    }

    public static func requiresWatchdog(records: some Sequence<DownloadRecord>) -> Bool {
        records.contains(where: requiresWatchdog)
    }
}
