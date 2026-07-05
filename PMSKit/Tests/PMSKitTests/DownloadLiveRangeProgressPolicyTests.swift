import Foundation
import Testing
@testable import PMSKit

@Suite("Download live range progress policy")
struct DownloadLiveRangeProgressPolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-live-range.mp4")

    private func record(status: DownloadStatus = .downloading, bytes: Int = 100) -> DownloadRecord {
        DownloadRecord(ratingKey: DownloadRecordIdentity.recordKey(for: "item", backend: .jellyfin),
                       title: "Title",
                       localURL: url,
                       bytes: bytes,
                       progress: 0,
                       status: status)
    }

    @Test("Merging keeps monotonic bytes within a chunk and lower re-baselines")
    func mergedSampleBytes() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = DownloadLiveRangeProgressPolicy.mergedSample(liveBytes: 200,
                                                                 expectedBytes: 1_000,
                                                                 previous: nil,
                                                                 updatedAt: now)
        #expect(first.bytes == 200)
        #expect(first.expectedBytes == 1_000)

        let higher = DownloadLiveRangeProgressPolicy.mergedSample(liveBytes: 250,
                                                                  expectedBytes: nil,
                                                                  previous: first,
                                                                  updatedAt: now.addingTimeInterval(1))
        #expect(higher.bytes == 250)
        #expect(higher.expectedBytes == 1_000)

        let rebaselined = DownloadLiveRangeProgressPolicy.mergedSample(liveBytes: 150,
                                                                       expectedBytes: nil,
                                                                       previous: higher,
                                                                       updatedAt: now.addingTimeInterval(2))
        #expect(rebaselined.bytes == 150)
        #expect(rebaselined.expectedBytes == 1_000)
    }

    @Test("Live display bytes require fresh forward progress on an active or pausing row")
    func liveDisplayBytes() {
        let now = Date(timeIntervalSince1970: 2_000)
        let fresh = DownloadLiveRangeProgressSample(bytes: 150, expectedBytes: nil, updatedAt: now.addingTimeInterval(-15))
        let stale = DownloadLiveRangeProgressSample(bytes: 150, expectedBytes: nil, updatedAt: now.addingTimeInterval(-16))

        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(),
                                                                 sample: fresh,
                                                                 now: now,
                                                                 isCheckpointPausing: false) == 150)
        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(status: .paused),
                                                                 sample: fresh,
                                                                 now: now,
                                                                 isCheckpointPausing: true) == 150)
        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(),
                                                                 sample: stale,
                                                                 now: now,
                                                                 isCheckpointPausing: false) == nil)
        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(bytes: 150),
                                                                 sample: fresh,
                                                                 now: now,
                                                                 isCheckpointPausing: false) == nil)
        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(status: .paused),
                                                                 sample: fresh,
                                                                 now: now,
                                                                 isCheckpointPausing: false) == nil)
    }
}
