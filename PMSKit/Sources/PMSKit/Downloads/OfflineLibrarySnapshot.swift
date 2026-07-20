import Foundation

/// Pre-derived data for the offline downloads list.
///
/// The downloads screen is a hot UI: transfer callbacks can update bytes/ETA/progress many
/// times while the user is scrolling. Keep the UI tree reading one coarse snapshot rather
/// than several coordinator dictionaries from every row, so progress refreshes do less
/// observation work and row rendering stays value-driven.
public struct OfflineLibrarySnapshot: Sendable, Equatable {
    public static let empty = OfflineLibrarySnapshot(rows: [], queueToolbarAction: nil, isQueuePaused: false,
                                                     aggregateStats: .empty,
                                                     activeTransferPercentage: nil)

    public let rows: [OfflineDownloadRowSnapshot]
    public let queueToolbarAction: DownloadQueueToolbarPolicy.Action?
    public let isQueuePaused: Bool
    public let aggregateStats: OfflineDownloadAggregateStats
    public let activeTransferPercentage: Int?

    public init(rows: [OfflineDownloadRowSnapshot],
                queueToolbarAction: DownloadQueueToolbarPolicy.Action?,
                isQueuePaused: Bool,
                aggregateStats: OfflineDownloadAggregateStats,
                activeTransferPercentage: Int? = nil) {
        self.rows = rows
        self.queueToolbarAction = queueToolbarAction
        self.isQueuePaused = isQueuePaused
        self.aggregateStats = aggregateStats
        self.activeTransferPercentage = activeTransferPercentage
    }

    public var footerText: String {
        isQueuePaused
            ? "Download queue paused. Resume when you're ready to continue queued transfers."
            : "Background transfers are best-effort. Keep this device on power and reopen Labstream to let downloads resume and checkpoint."
    }

    public var ratingKeys: [String] { rows.map(\.id) }
}

public struct OfflineDownloadRowSnapshot: Identifiable, Sendable, Equatable {
    public let record: DownloadRecord
    public let showBackendBadge: Bool
    public let backendName: String
    public let errorMessage: String?
    public let displayProgress: Double?
    public let statusCaption: String
    public let isRetrying: Bool

    public init(record: DownloadRecord,
                showBackendBadge: Bool,
                backendName: String,
                errorMessage: String?,
                displayProgress: Double?,
                statusCaption: String,
                isRetrying: Bool) {
        self.record = record
        self.showBackendBadge = showBackendBadge
        self.backendName = backendName
        self.errorMessage = errorMessage
        self.displayProgress = displayProgress
        self.statusCaption = statusCaption
        self.isRetrying = isRetrying
    }

    public var id: String { record.ratingKey }
}
