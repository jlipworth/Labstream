import Foundation

/// Pure policy for releasing app-level in-flight protection from persisted row state.
///
/// `DownloadManager` owns the actual side effects (active job slot, poller teardown, encoder cleanup),
/// but the terminal-row predicate is nuanced enough to pin here: a visible failed row that is still
/// inside the retry handoff window must not release until the replacement start has safely taken over.
public enum DownloadTerminalReleasePolicy {
    public static func terminalReleaseKeys(records: [DownloadRecord],
                                           retryHandoffKeys: Set<String>,
                                           retryingKeys: Set<String>) -> Set<String> {
        Set(records.filter { shouldReleaseInFlight(record: $0,
                                                   retryHandoffKeys: retryHandoffKeys,
                                                   retryingKeys: retryingKeys) }
            .map(\.ratingKey))
    }

    public static func shouldReleaseInFlight(record: DownloadRecord,
                                             retryHandoffKeys: Set<String>,
                                             retryingKeys: Set<String>) -> Bool {
        if record.status == .failed,
           retryHandoffKeys.contains(record.ratingKey),
           retryingKeys.contains(record.ratingKey) {
            return false
        }
        return record.status == .complete
            || record.status == .unverified
            || record.status == .failed
            || record.status == .paused
    }
}
