import Foundation

/// Pure cleanup predicates run during `DownloadManager.refreshRecords()` for static-range recovery
/// overlays. The app layer still owns the actual tracker mutations and URLSession liveness checks;
/// this policy pins which row states are terminal for each in-memory recovery overlay.
public enum StaticRangeRefreshCleanupPolicy {
    public static func finalizingTerminalKeys(records: [DownloadRecord]) -> Set<String> {
        Set(records.filter(isFinalizingTerminal).map(\.ratingKey))
    }

    public static func manualQueueResumeTerminalKeys(records: [DownloadRecord],
                                                     retryHandoffKeys: Set<String>,
                                                     retryingKeys: Set<String>) -> Set<String> {
        Set(records.filter { record in
            isManualQueueResumeTerminal(record,
                                        retryHandoffKeys: retryHandoffKeys,
                                        retryingKeys: retryingKeys)
        }.map(\.ratingKey))
    }

    public static func isFinalizingTerminal(_ record: DownloadRecord) -> Bool {
        record.status == .complete || record.status == .unverified || record.status == .failed
    }

    /// Manual queue-resume markers should clear on true terminal states, but not during the retry
    /// handoff window where the visible failed row is intentionally kept until the replacement start
    /// seeds successfully.
    public static func isManualQueueResumeTerminal(_ record: DownloadRecord,
                                                   retryHandoffKeys: Set<String>,
                                                   retryingKeys: Set<String>) -> Bool {
        if record.status == .complete || record.status == .unverified { return true }
        if record.status == .failed,
           retryHandoffKeys.contains(record.ratingKey),
           retryingKeys.contains(record.ratingKey) {
            return false
        }
        return record.status == .failed
    }

    public static func shouldKeepLiveRangeProgress(key: String,
                                                   activeDownloadingKeys: Set<String>) -> Bool {
        activeDownloadingKeys.contains(key)
    }
}
