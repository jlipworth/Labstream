import Foundation

/// Pure admission decision for the app-level per-download in-flight slot.
///
/// `DownloadManager` owns the mutable `activeJobs` set and diagnostics; this policy pins the
/// important distinction between a real duplicate active row, a duplicate active slot, and stale
/// bookkeeping left behind after a retry removed the only visible row.
public enum DownloadStartSlotPolicy {
    public enum Decision: Equatable, Sendable {
        case accept
        case rejectExistingActiveRow(status: DownloadStatus)
        case rejectAlreadyActive
        case recoverStaleSlotAndAccept
    }

    public static func decision(existingRecordStatus: DownloadStatus?,
                                hasActiveSlot: Bool,
                                allowReplacingExistingActiveRow: Bool = false) -> Decision {
        if let existingRecordStatus, existingRecordStatus.isActiveWork {
            if allowReplacingExistingActiveRow && !hasActiveSlot {
                return .accept
            }
            return .rejectExistingActiveRow(status: existingRecordStatus)
        }
        if hasActiveSlot {
            return existingRecordStatus == nil ? .recoverStaleSlotAndAccept : .rejectAlreadyActive
        }
        return .accept
    }
}
