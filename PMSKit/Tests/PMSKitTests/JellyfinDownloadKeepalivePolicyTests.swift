import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin download keepalive policy")
struct JellyfinDownloadKeepalivePolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-jellyfin-keepalive.mp4")

    private func record(status: DownloadStatus = .downloading,
                        backend: DownloadBackendKind = .jellyfin,
                        lane: DownloadLane = .compatibleRemux,
                        mediaSourceID: String? = " source ",
                        playSessionID: String? = " session ") -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: "item", backend: backend)
        let metadata = OfflineMetadata(ratingKey: ratingKey,
                                       title: "Title",
                                       type: "movie",
                                       duration: 12_345,
                                       backendKind: backend,
                                       mediaSourceID: mediaSourceID,
                                       playSessionID: playSessionID,
                                       downloadLane: lane,
                                       resumeMode: lane == .original ? .staticByteRange : .liveForwardOnly)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              bytes: 0,
                              progress: 0,
                              status: status,
                              metadata: metadata)
    }

    @Test("Candidate trims ids and returns backend-local item id")
    func candidate() {
        let candidate = JellyfinDownloadKeepalivePolicy.candidate(for: record(), hasExistingTask: false)
        #expect(candidate == JellyfinDownloadKeepaliveCandidate(ratingKey: "jellyfin:item",
                                                               itemID: "item",
                                                               mediaSourceID: "source",
                                                               playSessionID: "session",
                                                               durationMs: 12_345))
    }

    @Test("Candidate requires active Jellyfin non-original row with session ids and no existing task")
    func candidateGuards() {
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(status: .queued), hasExistingTask: false) != nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(status: .downloading), hasExistingTask: false) != nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(status: .paused), hasExistingTask: false) == nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(backend: .emby), hasExistingTask: false) == nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(lane: .original), hasExistingTask: false) == nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(mediaSourceID: "  "), hasExistingTask: false) == nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(playSessionID: "\n"), hasExistingTask: false) == nil)
        #expect(JellyfinDownloadKeepalivePolicy.candidate(for: record(), hasExistingTask: true) == nil)
    }

    @Test("Position ticks clamp progress and tolerate missing duration")
    func positionTicks() {
        #expect(JellyfinDownloadKeepalivePolicy.positionTicks(progress: 0.5, durationMs: 1_000) == 5_000_000)
        #expect(JellyfinDownloadKeepalivePolicy.positionTicks(progress: -1, durationMs: 1_000) == 0)
        #expect(JellyfinDownloadKeepalivePolicy.positionTicks(progress: 2, durationMs: 1_000) == 10_000_000)
        #expect(JellyfinDownloadKeepalivePolicy.positionTicks(progress: 0.5, durationMs: nil) == 0)
        #expect(JellyfinDownloadKeepalivePolicy.positionTicks(progress: .nan, durationMs: 1_000) == 0)
    }

    // MARK: N2/F2c — keepalive reports a real advancing position for forward-only rows

    @Test("Reported position prefers the exact progress fraction when the lane has one")
    func reportedPositionUsesExactProgress() {
        #expect(JellyfinDownloadKeepalivePolicy.reportedPositionTicks(
            progress: 0.5, bytes: 0, estimatedTotalBytes: nil,
            elapsedSeconds: 10, durationMs: 1_000, lastReportedTicks: 0) == 5_000_000)
    }

    @Test("Reported position derives from bytes vs the transcode size estimate when progress is zero")
    func reportedPositionDerivesFromBytes() {
        // 25% of the estimated bytes → 25% of a 7,200,000 ms runtime.
        #expect(JellyfinDownloadKeepalivePolicy.reportedPositionTicks(
            progress: 0, bytes: 500_000_000, estimatedTotalBytes: 2_000_000_000,
            elapsedSeconds: 30, durationMs: 7_200_000, lastReportedTicks: 0) == 18_000_000_000)
        // The byte fraction is capped at the source duration.
        #expect(JellyfinDownloadKeepalivePolicy.reportedPositionTicks(
            progress: 0, bytes: 3_000_000_000, estimatedTotalBytes: 2_000_000_000,
            elapsedSeconds: 30, durationMs: 7_200_000, lastReportedTicks: 0) == 72_000_000_000)
    }

    @Test("Reported position falls back to elapsed wall clock capped at duration")
    func reportedPositionElapsedFallback() {
        // No progress, no estimate: 30s elapsed → 30s position.
        #expect(JellyfinDownloadKeepalivePolicy.reportedPositionTicks(
            progress: 0, bytes: 0, estimatedTotalBytes: nil,
            elapsedSeconds: 30, durationMs: 7_200_000, lastReportedTicks: 0) == 300_000_000)
        // Elapsed past the runtime is capped at the runtime.
        #expect(JellyfinDownloadKeepalivePolicy.reportedPositionTicks(
            progress: 0, bytes: 0, estimatedTotalBytes: nil,
            elapsedSeconds: 8_000, durationMs: 1_000, lastReportedTicks: 0) == 10_000_000)
        // Even with no duration at all, elapsed still advances (better than a frozen 0).
        #expect(JellyfinDownloadKeepalivePolicy.reportedPositionTicks(
            progress: 0, bytes: 0, estimatedTotalBytes: nil,
            elapsedSeconds: 30, durationMs: nil, lastReportedTicks: 0) == 300_000_000)
    }

    @Test("Reported position is monotonic across signal-source switches")
    func reportedPositionMonotonic() {
        // A later byte-based sample lower than the previous report never moves backwards.
        #expect(JellyfinDownloadKeepalivePolicy.reportedPositionTicks(
            progress: 0, bytes: 100, estimatedTotalBytes: 2_000_000_000,
            elapsedSeconds: 1, durationMs: 7_200_000, lastReportedTicks: 42_000_000) == 42_000_000)
        #expect(JellyfinDownloadKeepalivePolicy.reportedPositionTicks(
            progress: 0, bytes: 0, estimatedTotalBytes: nil,
            elapsedSeconds: 0, durationMs: nil, lastReportedTicks: 42) == 42)
        // Degenerate inputs stay at zero.
        #expect(JellyfinDownloadKeepalivePolicy.reportedPositionTicks(
            progress: .nan, bytes: 0, estimatedTotalBytes: nil,
            elapsedSeconds: .nan, durationMs: nil, lastReportedTicks: -5) == 0)
    }
}
