import Foundation
import Testing
@testable import PMSKit

@Suite("Offline library snapshot builder")
struct OfflineLibrarySnapshotBuilderTests {
    private func record(_ key: String,
                        status: DownloadStatus,
                        bytes: Int = 0,
                        sideAssetBytes: Int = 0) -> DownloadRecord {
        DownloadRecord(ratingKey: key,
                       title: key,
                       localURL: URL(fileURLWithPath: "/tmp/\(key).mp4"),
                       bytes: bytes,
                       progress: 0.25,
                       status: status,
                       sideAssetBytes: sideAssetBytes)
    }

    @Test("builder derives mixed-backend rows, queue action, aggregate stats, and overlays")
    func builderDerivesRowsAndGlobalState() throws {
        let records = [
            record("plex-1", status: .downloading, bytes: 120, sideAssetBytes: 5),
            record("emby:2", status: .failed, bytes: 30),
        ]

        let snapshot = OfflineLibrarySnapshotBuilder.make(
            records: records,
            isQueuePaused: false,
            downloadSpeed: ["plex-1": 10.5, "emby:2": 100],
            displayBytes: { record in record.ratingKey == "plex-1" ? 420 : nil },
            errorMessage: { record in record.status == .failed ? "boom" : nil },
            displayProgress: { record in record.ratingKey == "plex-1" ? 0.42 : nil },
            statusCaption: { record, backend in "\(backend.displayName):\(record.status.rawValue)" },
            isRetrying: { $0 == "emby:2" },
            isCheckpointPausing: { $0 == "plex-1" }
        )

        #expect(snapshot.queueToolbarAction == .pauseQueue)
        #expect(snapshot.isQueuePaused == false)
        #expect(snapshot.aggregateStats.downloadedBytes == 455)
        #expect(snapshot.aggregateStats.activeSpeedBytesPerSecond == 10.5)
        #expect(snapshot.ratingKeys == ["plex-1", "emby:2"])
        #expect(snapshot.footerText.contains("Background transfers are best-effort"))

        let plexRow = try #require(snapshot.rows.first)
        #expect(plexRow.showBackendBadge)
        #expect(plexRow.backendName == "Plex")
        #expect(plexRow.displayProgress == 0.42)
        #expect(plexRow.statusCaption == "Plex:downloading")
        #expect(plexRow.errorMessage == nil)
        #expect(plexRow.isRetrying == false)
        #expect(plexRow.isCheckpointPausing)

        let embyRow = try #require(snapshot.rows.last)
        #expect(embyRow.showBackendBadge)
        #expect(embyRow.backendName == "Emby")
        #expect(embyRow.errorMessage == "boom")
        #expect(embyRow.statusCaption == "Emby:failed")
        #expect(embyRow.isRetrying)
        #expect(embyRow.isCheckpointPausing == false)
    }

    @Test("single-backend paused snapshot hides badges and exposes resume footer")
    func singleBackendPausedSnapshotHidesBadges() throws {
        let snapshot = OfflineLibrarySnapshotBuilder.make(
            records: [record("jellyfin:1", status: .paused, bytes: 1)],
            isQueuePaused: true,
            downloadSpeed: [:],
            errorMessage: { _ in nil },
            displayProgress: { _ in nil },
            statusCaption: { _, _ in "Paused" },
            isRetrying: { _ in false },
            isCheckpointPausing: { _ in false }
        )

        #expect(snapshot.queueToolbarAction == .resumeQueue)
        #expect(snapshot.footerText.contains("Download queue paused"))
        let row = try #require(snapshot.rows.first)
        #expect(row.showBackendBadge == false)
        #expect(row.backendName == "Jellyfin")
        #expect(row.statusCaption == "Paused")
    }
}
