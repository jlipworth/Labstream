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
                                                     activeTransferPercentage: nil,
                                                     sidebarStatus: nil)

    public let rows: [OfflineDownloadRowSnapshot]
    public let queueToolbarAction: DownloadQueueToolbarPolicy.Action?
    public let isQueuePaused: Bool
    public let aggregateStats: OfflineDownloadAggregateStats
    public let activeTransferPercentage: Int?
    public let sidebarStatus: OfflineSidebarStatusPolicy.Presentation?

    public init(rows: [OfflineDownloadRowSnapshot],
                queueToolbarAction: DownloadQueueToolbarPolicy.Action?,
                isQueuePaused: Bool,
                aggregateStats: OfflineDownloadAggregateStats,
                activeTransferPercentage: Int? = nil,
                sidebarStatus: OfflineSidebarStatusPolicy.Presentation? = nil) {
        self.rows = rows
        self.queueToolbarAction = queueToolbarAction
        self.isQueuePaused = isQueuePaused
        self.aggregateStats = aggregateStats
        self.activeTransferPercentage = activeTransferPercentage
        self.sidebarStatus = sidebarStatus
    }

    public var footerText: String {
        isQueuePaused
            ? "Download queue paused. Resume when you're ready to continue queued transfers."
            : "Background transfers are best-effort. Keep this device on power and reopen Labstream to let downloads resume and checkpoint."
    }

    public var ratingKeys: [String] { rows.map(\.id) }
}

public struct OfflineDownloadRowSnapshot: Identifiable, Sendable, Equatable {
    public let id: String
    public let attemptID: DownloadAttemptID?
    public let title: String
    public let subtitle: String?
    public let qualityText: String?
    public let status: DownloadStatus
    public let routeBadge: DownloadRowDisplayPolicy.RouteBadge
    public let artwork: OfflineArtworkPresentation?
    public let showBackendBadge: Bool
    public let backendName: String
    public let errorMessage: String?
    public let displayProgress: Double?
    public let statusCaption: String
    public let isRetrying: Bool

    public init(id: String,
                attemptID: DownloadAttemptID?,
                title: String,
                subtitle: String?,
                qualityText: String?,
                status: DownloadStatus,
                routeBadge: DownloadRowDisplayPolicy.RouteBadge,
                artwork: OfflineArtworkPresentation?,
                showBackendBadge: Bool,
                backendName: String,
                errorMessage: String?,
                displayProgress: Double?,
                statusCaption: String,
                isRetrying: Bool) {
        self.id = id
        self.attemptID = attemptID
        self.title = title
        self.subtitle = subtitle
        self.qualityText = qualityText
        self.status = status
        self.routeBadge = routeBadge
        self.artwork = artwork
        self.showBackendBadge = showBackendBadge
        self.backendName = backendName
        self.errorMessage = errorMessage
        self.displayProgress = displayProgress
        self.statusCaption = statusCaption
        self.isRetrying = isRetrying
    }

    public var isComplete: Bool { status == .complete || status == .unverified }
    public var isUnverified: Bool { status == .unverified }

    /// Exact persisted owner captured when this rendered row was built. Row actions carry this
    /// value back to the manager so a tap from an overtaken SwiftUI render cannot act on a newer
    /// retry/re-download that happens to reuse the same rating key.
    public var actionIdentity: OfflineDownloadRowActionIdentity {
        OfflineDownloadRowActionIdentity(ratingKey: id, attemptID: attemptID)
    }
}

public struct OfflineDownloadRowActionIdentity: Sendable, Equatable {
    public let ratingKey: String
    public let attemptID: DownloadAttemptID?

    public init(ratingKey: String, attemptID: DownloadAttemptID?) {
        self.ratingKey = ratingKey
        self.attemptID = attemptID
    }
}

/// Credential-free artwork identity carried by the presentation snapshot. It is deliberately
/// smaller than `OfflineMetadata`; action/playback paths resolve the current full record by id.
public struct OfflineArtworkPresentation: Sendable, Equatable {
    public let fileURL: URL
    public let backend: DownloadBackendKind
    public let owner: OfflineSideAssetBundleOwner
    public let generation: UInt64

    public init(fileURL: URL, backend: DownloadBackendKind,
                owner: OfflineSideAssetBundleOwner, generation: UInt64) {
        self.fileURL = fileURL
        self.backend = backend
        self.owner = owner
        self.generation = generation
    }
}
