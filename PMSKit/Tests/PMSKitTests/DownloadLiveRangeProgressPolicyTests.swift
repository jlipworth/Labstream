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

    @Test("Closed segment accounting caps replayed task counters at planned length")
    func capsClosedSegmentTaskCounters() {
        let segment = 64 * 1_024 * 1_024
        #expect(DownloadLiveRangeProgressPolicy.accountedTaskBodyBytes(
            reportedBytes: 4_991_033_070,
            segmentLength: segment) == segment)
        #expect(DownloadLiveRangeProgressPolicy.accountedTaskBodyBytes(
            reportedBytes: segment / 2,
            segmentLength: segment) == segment / 2)
        #expect(DownloadLiveRangeProgressPolicy.accountedTaskBodyBytes(
            reportedBytes: 4_991_033_070,
            segmentLength: nil) == 4_991_033_070)
        #expect(DownloadLiveRangeProgressPolicy.accountedTaskBodyBytes(
            reportedBytes: -1,
            segmentLength: segment) == 0)
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
        // Samples have no time-based staleness — an old sample is displayed for as long as the
        // row stays `.downloading` (a suspended app receives no callbacks while the background
        // session keeps writing); status transitions are what remove samples.
        let old = DownloadLiveRangeProgressSample(
            bytes: 150, expectedBytes: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000))

        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(),
                                                                 sample: old) == 150)
        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(bytes: 150),
                                                                 sample: old) == nil)
        #expect(DownloadLiveRangeProgressPolicy.liveDisplayBytes(for: record(status: .paused),
                                                                 sample: old) == nil)
    }

    @Test("Aggregated live bytes sum durable plus every live segment body")
    func aggregatedLiveBytesSumsSegments() {
        // Multi-segment train: durable partial plus three still-in-flight segment bodies.
        #expect(DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: 1_000,
            liveSegmentBodyBytes: [500, 300, 200]) == 2_000)
        // Unknown-total open-ended fallback: durableBytes == baseOffset by construction, so
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

    @Test("Held bodies remain in the live aggregate after leaving URLSession temp ownership")
    func heldBodiesRemainInAggregate() {
        let durable = 64 * 1024 * 1024
        let liveBodies = [8 * 1024 * 1024, 4 * 1024 * 1024]
        let heldBodies = [64 * 1024 * 1024]
        #expect(DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: durable,
            liveSegmentBodyBytes: liveBodies + heldBodies)
            == 140 * 1024 * 1024)
    }

    @Test("Train pause display is durable + Σ bodies, never the highest segment file position")
    func trainPauseDisplayUsesAggregateNotMaxPosition() {
        // B1 regression: reproduce the 8-segment train from the field report (15.67 GB original,
        // durable = 0, 512 MiB segments at offsets 0, 512Mi, 1Gi, … 3.5Gi). Each segment temp holds
        // ~126 MB of body. The OLD pause watermark took the HIGHEST segment's `baseOffset + body`
        // (3_758_096_384 + 126 MB ≈ 3.88 GB → a bogus 24% on a ~1 GB-transferred row). The fix must
        // instead publish durable + Σ(all live segment bodies) — the bytes actually downloaded.
        let seg = 512 * 1_024 * 1_024
        let body = 126 * 1_024 * 1_024
        let durable = 0
        let baseOffsets = (0..<8).map { $0 * seg }
        let bodies = Array(repeating: body, count: 8)

        let aggregate = DownloadLiveRangeProgressPolicy.aggregatedLiveBytes(
            durableBytes: durable, liveSegmentBodyBytes: bodies)
        #expect(aggregate == durable + body * 8)

        // The discredited max-position watermark, for contrast — the fix must NOT equal this.
        let highestSegmentPosition = (baseOffsets.max() ?? 0) + body
        #expect(highestSegmentPosition == 3_758_096_384 + body)
        #expect(aggregate != highestSegmentPosition)
        #expect(aggregate < highestSegmentPosition, "aggregate transferred bytes stay well below the top file position")
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

    @Test("Optimistic range coverage cannot claim 100 percent before the file is durable")
    func activeDisplayDoesNotClaimPrematureCompletion() {
        #expect(DownloadLiveRangeProgressPolicy.activeDisplayBytes(
            optimisticBytes: 3_500, expectedBytes: 3_000, durableBytes: 1_000) == 2_999)
        #expect(DownloadLiveRangeProgressPolicy.activeDisplayBytes(
            optimisticBytes: 3_000, expectedBytes: 3_000, durableBytes: 2_999) == 2_999)
        #expect(DownloadLiveRangeProgressPolicy.activeDisplayBytes(
            optimisticBytes: 3_500, expectedBytes: 3_000, durableBytes: 3_000) == 3_000)
        #expect(DownloadLiveRangeProgressPolicy.activeDisplayBytes(
            optimisticBytes: 3_500, expectedBytes: nil, durableBytes: 1_000) == 3_500)
    }
    /// Replays one Range attempt through the aggregate estimator. `awaiting` maps a callback index
    /// to the megabytes of finished, not-yet-counted bodies waiting to be appended at that moment.
    private func boundaryRates(_ megabytes: [Int], awaiting: [Int: Int]) -> [Double?] {
        let key = DownloadAttemptKey(ratingKey: "a", attemptID: .init(rawValue: "attempt-a")!)
        var estimator = DownloadAggregateRateEstimator()
        estimator.setActiveTransfers([key])
        var previous: Int?
        return megabytes.enumerated().map { second, mb in
            let now = Date(timeIntervalSinceReferenceDate: Double(second))
            let sampled = DownloadLiveRangeProgressPolicy.rateSampleBytes(
                reportedBytes: mb * 1_000_000, previous: previous,
                bytesAwaitingAppend: (awaiting[second] ?? 0) * 1_000_000)
            previous = sampled
            estimator.sample(key, bytes: sampled, at: now)
            return estimator.rate(at: now)
        }
    }

    @Test("a segment boundary dip keeps the aggregate speed through the append (#416)")
    func segmentBoundaryKeepsAggregateSpeed() {
        // Device pattern: a 512 MiB segment finishes and leaves the in-flight sum about a second
        // before its body is appended, so the train total drops by hundreds of MB.
        let trace = [0, 36, 72, 108, 144, 180, 216, 252, 288, 324, 24, 60, 396, 432, 468]
        let held = boundaryRates(trace, awaiting: [10: 536, 11: 536])
        // Once settled, the speed stays visible at every callback across the boundary.
        for rate in held[6...] { #expect((rate ?? 0) > 0) }

        // Without the hold, the dip rebaselines the batch: "Updating speed…" for the settling window.
        for rate in boundaryRates(trace, awaiting: [:])[10...13] { #expect(rate == nil) }
    }

    @Test("a regression the awaiting bodies cannot explain still rebaselines the speed")
    func genuineResetStillRebaselines() {
        typealias Policy = DownloadLiveRangeProgressPolicy
        #expect(Policy.rateSampleBytes(reportedBytes: 5, previous: 900, bytesAwaitingAppend: 0) == 5)
        #expect(Policy.rateSampleBytes(reportedBytes: 5, previous: nil, bytesAwaitingAppend: 900) == 5)
        #expect(Policy.rateSampleBytes(reportedBytes: 950, previous: 900, bytesAwaitingAppend: 500) == 950)
        #expect(Policy.rateSampleBytes(reportedBytes: 500, previous: 900, bytesAwaitingAppend: 400) == 900)
        // A sibling loses 300 MB while only a 100 MB body is awaiting append: a real loss.
        #expect(Policy.rateSampleBytes(reportedBytes: 500, previous: 900, bytesAwaitingAppend: 100) == 500)
        // Temp bytes discarded back to the checkpoint: the estimator must start over.
        let reset = boundaryRates([0, 36, 72, 108, 144, 180, 216, 24, 60], awaiting: [7: 100])
        #expect(reset[6] != nil)
        #expect(reset[7] == nil)
    }

    @Test("an attempt with only bodies awaiting append keeps its rate sample")
    func pendingBodiesRetainTheRateSample() {
        let retained = DownloadLiveRangeProgressPolicy.retainedRateSampleKeys(
            inflight: ["b"],
            claims: [(key: "a", trainEpoch: 2), (key: "c", trainEpoch: 0)],
            trainEpochs: ["a": 2, "c": 1])
        // b is transferring; a's segments both finished and are appending; c's claim is retiring
        // from an older train and must not keep a pre-reset sample alive.
        #expect(retained == ["a", "b"])
    }
}
