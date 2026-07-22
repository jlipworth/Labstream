import Foundation
import Testing
@testable import PMSKit

@Suite("Offline library snapshot builder")
struct OfflineLibrarySnapshotBuilderTests {
    private func record(_ key: String,
                        status: DownloadStatus,
                        bytes: Int = 0,
                        sideAssetBytes: Int = 0,
                        attemptID: DownloadAttemptID? = nil,
                        metadata: OfflineMetadata? = nil) -> DownloadRecord {
        DownloadRecord(ratingKey: key,
                       attemptID: attemptID,
                       title: key,
                       localURL: URL(fileURLWithPath: "/tmp/\(key).mp4"),
                       bytes: bytes,
                       progress: 0.25,
                       status: status,
                       metadata: metadata,
                       sideAssetBytes: sideAssetBytes)
    }

    @Test("builder derives mixed-backend rows, queue action, aggregate stats, and overlays")
    func builderDerivesRowsAndGlobalState() throws {
        let records = [
            record("plex-1", status: .downloading, bytes: 120, sideAssetBytes: 5,
                   attemptID: DownloadAttemptID(rawValue: "attempt-a")),
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
            isRetrying: { $0 == "emby:2" }
        )

        #expect(snapshot.queueToolbarAction == .resumeQueue)
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
        #expect(plexRow.id == "plex-1")
        #expect(plexRow.attemptID?.rawValue == "attempt-a")
        #expect(plexRow.actionIdentity == OfflineDownloadRowActionIdentity(
            ratingKey: "plex-1", attemptID: DownloadAttemptID(rawValue: "attempt-a")))
        #expect(plexRow.title == "plex-1")
        #expect(plexRow.status == .downloading)
        #expect(plexRow.routeBadge == .original)

        let embyRow = try #require(snapshot.rows.last)
        #expect(embyRow.showBackendBadge)
        #expect(embyRow.backendName == "Emby")
        #expect(embyRow.errorMessage == "boom")
        #expect(embyRow.statusCaption == "Emby:failed")
        #expect(embyRow.isRetrying)
    }

    @Test("episode title is derived from lightweight persisted scalars")
    func episodeTitleUsesPersistedScalars() throws {
        let metadata = OfflineMetadata(
            ratingKey: "episode-1", title: "Pilot", type: "episode",
            grandparentTitle: "Example Show", parentIndex: 2, index: 3)
        let snapshot = OfflineLibrarySnapshotBuilder.make(
            records: [record("fallback", status: .complete, metadata: metadata)],
            isQueuePaused: false,
            downloadSpeed: [:],
            errorMessage: { _ in nil },
            displayProgress: { _ in nil },
            statusCaption: { _, _ in "Downloaded" },
            isRetrying: { _ in false })

        #expect(try #require(snapshot.rows.first).title == "Example Show · S2E3 · Pilot")
    }

    @Test("snapshot aggregate uses paused resumable display bytes")
    func snapshotAggregateUsesPausedResumableDisplayBytes() {
        let paused = record("plex-1", status: .paused, bytes: 270, sideAssetBytes: 20)
        let snapshot = OfflineLibrarySnapshotBuilder.make(
            records: [paused],
            isQueuePaused: false,
            downloadSpeed: [:],
            displayBytes: { $0.ratingKey == "plex-1" ? 5_500 : nil },
            errorMessage: { _ in nil },
            displayProgress: { _ in 0.35 },
            statusCaption: { _, _ in "Paused • 35% • 5.5 KB" },
            isRetrying: { _ in false })

        #expect(snapshot.aggregateStats.downloadedBytes == 5_520)
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
            isRetrying: { _ in false }
        )

        #expect(snapshot.queueToolbarAction == .resumeQueue)
        #expect(snapshot.footerText.contains("Download queue paused"))
        let row = try #require(snapshot.rows.first)
        #expect(row.showBackendBadge == false)
        #expect(row.backendName == "Jellyfin")
        #expect(row.statusCaption == "Paused")
    }
}
