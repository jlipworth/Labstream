import Foundation

/// Aggregate counters for the local Offline downloads library.
///
/// These values deliberately describe bytes/speeds observed by Labstream's local download store,
/// not server-side optimized files that exist only on Plex/Emby/Jellyfin.
public struct OfflineDownloadAggregateStats: Sendable, Equatable {
    public static let empty = OfflineDownloadAggregateStats(activeSpeedBytesPerSecond: nil,
                                                            downloadedBytes: 0)

    /// Batch rate measured over one common interval for every active transfer. Nil means the
    /// whole batch lacks trustworthy evidence; callers must never substitute a partial row sum.
    public var activeSpeedBytesPerSecond: Double?

    public var isUpdatingSpeed: Bool

    /// Total local bytes recorded across complete and incomplete rows. For active static-range
    /// transfers, callers may provide live display bytes so this aggregate matches the row progress
    /// while URLSession owns a large in-flight temp file between durable checkpoints. Paused/failed
    /// rows should pass no live overlay so the total snaps back to resumable local bytes honestly.
    public var downloadedBytes: Int

    public init(activeSpeedBytesPerSecond: Double?, downloadedBytes: Int, isUpdatingSpeed: Bool = false) {
        self.activeSpeedBytesPerSecond = activeSpeedBytesPerSecond
        self.downloadedBytes = downloadedBytes
        self.isUpdatingSpeed = isUpdatingSpeed
    }

    public var hasVisibleMetrics: Bool {
        activeSpeedBytesPerSecond != nil || isUpdatingSpeed || downloadedBytes > 0
    }

    public static func make(records: some Sequence<DownloadRecord>,
                            activeSpeedBytesPerSecond: Double?,
                            displayBytesByRatingKey: [String: Int] = [:]) -> OfflineDownloadAggregateStats {
        var hasActiveTransfer = false
        var totalBytes = 0

        for record in records {
            let effectiveBytes = max(record.bytes, displayBytesByRatingKey[record.ratingKey] ?? 0)
            if effectiveBytes > 0 {
                totalBytes += effectiveBytes
            }
            if record.sideAssetBytes > 0 {
                totalBytes += record.sideAssetBytes
            }
            hasActiveTransfer = hasActiveTransfer || record.lifecycle == .transferring
        }

        let speed = activeSpeedBytesPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return OfflineDownloadAggregateStats(activeSpeedBytesPerSecond: hasActiveTransfer ? speed : nil,
                                             downloadedBytes: totalBytes,
                                             isUpdatingSpeed: hasActiveTransfer && speed == nil)
    }
}
