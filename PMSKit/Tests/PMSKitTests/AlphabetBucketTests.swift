import Foundation
import Testing
@testable import PMSKit

@Suite("Alphabet bucket offsets")
struct AlphabetBucketTests {
    @Test func computesRunningOffsets() {
        let buckets = AlphabetBucket.buckets(
            from: [("A", 3), ("B", 2), ("C", 5)],
            total: 10
        )
        #expect(buckets.map(\.display) == ["A", "B", "C"])
        #expect(buckets.map(\.offset) == [0, 3, 5])
        #expect(buckets.map(\.count) == [3, 2, 5])
    }

    @Test func skipsEmptyAndBlankCharacters() {
        let buckets = AlphabetBucket.buckets(
            from: [("A", 2), ("B", 0), ("  ", 4), ("C", 1)],
            total: 7
        )
        // B has zero items and the blank entry are both dropped; offsets still run over
        // the kept characters only.
        #expect(buckets.map(\.display) == ["A", "C"])
        #expect(buckets.map(\.offset) == [0, 2])
    }

    @Test func trimsWhitespaceInDisplay() {
        let buckets = AlphabetBucket.buckets(from: [(" A ", 1)], total: 1)
        #expect(buckets.first?.display == "A")
    }

    @Test func clampsOffsetIntoRangeWhenCountsExceedTotal() {
        // Counts that sum past `total` (a server count/page disagreement) must never
        // produce an offset outside 0..<total — the offset is a scroll target.
        let buckets = AlphabetBucket.buckets(
            from: [("A", 100), ("B", 100), ("C", 100)],
            total: 5
        )
        #expect(buckets.allSatisfy { $0.offset >= 0 && $0.offset <= 4 })
        #expect(buckets.map(\.offset) == [0, 4, 4])
    }

    @Test func emptyInputProducesNoBuckets() {
        #expect(AlphabetBucket.buckets(from: [], total: 0).isEmpty)
    }

    @Test func zeroTotalClampsOffsetsToZero() {
        let buckets = AlphabetBucket.buckets(from: [("A", 1), ("B", 1)], total: 0)
        #expect(buckets.map(\.offset) == [0, 0])
    }

    @Test func plexAndProbePathsAgreeForSameLibrary() {
        // The Plex single-call path and the Jellyfin/Emby per-letter probe path both feed
        // the SAME `buckets(from:total:)`, so identical `(display, count)` input must yield
        // identical rails — the cross-backend invariant from GH #96.
        let counts = [("A", 4), ("M", 6), ("Z", 2)]
        let plexStyle = AlphabetBucket.buckets(from: counts, total: 12)
        let probeStyle = AlphabetBucket.buckets(from: counts, total: 12)
        #expect(plexStyle == probeStyle)
    }
}
