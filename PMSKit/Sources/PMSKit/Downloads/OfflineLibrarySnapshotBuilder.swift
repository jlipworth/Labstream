import Foundation

/// Pure builder for the coarse value consumed by the offline downloads UI.
///
/// The app coordinator remains the owner of live state and backend availability, but this builder
/// centralizes row aggregation: mixed-backend badge detection, row assembly, queue toolbar policy,
/// and aggregate metrics. Keeping this in PMSKit narrows the UI publication seam and pins the
/// backend/lane semantics with ordinary package tests.
public enum OfflineLibrarySnapshotBuilder {
    public static func make(records: [DownloadRecord],
                            isQueuePaused: Bool,
                            downloadSpeed: [String: Double],
                            displayBytes: (DownloadRecord) -> Int? = { _ in nil },
                            errorMessage: (DownloadRecord) -> String?,
                            displayProgress: (DownloadRecord) -> Double?,
                            statusCaption: (DownloadRecord, DownloadBackendKind) -> String,
                            isRetrying: (String) -> Bool) -> OfflineLibrarySnapshot {
        let backendsByKey = Dictionary(uniqueKeysWithValues: records.map { record in
            (record.ratingKey, DownloadJobSnapshot(record: record).backend)
        })
        let hasMixedBackends = Set(backendsByKey.values.map(\.rawValue)).count > 1

        let rows = records.map { record in
            let backend = backendsByKey[record.ratingKey] ?? DownloadJobSnapshot(record: record).backend
            return OfflineDownloadRowSnapshot(
                record: record,
                showBackendBadge: hasMixedBackends,
                backendName: backend.displayName,
                errorMessage: errorMessage(record),
                displayProgress: displayProgress(record),
                statusCaption: statusCaption(record, backend),
                isRetrying: isRetrying(record.ratingKey)
            )
        }

        let displayBytesByRatingKey = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            displayBytes(record).map { (record.ratingKey, $0) }
        })

        return OfflineLibrarySnapshot(
            rows: rows,
            queueToolbarAction: DownloadQueueToolbarPolicy.action(
                isQueuePaused: isQueuePaused,
                statuses: records.map(\.status)
            ),
            isQueuePaused: isQueuePaused,
            aggregateStats: OfflineDownloadAggregateStats.make(records: records,
                                                               speedsByRatingKey: downloadSpeed,
                                                               displayBytesByRatingKey: displayBytesByRatingKey)
        )
    }
}
