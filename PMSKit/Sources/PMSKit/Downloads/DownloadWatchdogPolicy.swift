import Foundation

/// Pure decision for whether the app-level download watchdog should be running.
///
/// The watchdog periodically refreshes records for work with no steady URLSession progress callback:
/// forward-only MediaBrowser streams that need stall detection, and server-prep rows that need poller
/// reconciliation. The app layer owns the timer Task; this policy pins the row predicates and cadence.
public enum DownloadWatchdogPolicy {
    public static let refreshIntervalSeconds: Double = 15.0

    public static func requiresWatchdog(_ record: DownloadRecord) -> Bool {
        DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(record)
            || record.status == .preparing
    }

    public static func requiresWatchdog(records: some Sequence<DownloadRecord>) -> Bool {
        records.contains(where: requiresWatchdog)
    }
}
