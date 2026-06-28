import Foundation

/// Aggregate counters for the local Offline downloads library.
///
/// These values deliberately describe bytes/speeds observed by VisionPlay's local download store,
/// not server-side optimized files that exist only on Plex/Emby/Jellyfin.
public struct OfflineDownloadAggregateStats: Sendable, Equatable {
    public static let empty = OfflineDownloadAggregateStats(activeSpeedBytesPerSecond: nil,
                                                            downloadedBytes: 0)

    /// Sum of currently measured per-row rates for active work. Nil means no active transfer has a
    /// trustworthy rate yet, which lets the UI stay quiet instead of showing noisy `0 B/s`.
    public var activeSpeedBytesPerSecond: Double?

    /// Total local bytes recorded across complete and incomplete rows. This includes paused/failed
    /// partials because those bytes are already present in the app's offline download store.
    public var downloadedBytes: Int

    public init(activeSpeedBytesPerSecond: Double?, downloadedBytes: Int) {
        self.activeSpeedBytesPerSecond = activeSpeedBytesPerSecond
        self.downloadedBytes = downloadedBytes
    }

    public var hasVisibleMetrics: Bool {
        activeSpeedBytesPerSecond != nil || downloadedBytes > 0
    }

    public static func make(records: some Sequence<DownloadRecord>,
                            speedsByRatingKey: [String: Double]) -> OfflineDownloadAggregateStats {
        var totalSpeed = 0.0
        var hasActiveSpeed = false
        var totalBytes = 0

        for record in records {
            if record.bytes > 0 {
                totalBytes += record.bytes
            }
            if record.status.isActiveWork,
               let speed = speedsByRatingKey[record.ratingKey],
               speed.isFinite,
               speed > 0 {
                totalSpeed += speed
                hasActiveSpeed = true
            }
        }

        return OfflineDownloadAggregateStats(activeSpeedBytesPerSecond: hasActiveSpeed ? totalSpeed : nil,
                                             downloadedBytes: totalBytes)
    }
}
