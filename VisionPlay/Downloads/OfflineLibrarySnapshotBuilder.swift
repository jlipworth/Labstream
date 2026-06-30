import Foundation
import PMSKit

/// App-layer builder for the coarse value consumed by `OfflineLibraryView`.
///
/// `DownloadManager` remains the owner of live coordinator state and backend availability, but this
/// builder centralizes row aggregation: mixed-backend badge detection, row assembly, queue toolbar
/// policy, and aggregate metrics. Keeping this separate from the coordinator narrows the hot UI
/// publication seam without moving app-only state into PMSKit.
@MainActor
struct OfflineLibrarySnapshotBuilder {
    static func make(records: [DownloadRecord],
                     isQueuePaused: Bool,
                     downloadSpeed: [String: Double],
                     backendKind: (DownloadRecord) -> DownloadBackendKind,
                     errorMessage: (DownloadRecord) -> String?,
                     displayProgress: (DownloadRecord) -> Double?,
                     statusCaption: (DownloadRecord, DownloadBackendKind) -> String,
                     isRetrying: (String) -> Bool,
                     isCheckpointPausing: (String) -> Bool) -> OfflineLibrarySnapshot {
        let backendsByKey = Dictionary(uniqueKeysWithValues: records.map { record in
            (record.ratingKey, backendKind(record))
        })
        let hasMixedBackends = Set(backendsByKey.values.map(\.rawValue)).count > 1

        let rows = records.map { record in
            let backend = backendsByKey[record.ratingKey] ?? backendKind(record)
            return OfflineDownloadRowSnapshot(
                record: record,
                showBackendBadge: hasMixedBackends,
                backendName: backend.displayName,
                errorMessage: errorMessage(record),
                displayProgress: displayProgress(record),
                statusCaption: statusCaption(record, backend),
                isRetrying: isRetrying(record.ratingKey),
                isCheckpointPausing: isCheckpointPausing(record.ratingKey)
            )
        }

        return OfflineLibrarySnapshot(
            rows: rows,
            queueToolbarAction: DownloadQueueToolbarPolicy.action(
                isQueuePaused: isQueuePaused,
                statuses: records.map(\.status)
            ),
            isQueuePaused: isQueuePaused,
            aggregateStats: OfflineDownloadAggregateStats.make(records: records,
                                                               speedsByRatingKey: downloadSpeed)
        )
    }
}
