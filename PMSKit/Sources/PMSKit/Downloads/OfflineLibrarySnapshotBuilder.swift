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
                            trustworthyExpectedBytes: (DownloadRecord) -> Int? = { _ in nil },
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
            let metadata = record.metadata
            let title = offlineRowTitle(recordTitle: record.title, metadata: metadata)
            let subtitle: String? = {
                guard let metadata else { return nil }
                var parts: [String] = []
                if let year = metadata.year { parts.append(String(year)) }
                if let duration = metadata.duration, duration > 0 {
                    parts.append("\(max(1, duration / 60_000)) min")
                }
                if let rating = metadata.contentRating, !rating.isEmpty { parts.append(rating) }
                return parts.isEmpty ? nil : parts.joined(separator: " • ")
            }()
            let artwork = record.posterURL.flatMap { url in
                metadata?.sideAssetBundleOwner.map {
                    OfflineArtworkPresentation(fileURL: url, backend: backend, owner: $0,
                                               generation: metadata?.posterGeneration ?? 0)
                }
            }
            return OfflineDownloadRowSnapshot(
                id: record.ratingKey,
                attemptID: record.attemptID,
                title: title,
                subtitle: subtitle,
                qualityText: DownloadRowDisplayPolicy.downloadQualityText(for: record),
                status: record.status,
                routeBadge: DownloadRowDisplayPolicy.routeBadge(for: record),
                artwork: artwork,
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

        let activeSamples = records.map { record in
            OfflineActiveTransferPercentage.Sample(
                status: record.status,
                transferredBytes: max(record.bytes, displayBytesByRatingKey[record.ratingKey] ?? 0),
                trustworthyExpectedBytes: trustworthyExpectedBytes(record)
            )
        }
        let activeTransferPercentage = OfflineActiveTransferPercentage.integerPercent(activeSamples)

        return OfflineLibrarySnapshot(
            rows: rows,
            queueToolbarAction: DownloadQueueToolbarPolicy.action(
                isQueuePaused: isQueuePaused,
                statuses: records.map(\.status)
            ),
            isQueuePaused: isQueuePaused,
            aggregateStats: OfflineDownloadAggregateStats.make(records: records,
                                                               speedsByRatingKey: downloadSpeed,
                                                               displayBytesByRatingKey: displayBytesByRatingKey),
            activeTransferPercentage: activeTransferPercentage,
            sidebarStatus: OfflineSidebarStatusPolicy.presentation(activeSamples)
        )
    }

    /// Derive the episode label from the persisted scalars needed by the row. Reconstructing a
    /// full `MediaItem` here copied chapters, markers, and other playback-only metadata for every
    /// progress publication; full-record reconstruction remains at the playback/retry edge.
    private static func offlineRowTitle(recordTitle: String, metadata: OfflineMetadata?) -> String {
        guard let metadata, metadata.type == "episode" else { return recordTitle }
        var parts: [String] = []
        if let show = metadata.grandparentTitle, !show.isEmpty { parts.append(show) }
        switch (metadata.parentIndex, metadata.index) {
        case let (season?, episode?): parts.append("S\(season)E\(episode)")
        case let (season?, nil): parts.append("S\(season)")
        case let (nil, episode?): parts.append("E\(episode)")
        case (nil, nil): break
        }
        if !metadata.title.isEmpty { parts.append(metadata.title) }
        return parts.isEmpty ? metadata.title : parts.joined(separator: " · ")
    }
}
