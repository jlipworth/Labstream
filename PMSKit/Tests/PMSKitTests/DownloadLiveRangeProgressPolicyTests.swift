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

    @Test("Merging keeps live display bytes monotonic")
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

        let lower = DownloadLiveRangeProgressPolicy.mergedSample(liveBytes: 150,
                                                                 expectedBytes: nil,
                                                                 previous: higher,
                                                                 updatedAt: now.addingTimeInterval(2))
        #expect(lower.bytes == 250)
        #expect(lower.expectedBytes == 1_000)
    }

    @Test("Live display bytes require forward progress on an active downloading row")
    func liveDisplayBytes() {
        let now = Date(timeIntervalSince1970: 2_000)
        let fresh = DownloadLiveRangeProgressSample(bytes: 150, expectedBytes: nil, updatedAt: now.addingTimeInterval(-15))
        let stale = DownloadLiveRangeProgressSample(bytes: 150, expectedBytes: nil, updatedAt: now.addingTimeInterval(-16))

        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(),
                                                                 sample: fresh,
                                                                 now: now) == 150)
        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(),
                                                                 sample: stale,
                                                                 now: now) == 150)
        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(bytes: 150),
                                                                 sample: fresh,
                                                                 now: now) == nil)
        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(status: .paused),
                                                                 sample: fresh,
                                                                 now: now) == nil)
    }

    @Test("Resume display watermark rebases fresh-baseline counts without double-counting the base offset")
    func resumedTaskDisplayBytes() {
        // Fresh-baseline report: taskBytes = baseOffset + bytes THIS task instance received.
        // The watermark already covers baseOffset + the blob temp, so only the fresh delta is added.
        #expect(DownloadLiveRangeProgressPolicy.displayBytesForResumedTask(
            taskBytes: 100_002_000,
            baseOffset: 100_000_000,
            resumeDisplayBytes: 150_000_000) == 150_002_000)
        // A report with no fresh bytes yet holds at the watermark instead of inflating past it.
        #expect(DownloadLiveRangeProgressPolicy.displayBytesForResumedTask(
            taskBytes: 100_000_000,
            baseOffset: 100_000_000,
            resumeDisplayBytes: 150_000_000) == 150_000_000)
        // Cumulative reports at/above the watermark are already authoritative.
        #expect(DownloadLiveRangeProgressPolicy.displayBytesForResumedTask(
            taskBytes: 250_000_000,
            baseOffset: 100_000_000,
            resumeDisplayBytes: 200_000_000) == 250_000_000)
        #expect(DownloadLiveRangeProgressPolicy.displayBytesForResumedTask(
            taskBytes: 0,
            baseOffset: 100_000_000,
            resumeDisplayBytes: 200_000_000) == 200_000_000)
        #expect(DownloadLiveRangeProgressPolicy.displayBytesForResumedTask(
            taskBytes: 2_000,
            baseOffset: 0,
            resumeDisplayBytes: nil) == 2_000)
    }
}
