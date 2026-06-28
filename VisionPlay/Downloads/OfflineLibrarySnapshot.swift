import Foundation
import PMSKit

/// Pre-derived data for `OfflineLibraryView`.
///
/// The downloads screen is a hot UI: transfer callbacks can update bytes/ETA/progress many
/// times while the user is scrolling. Keep the SwiftUI tree reading one coarse snapshot rather
/// than several `DownloadManager` dictionaries from every row, so progress refreshes do less
/// observation work and row rendering stays value-driven.
struct OfflineLibrarySnapshot {
    static let empty = OfflineLibrarySnapshot(rows: [], queueToolbarAction: nil, isQueuePaused: false,
                                               aggregateStats: .empty)

    let rows: [OfflineDownloadRowSnapshot]
    let queueToolbarAction: DownloadQueueToolbarPolicy.Action?
    let isQueuePaused: Bool
    let aggregateStats: OfflineDownloadAggregateStats

    var footerText: String {
        isQueuePaused
            ? "Download queue paused. Resume when you're ready to continue transfers."
            : "Background transfers pause while the headset is off and resume when it's worn again."
    }

    var ratingKeys: [String] { rows.map(\.id) }
}

struct OfflineDownloadRowSnapshot: Identifiable {
    let record: DownloadRecord
    let showBackendBadge: Bool
    let backendName: String
    let errorMessage: String?
    let displayProgress: Double?
    let statusCaption: String
    let isRetrying: Bool

    var id: String { record.ratingKey }
}
