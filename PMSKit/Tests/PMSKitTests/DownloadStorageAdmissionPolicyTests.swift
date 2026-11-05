import Testing
@testable import PMSKit

@Suite("Download storage admission policy (P5)")
struct DownloadStorageAdmissionPolicyTests {
    private typealias P = DownloadStorageAdmissionPolicy
    private let gib = 1 << 30
    private var headroom: Int64 { P.headroomBytes }

    /// B01: a 10 GiB file with a 9 GiB checkpoint and the 1 GiB tail already held needs only the
    /// append peak plus headroom; held bytes are never charged twice.
    @Test func heldOnlyCompletionNeedsTheAppendPeakAndHeadroom() {
        let required = P.requiredAdditionalFreeBytes(
            expectedBytes: 10 * gib, durableCheckpointBytes: 9 * gib,
            heldBodyBytes: gib, largestPendingAppendBytes: gib)
        #expect(required == Int64(gib) + headroom)
    }

    @Test func futureSegmentsAndSideAssetsAreCharged() {
        let required = P.requiredAdditionalFreeBytes(
            expectedBytes: 10 * gib, durableCheckpointBytes: 4 * gib,
            heldBodyBytes: gib, largestPendingAppendBytes: gib, futureSideAssetBytes: 50_000_000)
        #expect(required == Int64(5 * gib) + Int64(gib) + 50_000_000 + headroom)
    }

    @Test func unknownSizeChargesOnlyPeakSideAssetsAndHeadroom() {
        #expect(P.requiredAdditionalFreeBytes(expectedBytes: nil, durableCheckpointBytes: nil)
            == headroom)
        #expect(P.requiredAdditionalFreeBytes(expectedBytes: nil, durableCheckpointBytes: 5,
                                              largestPendingAppendBytes: 7, futureSideAssetBytes: 3)
            == 10 + headroom)
    }

    @Test func anOversizedCheckpointShieldsNothing() {
        #expect(P.requiredAdditionalFreeBytes(expectedBytes: 100, durableCheckpointBytes: 200)
            == 100 + headroom)
    }

    /// B24: a retried partial is counted once; an admitted row reserves its known remaining
    /// bytes; a failed row counts only what it holds.
    @Test func capUsageCountsEachRowOnceAndReservesActiveRemaining() {
        let rows = [
            P.CapRow(id: "active", retainedBytes: 300, sideAssetBytes: 10,
                     estimatedTotalBytes: 1_000, reservesRemaining: true),
            P.CapRow(id: "failed", retainedBytes: 200, sideAssetBytes: 5,
                     estimatedTotalBytes: 1_000, reservesRemaining: false),
            P.CapRow(id: "unknown", retainedBytes: 50, sideAssetBytes: 0,
                     estimatedTotalBytes: nil, reservesRemaining: true),
        ]
        #expect(P.capUsage(rows) == (1_000 + 10) + (200 + 5) + 50)
        // Retrying the failed row replaces its 200 bytes with its 1 000 estimate (keeps assets).
        #expect(P.capProjection(rows: rows, addingBytes: 1_000, replacingRowID: "failed")
            == (1_000 + 10) + 50 + 1_000 + 5)
        // A new download adds its estimate on top.
        #expect(P.capProjection(rows: rows, addingBytes: 400, replacingRowID: nil)
            == P.capUsage(rows) + 400)
    }

    @Test func capRejectionUsesTheSelfExcludingProjection() {
        let rows = [P.CapRow(id: "retry", retainedBytes: 900, sideAssetBytes: 0,
                             estimatedTotalBytes: 1_000, reservesRemaining: false)]
        // Old double count: 900 + 1 000 > 1 500. Replacing its own row: 1 000 ≤ 1 500.
        #expect(P.capRejection(rows: rows, addingBytes: 1_000, replacingRowID: "retry",
                               limitBytes: 1_500) == nil)
        #expect(P.capRejection(rows: rows, addingBytes: 1_000, replacingRowID: nil,
                               limitBytes: 1_500) != nil)
        #expect(P.capRejection(rows: rows, addingBytes: nil, replacingRowID: nil,
                               limitBytes: 1) == nil, "unknown sizes are surfaced, not refused")
        #expect(P.capRejection(rows: rows, addingBytes: 5_000, replacingRowID: nil,
                               limitBytes: 0) == nil, "unlimited")
    }
}
