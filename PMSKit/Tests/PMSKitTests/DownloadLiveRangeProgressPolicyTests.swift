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

    @Test("Aggregated live bytes sum durable plus every live segment body")
    func aggregatedLiveBytesSumsSegments() {
        // Multi-segment train: durable partial plus three still-in-flight segment bodies.
        #expect(DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: 1_000,
            liveSegmentBodyBytes: [500, 300, 200]) == 2_000)
        // Single-segment (openEndedRemainder) case: durableBytes == baseOffset by construction, so
        // this must equal the historical `baseOffset + bodyBytesWritten` total exactly.
        #expect(DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: 100_000,
            liveSegmentBodyBytes: [4_096]) == 104_096)
        // No live segments (all finished/none started yet): just the durable checkpoint.
        #expect(DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: 1_000,
            liveSegmentBodyBytes: []) == 1_000)
        // Defensive clamping against negative inputs.
        #expect(DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: -5,
            liveSegmentBodyBytes: [-10, 50]) == 50)
    }

    @Test("Segment completion transition never dips the published live sample")
    func segmentCompletionTransitionMonotonic() {
        let now = Date(timeIntervalSince1970: 3_000)
        // Two segments in flight: durable partial 1_000, segment A at 600 bytes, segment B at 100.
        let beforeCompletion = DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: 1_000,
            liveSegmentBodyBytes: [600, 100])
        #expect(beforeCompletion == 1_700)
        let sampleBeforeCompletion = DownloadLiveRangeProgressPolicy.mergedSample(
            liveBytes: beforeCompletion, expectedBytes: 10_000, previous: nil, updatedAt: now)

        // Segment A finishes: it leaves the live set (finishRangeRemainder removes it from
        // rangeInflight) BEFORE the async append lands, so durable hasn't grown yet at the instant
        // the next callback for segment B fires. The raw aggregate would dip to 1_100 (durable
        // 1_000 + segment B's 100) — but merging against the previous sample must clamp it.
        let duringAppendWindow = DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: 1_000,
            liveSegmentBodyBytes: [100])
        #expect(duringAppendWindow == 1_100)
        let sampleDuringAppendWindow = DownloadLiveRangeProgressPolicy.mergedSample(
            liveBytes: duringAppendWindow, expectedBytes: 10_000,
            previous: sampleBeforeCompletion, updatedAt: now.addingTimeInterval(0.2))
        #expect(sampleDuringAppendWindow.bytes == 1_700, "published sample must not dip below the prior peak")

        // Once the async append lands, durable jumps to cover segment A's full 700 bytes plus the
        // pre-existing 1_000 (1_700 total from durable alone), and segment B keeps accumulating.
        let afterAppend = DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: 1_700,
            liveSegmentBodyBytes: [150])
        #expect(afterAppend == 1_850)
        let sampleAfterAppend = DownloadLiveRangeProgressPolicy.mergedSample(
            liveBytes: afterAppend, expectedBytes: 10_000,
            previous: sampleDuringAppendWindow, updatedAt: now.addingTimeInterval(0.4))
        #expect(sampleAfterAppend.bytes == 1_850)
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
