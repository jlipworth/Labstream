import Foundation
import Testing
@testable import PMSKit

private let MB = 1_024 * 1_024

@Suite("Static range segment queue policy")
struct StaticRangeSegmentQueuePolicyTests {
    @Test("Fresh file: a full train of closed-range plans is queued up to the max depth")
    func plansFreshFileTrain() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 0, expectedBytes: 3 * 512 * MB, liveSegmentOffsets: [],
            segmentBytes: 512 * MB, maxQueuedSegments: 8)
        #expect(plans.count == 3)
        #expect(plans[0].rangeHeaderValue == "bytes=0-\(512 * MB - 1)")
        #expect(plans[0] == StaticRangeSegmentPlan(offset: 0, length: 512 * MB))
        #expect(plans[1] == StaticRangeSegmentPlan(offset: 512 * MB, length: 512 * MB))
        #expect(plans[2] == StaticRangeSegmentPlan(offset: 2 * 512 * MB, length: 512 * MB))
    }

    @Test("Partial train alive: plans start after live offsets and top up to the max depth")
    func plansResumeAfterLiveSegments() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 0, expectedBytes: 8 * 512 * MB, liveSegmentOffsets: [0, 512 * MB],
            segmentBytes: 512 * MB, maxQueuedSegments: 4)
        // 2 live + N new <= 4 -> 2 new plans, starting after the live train.
        #expect(plans.count == 2)
        #expect(plans[0].offset == 2 * 512 * MB)
        #expect(plans[1].offset == 3 * 512 * MB)
    }

    @Test("Tail shorter than a segment is truncated to the remainder")
    func tailSegmentTruncated() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 0, expectedBytes: 512 * MB + 100, liveSegmentOffsets: [],
            segmentBytes: 512 * MB, maxQueuedSegments: 8)
        #expect(plans.count == 2)
        #expect(plans[0] == StaticRangeSegmentPlan(offset: 0, length: 512 * MB))
        #expect(plans[1] == StaticRangeSegmentPlan(offset: 512 * MB, length: 100))
        #expect(plans[1].rangeHeaderValue == "bytes=\(512 * MB)-\(512 * MB + 99)")
    }

    @Test("Unknown total size falls back to a single open-ended plan")
    func unknownTotalFallsBackToOpenEnded() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 700, expectedBytes: nil, liveSegmentOffsets: [],
            segmentBytes: 512 * MB, maxQueuedSegments: 8)
        #expect(plans == [StaticRangeSegmentPlan(offset: 700, length: nil)])
        #expect(plans[0].rangeHeaderValue == "bytes=700-")
    }

    @Test("Durable bytes already at or past expected size yields no new plans")
    func durableAtOrPastExpectedIsEmpty() {
        #expect(StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 1_000, expectedBytes: 1_000, liveSegmentOffsets: [],
            segmentBytes: 512 * MB, maxQueuedSegments: 8).isEmpty)
        #expect(StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 1_200, expectedBytes: 1_000, liveSegmentOffsets: [],
            segmentBytes: 512 * MB, maxQueuedSegments: 8).isEmpty)
    }

    @Test("Live segment depth already at the max queues nothing new")
    func liveAtMaxQueuesNothing() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 0, expectedBytes: 8 * 512 * MB,
            liveSegmentOffsets: [0, 512 * MB, 2 * 512 * MB, 3 * 512 * MB],
            segmentBytes: 512 * MB, maxQueuedSegments: 4)
        #expect(plans.isEmpty)
    }
}
