import Foundation
import Testing
@testable import PMSKit

@Suite("Offline download aggregate stats")
struct OfflineDownloadAggregateStatsTests {
    private func record(_ key: String,
                        status: DownloadStatus,
                        bytes: Int = 0) -> DownloadRecord {
        DownloadRecord(ratingKey: key,
                       title: key,
                       localURL: URL(fileURLWithPath: "/tmp/\(key).mp4"),
                       bytes: bytes,
                       progress: 0,
                       status: status)
    }

    @Test("no downloads produce no visible aggregate metrics")
    func emptyAggregatesAreQuiet() {
        let stats = OfflineDownloadAggregateStats.make(records: [] as [DownloadRecord],
                                                       speedsByRatingKey: [:])
        #expect(stats == .empty)
        #expect(stats.hasVisibleMetrics == false)
    }

    @Test("downloaded total includes complete and partial local bytes")
    func downloadedTotalIncludesCompleteAndPartialRows() {
        let rows = [
            record("complete", status: .complete, bytes: 1_000),
            record("paused", status: .paused, bytes: 200),
            record("downloading", status: .downloading, bytes: 300),
            record("failed", status: .failed, bytes: 40),
            record("preparing", status: .preparing, bytes: 0),
        ]

        let stats = OfflineDownloadAggregateStats.make(records: rows,
                                                       speedsByRatingKey: ["downloading": 12.5])

        #expect(stats.downloadedBytes == 1_540)
        #expect(stats.activeSpeedBytesPerSecond == 12.5)
        #expect(stats.hasVisibleMetrics)
    }

    @Test("active speed sums measured active rows only")
    func activeSpeedSumsActiveMeasuredRowsOnly() {
        let rows = [
            record("queued", status: .queued, bytes: 10),
            record("preparing", status: .preparing, bytes: 0),
            record("downloading", status: .downloading, bytes: 20),
            record("paused", status: .paused, bytes: 30),
            record("complete", status: .complete, bytes: 40),
        ]

        let stats = OfflineDownloadAggregateStats.make(records: rows, speedsByRatingKey: [
            "queued": 1.25,
            "preparing": 0,
            "downloading": 2.75,
            "paused": 100,
            "complete": 200,
        ])

        #expect(stats.activeSpeedBytesPerSecond == 4.0)
        #expect(stats.downloadedBytes == 100)
    }

    @Test("active rows without measured rates do not show zero speed")
    func missingRatesDoNotShowZeroSpeed() {
        let rows = [
            record("queued", status: .queued, bytes: 0),
            record("downloading", status: .downloading, bytes: 0),
        ]

        let stats = OfflineDownloadAggregateStats.make(records: rows,
                                                       speedsByRatingKey: ["queued": 0, "downloading": -1])

        #expect(stats.activeSpeedBytesPerSecond == nil)
        #expect(stats.downloadedBytes == 0)
        #expect(stats.hasVisibleMetrics == false)
    }
}
