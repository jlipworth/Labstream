import Foundation
import Testing
@testable import PMSKit

private let MB = 1_024 * 1_024

@Suite("Static range segment queue policy")
struct StaticRangeSegmentQueuePolicyTests {
    @Test("Fresh file: a full train of closed-range plans is queued up to the max depth")
    func plansFreshFileTrain() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 0, expectedBytes: 3 * 512 * MB, liveSegments: [],
            segmentBytes: 512 * MB, maxQueuedSegments: 8)
        #expect(plans.count == 3)
        #expect(plans[0].rangeHeaderValue == "bytes=0-\(512 * MB - 1)")
        #expect(plans[0] == StaticRangeSegmentPlan(offset: 0, length: 512 * MB))
        #expect(plans[1] == StaticRangeSegmentPlan(offset: 512 * MB, length: 512 * MB))
        #expect(plans[2] == StaticRangeSegmentPlan(offset: 2 * 512 * MB, length: 512 * MB))
    }

    @Test("Partial train alive: plans start after live segments and top up to the max depth")
    func plansResumeAfterLiveSegments() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 0, expectedBytes: 8 * 512 * MB,
            liveSegments: [
                StaticRangeSegmentPlan(offset: 0, length: 512 * MB),
                StaticRangeSegmentPlan(offset: 512 * MB, length: 512 * MB),
            ],
            segmentBytes: 512 * MB, maxQueuedSegments: 4)
        // 2 live + N new <= 4 -> 2 new plans, starting after the live train.
        #expect(plans.count == 2)
        #expect(plans[0].offset == 2 * 512 * MB)
        #expect(plans[1].offset == 3 * 512 * MB)
    }

    @Test("Tail shorter than a segment is truncated to the remainder")
    func tailSegmentTruncated() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 0, expectedBytes: 512 * MB + 100, liveSegments: [],
            segmentBytes: 512 * MB, maxQueuedSegments: 8)
        #expect(plans.count == 2)
        #expect(plans[0] == StaticRangeSegmentPlan(offset: 0, length: 512 * MB))
        #expect(plans[1] == StaticRangeSegmentPlan(offset: 512 * MB, length: 100))
        #expect(plans[1].rangeHeaderValue == "bytes=\(512 * MB)-\(512 * MB + 99)")
    }

    @Test("Unknown total size falls back to a single open-ended plan")
    func unknownTotalFallsBackToOpenEnded() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 700, expectedBytes: nil, liveSegments: [],
            segmentBytes: 512 * MB, maxQueuedSegments: 8)
        #expect(plans == [StaticRangeSegmentPlan(offset: 700, length: nil)])
        #expect(plans[0].rangeHeaderValue == "bytes=700-")
    }

    @Test("Durable bytes already at or past expected size yields no new plans")
    func durableAtOrPastExpectedIsEmpty() {
        #expect(StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 1_000, expectedBytes: 1_000, liveSegments: [],
            segmentBytes: 512 * MB, maxQueuedSegments: 8).isEmpty)
        #expect(StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 1_200, expectedBytes: 1_000, liveSegments: [],
            segmentBytes: 512 * MB, maxQueuedSegments: 8).isEmpty)
    }

    @Test("Live segment depth already at the max queues nothing new")
    func liveAtMaxQueuesNothing() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 0, expectedBytes: 8 * 512 * MB,
            liveSegments: (0..<4).map {
                StaticRangeSegmentPlan(offset: $0 * 512 * MB, length: 512 * MB)
            },
            segmentBytes: 512 * MB, maxQueuedSegments: 4)
        #expect(plans.isEmpty)
    }

    @Test("Adopted old-grid segments count as coverage — no overlapping refetch after a misaligned relaunch")
    func adoptedOldGridSegmentsAreNotRefetched() {
        // Crash-mid-append relaunch: durable is 350, but the adopted train sits on the old grid
        // anchored at 300 (segments [812, 1324) and [1324, 1836)). An offset-equality skip would
        // re-plan 350, 862, 1374... overlapping BOTH adopted segments. Interval-aware planning
        // fills only the real gap [350, 812) and then continues after the covered run.
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 350, expectedBytes: 2_000,
            liveSegments: [
                StaticRangeSegmentPlan(offset: 812, length: 512),
                StaticRangeSegmentPlan(offset: 1_324, length: 512),
            ],
            segmentBytes: 512, maxQueuedSegments: 8)
        #expect(plans == [
            StaticRangeSegmentPlan(offset: 350, length: 462),
            StaticRangeSegmentPlan(offset: 1_836, length: 164),
        ])
    }

    @Test("A gap wider than a segment is filled with full segments up to the next covered interval")
    func wideGapFilledWithGridSegments() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 0, expectedBytes: 4_000,
            liveSegments: [StaticRangeSegmentPlan(offset: 1_200, length: 512)],
            segmentBytes: 512, maxQueuedSegments: 8)
        #expect(plans == [
            StaticRangeSegmentPlan(offset: 0, length: 512),
            StaticRangeSegmentPlan(offset: 512, length: 512),
            StaticRangeSegmentPlan(offset: 1_024, length: 176),
            StaticRangeSegmentPlan(offset: 1_712, length: 512),
            StaticRangeSegmentPlan(offset: 2_224, length: 512),
            StaticRangeSegmentPlan(offset: 2_736, length: 512),
            StaticRangeSegmentPlan(offset: 3_248, length: 512),
        ])
    }

    @Test("A live open-ended segment covers through the end of the file")
    func openEndedLiveSegmentCoversTail() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 0, expectedBytes: 2_000,
            liveSegments: [StaticRangeSegmentPlan(offset: 512, length: nil)],
            segmentBytes: 512, maxQueuedSegments: 8)
        #expect(plans == [StaticRangeSegmentPlan(offset: 0, length: 512)])
    }

    @Test("Live segments fully behind the durable checkpoint don't block planning ahead")
    func staleLiveSegmentBehindDurableIgnoredForCoverage() {
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 1_024, expectedBytes: 2_000,
            liveSegments: [StaticRangeSegmentPlan(offset: 0, length: 512)],
            segmentBytes: 512, maxQueuedSegments: 2)
        // The stale segment still occupies one depth slot (budget 1), but its interval is behind
        // the cursor and never blocks the plan at the durable offset.
        #expect(plans == [StaticRangeSegmentPlan(offset: 1_024, length: 512)])
    }
}
