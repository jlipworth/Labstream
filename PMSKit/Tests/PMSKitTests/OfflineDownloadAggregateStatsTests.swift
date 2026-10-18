import Foundation
import Testing
@testable import PMSKit

@Suite("Offline download aggregate stats")
struct OfflineDownloadAggregateStatsTests {
    private func record(_ key: String,
                        status: DownloadStatus,
                        bytes: Int = 0,
                        sideAssetBytes: Int = 0) -> DownloadRecord {
        var record = DownloadRecord(ratingKey: key,
                       title: key,
                       localURL: URL(fileURLWithPath: "/tmp/\(key).mp4"),
                       bytes: bytes,
                       progress: 0,
                       status: status,
                       sideAssetBytes: sideAssetBytes)
        if status == .downloading { record.lifecycle = .transferring }
        return record
    }

    @Test("no downloads produce no visible aggregate metrics")
    func emptyAggregatesAreQuiet() {
        let stats = OfflineDownloadAggregateStats.make(records: [] as [DownloadRecord],
                                                       activeSpeedBytesPerSecond: nil)
        #expect(stats == .empty)
        #expect(stats.hasVisibleMetrics == false)
    }

    @Test("downloaded total includes complete and partial local bytes")
    func downloadedTotalIncludesCompleteAndPartialRows() {
        let rows = [
            record("complete", status: .complete, bytes: 1_000, sideAssetBytes: 25),
            record("paused", status: .paused, bytes: 200),
            record("downloading", status: .downloading, bytes: 300, sideAssetBytes: 10),
            record("failed", status: .failed, bytes: 40),
            record("preparing", status: .preparing, bytes: 0),
        ]

        let stats = OfflineDownloadAggregateStats.make(records: rows,
                                                       activeSpeedBytesPerSecond: 12.5)

        #expect(stats.downloadedBytes == 1_575)
        #expect(stats.activeSpeedBytesPerSecond == 12.5)
        #expect(stats.hasVisibleMetrics)
    }

    @Test("active live display bytes override durable checkpoint bytes")
    func activeLiveDisplayBytesOverrideDurableCheckpointBytes() {
        let rows = [
            record("downloading", status: .downloading, bytes: 256, sideAssetBytes: 10),
            record("paused", status: .paused, bytes: 128)
        ]

        let stats = OfflineDownloadAggregateStats.make(records: rows,
                                                       activeSpeedBytesPerSecond: nil,
                                                       displayBytesByRatingKey: [
                                                           "downloading": 5_500,
                                                           "paused": 64
                                                       ])

        #expect(stats.downloadedBytes == 5_638)
    }

    @Test("active speed consumes the shared-window batch measurement")
    func activeSpeedUsesSharedMeasurement() {
        let rows = [
            record("queued", status: .queued, bytes: 10),
            record("preparing", status: .preparing, bytes: 0),
            record("downloading", status: .downloading, bytes: 20),
            record("paused", status: .paused, bytes: 30),
            record("complete", status: .complete, bytes: 40),
        ]

        let stats = OfflineDownloadAggregateStats.make(records: rows, activeSpeedBytesPerSecond: 2.75)

        #expect(stats.activeSpeedBytesPerSecond == 2.75)
        #expect(stats.downloadedBytes == 100)
    }

    @Test("active rows without a valid batch rate show updating speed")
    func missingRateShowsUpdatingSpeed() {
        let rows = [
            record("queued", status: .queued, bytes: 0),
            record("downloading", status: .downloading, bytes: 0),
        ]

        let stats = OfflineDownloadAggregateStats.make(records: rows,
                                                       activeSpeedBytesPerSecond: -1)

        #expect(stats.activeSpeedBytesPerSecond == nil)
        #expect(stats.downloadedBytes == 0)
        #expect(stats.isUpdatingSpeed)
        #expect(stats.hasVisibleMetrics)
    }

    @Test("preparation and finalization do not keep the aggregate speed visible")
    func nonTransfersHaveNoSpeed() {
        var finalizing = record("finalizing", status: .downloading)
        finalizing.lifecycle = .finalizing
        let stats = OfflineDownloadAggregateStats.make(records: [
            record("queued", status: .queued), record("preparing", status: .preparing), finalizing
        ], activeSpeedBytesPerSecond: 100)
        #expect(stats.activeSpeedBytesPerSecond == nil)
        #expect(!stats.isUpdatingSpeed)
    }

    @Test("a fully observed stalled batch can display zero")
    func measuredZeroIsNotMissingEvidence() {
        let stats = OfflineDownloadAggregateStats.make(
            records: [record("active", status: .downloading)], activeSpeedBytesPerSecond: 0)
        #expect(stats.activeSpeedBytesPerSecond == 0)
        #expect(!stats.isUpdatingSpeed)
    }

    @Test("missing and invalid measurements keep the updating indicator visible",
          arguments: [nil, -1, Double.nan, Double.infinity] as [Double?])
    func invalidMeasurementIsUpdating(speed: Double?) {
        let stats = OfflineDownloadAggregateStats.make(
            records: [record("active", status: .downloading)], activeSpeedBytesPerSecond: speed)
        #expect(stats.activeSpeedBytesPerSecond == nil)
        #expect(stats.isUpdatingSpeed)
    }
}
