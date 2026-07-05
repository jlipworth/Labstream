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
}
