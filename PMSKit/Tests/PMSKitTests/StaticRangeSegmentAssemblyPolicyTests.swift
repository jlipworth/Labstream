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
}
