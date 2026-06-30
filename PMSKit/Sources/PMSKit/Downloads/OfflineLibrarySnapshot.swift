import Foundation

/// Pre-derived data for the offline downloads list.
///
/// The downloads screen is a hot UI: transfer callbacks can update bytes/ETA/progress many
/// times while the user is scrolling. Keep the UI tree reading one coarse snapshot rather
/// than several coordinator dictionaries from every row, so progress refreshes do less
/// observation work and row rendering stays value-driven.
public struct OfflineLibrarySnapshot: Sendable, Equatable {
    public static let empty = OfflineLibrarySnapshot(rows: [], queueToolbarAction: nil, isQueuePaused: false,
                                                     aggregateStats: .empty)

    public let rows: [OfflineDownloadRowSnapshot]
    public let queueToolbarAction: DownloadQueueToolbarPolicy.Action?
    public let isQueuePaused: Bool
    public let aggregateStats: OfflineDownloadAggregateStats

    public init(rows: [OfflineDownloadRowSnapshot],
                queueToolbarAction: DownloadQueueToolbarPolicy.Action?,
                isQueuePaused: Bool,
                aggregateStats: OfflineDownloadAggregateStats) {
        self.rows = rows
        self.queueToolbarAction = queueToolbarAction
        self.isQueuePaused = isQueuePaused
        self.aggregateStats = aggregateStats
    }

    public var footerText: String {
        isQueuePaused
            ? "Download queue paused. Resume when you're ready to continue transfers."
            : "Background transfers pause while the headset is off and resume when it's worn again."
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
    public let isCheckpointPausing: Bool

    public init(record: DownloadRecord,
                showBackendBadge: Bool,
                backendName: String,
                errorMessage: String?,
                displayProgress: Double?,
                statusCaption: String,
                isRetrying: Bool,
                isCheckpointPausing: Bool) {
        self.record = record
        self.showBackendBadge = showBackendBadge
        self.backendName = backendName
        self.errorMessage = errorMessage
        self.displayProgress = displayProgress
        self.statusCaption = statusCaption
        self.isRetrying = isRetrying
        self.isCheckpointPausing = isCheckpointPausing
    }

    public var id: String { record.ratingKey }
}
