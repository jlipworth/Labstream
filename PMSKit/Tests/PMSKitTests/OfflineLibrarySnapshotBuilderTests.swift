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
        var record = DownloadRecord(ratingKey: key,
                       attemptID: attemptID,
                       title: key,
                       localURL: URL(fileURLWithPath: "/tmp/\(key).mp4"),
                       bytes: bytes,
                       progress: 0.25,
                       status: status,
                       metadata: metadata,
                       sideAssetBytes: sideAssetBytes)
        if status == .downloading { record.lifecycle = .transferring }
        return record
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
            aggregateSpeedBytesPerSecond: 10.5,
            displayBytes: { record in record.ratingKey == "plex-1" ? 420 : nil },
            errorMessage: { record in record.status == .failed ? "boom" : nil },
            displayProgress: { record in record.ratingKey == "plex-1" ? 0.42 : nil },
            statusCaption: { record, backend in "\(backend.displayName):\(record.status.rawValue)" },
            isRetrying: { $0 == "emby:2" }
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

    @Test("admission requests are running queue work even while persisted paused or failed")
    func waitingRetriesOfferPauseAll() {
        for status in [DownloadStatus.paused, .failed] {
            var waiting = record("waiting", status: status)
            waiting.lifecycle = status == .paused ? .paused : .failed
            waiting.admissionIntent = .retryRequested
            let snapshot = OfflineLibrarySnapshotBuilder.make(
                records: [waiting], isQueuePaused: false,
                aggregateSpeedBytesPerSecond: nil,
                errorMessage: { _ in nil }, displayProgress: { _ in nil },
                statusCaption: { _, _ in "Waiting for a download slot…" },
                isRetrying: { _ in false })
            #expect(snapshot.queueToolbarAction == .pauseQueue)
        }
    }

    @Test("toolbar follows retries and a planned row through pause and resume")
    func toolbarTracksPendingWork() {
        var row = record("planned", status: .queued)
        row.lifecycle = .planned
        row.admissionIntent = .seasonPlanned
        func snapshot(_ row: DownloadRecord, retrying: Bool = false) -> OfflineLibrarySnapshot {
            OfflineLibrarySnapshotBuilder.make(
                records: [row], isQueuePaused: true, aggregateSpeedBytesPerSecond: nil,
                errorMessage: { _ in nil }, displayProgress: { _ in nil },
                statusCaption: { _, _ in "" }, isRetrying: { _ in retrying })
        }
        #expect(snapshot(row).queueToolbarAction == .pauseQueue)
        row.lifecycle = .paused
        row.status = .paused
        // A paused first start retains seasonPlanned as a route, not a pending request.
        #expect(snapshot(row).queueToolbarAction == .resumeQueue)
        #expect(!snapshot(row).rows[0].isWaitingForAdmission)
        row.admissionIntent = nil
        #expect(snapshot(row, retrying: true).queueToolbarAction == .pauseQueue)
        row.status = .downloading
        row.lifecycle = .transferring
        #expect(snapshot(row).queueToolbarAction == .pauseQueue)
    }

    @Test("episode title is derived from lightweight persisted scalars")
    func episodeTitleUsesPersistedScalars() throws {
        let metadata = OfflineMetadata(
            ratingKey: "episode-1", title: "Pilot", type: "episode",
            grandparentTitle: "Example Show", parentIndex: 2, index: 3)
        let snapshot = OfflineLibrarySnapshotBuilder.make(
            records: [record("fallback", status: .complete, metadata: metadata)],
            isQueuePaused: false,
            aggregateSpeedBytesPerSecond: nil,
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
            aggregateSpeedBytesPerSecond: nil,
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
            aggregateSpeedBytesPerSecond: nil,
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
