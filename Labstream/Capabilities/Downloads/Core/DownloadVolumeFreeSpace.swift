import Foundation

/// Proactive free-space measurement for the downloads container volume.
///
/// iOS reports two different "free space" numbers: the raw filesystem free blocks
/// (`.systemFreeSize` / statfs) EXCLUDE purgeable space the system reclaims on demand, while
/// the Settings storage gauge — and Apple's designated answer for user-initiated downloads,
/// `volumeAvailableCapacityForImportantUsage` — include it. Preflighting large downloads
/// against the raw number rejects transfers the device can actually hold (observed live:
/// ~87 GB "available" in Settings vs ~8 GB raw free while two 9–11 GB movies were refused
/// with `storage_full`). Every proactive preflight/measurement site routes through here;
/// reactive ENOSPC classification (`DownloadDiskSpacePolicy`) intentionally does not — a
/// write that already failed is truth regardless of what any capacity query says.
enum DownloadVolumeFreeSpace {

    enum Source: String {
        case importantUsage = "important_usage"
        case systemFree = "system_free"
    }

    struct Measurement: Equatable {
        let bytes: Int64
        let source: Source
    }

    /// Free bytes on the volume containing `directory`, preferring the purgeable-inclusive
    /// important-usage capacity and falling back to the raw filesystem free size.
    static func measure(directory: URL,
                        fileManager: FileManager = .default) -> Measurement? {
        let importantUsage = (try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ))?.volumeAvailableCapacityForImportantUsage
        let systemFree = (try? fileManager.attributesOfFileSystem(
            forPath: directory.path))?[.systemFreeSize] as? NSNumber
        return resolve(importantUsageBytes: importantUsage,
                       systemFreeBytes: systemFree?.int64Value)
    }

    /// Pure selection seam: important-usage wins when it produced a positive value; zero/nil
    /// (unsupported volume, query failure) falls back to the raw free size.
    static func resolve(importantUsageBytes: Int64?, systemFreeBytes: Int64?) -> Measurement? {
        if let importantUsageBytes, importantUsageBytes > 0 {
            return Measurement(bytes: importantUsageBytes, source: .importantUsage)
        }
        if let systemFreeBytes {
            return Measurement(bytes: systemFreeBytes, source: .systemFree)
        }
        return nil
    }
}
