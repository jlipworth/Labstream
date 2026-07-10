import Foundation
import Testing
@testable import PMSKit

@Suite("Static range segment assembly policy")
struct StaticRangeSegmentAssemblyPolicyTests {
    @Test("In-order contiguous stashes starting at durableBytes all append")
    func inOrderRunAppends() {
        let result = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 0,
            stashedSegments: [(offset: 0, length: 100), (offset: 100, length: 50), (offset: 150, length: 25)])
        #expect(result.append.map(\.offset) == [0, 100, 150])
        #expect(result.append.map(\.length) == [100, 50, 25])
        #expect(result.hold.isEmpty)
        #expect(result.discard.isEmpty)
    }

    @Test("A gap after the run holds the later segment instead of appending it")
    func gapHoldsLaterSegment() {
        let result = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 0,
            stashedSegments: [(offset: 0, length: 100), (offset: 200, length: 50)])
        #expect(result.append.map(\.offset) == [0])
        #expect(result.hold.map(\.offset) == [200])
        #expect(result.discard.isEmpty)
    }

    @Test("A segment fully behind durableBytes discards")
    func fullyBehindDiscards() {
        let result = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 100,
            stashedSegments: [(offset: 0, length: 100)])
        #expect(result.append.isEmpty)
        #expect(result.hold.isEmpty)
        #expect(result.discard.map(\.offset) == [0])
    }

    @Test("A segment overlapping durableBytes but not aligned to it discards, never appends")
    func overlapNotAlignedDiscards() {
        let result = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 100,
            stashedSegments: [(offset: 50, length: 100)])
        #expect(result.append.isEmpty)
        #expect(result.hold.isEmpty)
        #expect(result.discard.map(\.offset) == [50])
    }

    @Test("Empty input yields all-empty result")
    func emptyInputIsAllEmpty() {
        let result = StaticRangeSegmentAssemblyPolicy.appendableRun(durableBytes: 0, stashedSegments: [])
        #expect(result.append.isEmpty)
        #expect(result.hold.isEmpty)
        #expect(result.discard.isEmpty)
    }

    @Test("Unsorted input still assembles the correct run in offset order")
    func unsortedInputSortsInternally() {
        let result = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 0,
            stashedSegments: [(offset: 150, length: 25), (offset: 0, length: 100), (offset: 100, length: 50)])
        #expect(result.append.map(\.offset) == [0, 100, 150])
    }

    @Test("Duplicate offsets: the first is appendable, the rest discard")
    func duplicateOffsetsKeepFirstDiscardRest() {
        let result = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 0,
            stashedSegments: [(offset: 0, length: 100), (offset: 0, length: 100), (offset: 100, length: 50)])
        #expect(result.append.map(\.offset) == [0, 100])
        #expect(result.append.count == 2)
        #expect(result.discard.map(\.offset) == [0])
        #expect(result.discard.count == 1)
        #expect(result.hold.isEmpty)
    }

    @Test("Duplicate offsets beyond a gap: first hold, rest discard")
    func duplicateOffsetsBeyondGapHoldFirstDiscardRest() {
        let result = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 0,
            stashedSegments: [(offset: 0, length: 100), (offset: 300, length: 50), (offset: 300, length: 50)])
        #expect(result.append.map(\.offset) == [0])
        #expect(result.hold.map(\.offset) == [300])
        #expect(result.hold.count == 1)
        #expect(result.discard.map(\.offset) == [300])
        #expect(result.discard.count == 1)
    }

    // M1: a zero-length stash sitting exactly at the durable checkpoint must NOT append — its
    // `segmentEnd == durableBytes`, so it is fully behind the checkpoint and can only ever discard.
    // Pin this so a wedge (an empty body appended forever, or held forever) cannot regress in.
    @Test("Zero-length segment at the durable checkpoint discards, never appends")
    func zeroLengthAtCheckpointDiscards() {
        let result = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 512,
            stashedSegments: [(offset: 512, length: 0)])
        #expect(result.append.isEmpty)
        #expect(result.hold.isEmpty)
        #expect(result.discard.map(\.offset) == [512])
    }

    // A zero-length stash beyond a real appendable run still discards rather than holding forever.
    @Test("Zero-length segment ahead of the run discards, does not hold")
    func zeroLengthAheadOfRunDiscards() {
        let result = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 0,
            stashedSegments: [(offset: 0, length: 100), (offset: 200, length: 0)])
        #expect(result.append.map(\.offset) == [0])
        // offset 200 with length 0 → segmentEnd 200 > durable 0 and offset 200 >= durable, but it is
        // beyond the gap after the run, so it holds. Length 0 there is harmless (drain re-checks on
        // disk alignment); the load-bearing pin is the at-checkpoint discard above.
        #expect(result.hold.map(\.offset) == [200])
    }
}
