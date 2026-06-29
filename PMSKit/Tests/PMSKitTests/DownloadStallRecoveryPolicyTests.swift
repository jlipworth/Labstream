import Foundation
import Testing
@testable import PMSKit

@Suite("Download stall recovery policy")
struct DownloadStallRecoveryPolicyTests {
    private func record(ratingKey: String,
                        lane: DownloadLane,
                        resumeMode: DownloadResumeMode? = nil,
                        status: DownloadStatus = .downloading,
                        progress: Double = 0,
                        bytes: Int = 10_000) -> DownloadRecord {
        DownloadRecord(ratingKey: ratingKey,
                       title: "Fixture",
                       localURL: URL(fileURLWithPath: "/tmp/fixture.mp4"),
                       bytes: bytes,
                       progress: progress,
                       status: status,
                       metadata: OfflineMetadata(ratingKey: ratingKey,
                                                 title: "Fixture",
                                                 type: "movie",
                                                 downloadLane: lane,
                                                 resumeMode: resumeMode))
    }

    @Test("MediaBrowser live transcodes are forward-only restart candidates")
    func mediaBrowserLiveTranscodesAreCandidates() {
        #expect(DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(
            record(ratingKey: "jellyfin:1", lane: .optimize)))
        #expect(DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(
            record(ratingKey: "emby:1", lane: .compatibleRemux)))
    }

    @Test("static and Plex rows are not forward-only restart candidates")
    func staticAndPlexRowsAreNotCandidates() {
        #expect(!DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(
            record(ratingKey: "jellyfin:1", lane: .original, resumeMode: .staticByteRange, progress: 0.3)))
        #expect(!DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(
            record(ratingKey: "emby:1", lane: .original, resumeMode: .staticByteRange, progress: 0.3)))
        #expect(!DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(
            record(ratingKey: "plex:1", lane: .optimize)))
    }

    @Test("restart waits for timeout, active work, and attempt budget")
    func restartRequiresTimeoutAndBudget() {
        let now = Date(timeIntervalSince1970: 1_000)
        let stalled = record(ratingKey: "jellyfin:1", lane: .optimize)

        #expect(!DownloadStallRecoveryPolicy.shouldRestartForwardOnlyStream(
            record: stalled,
            active: true,
            lastForwardProgressAt: now.addingTimeInterval(-30),
            now: now,
            restartAttempts: 0))
        #expect(!DownloadStallRecoveryPolicy.shouldRestartForwardOnlyStream(
            record: stalled,
            active: false,
            lastForwardProgressAt: now.addingTimeInterval(-120),
            now: now,
            restartAttempts: 0))
        #expect(!DownloadStallRecoveryPolicy.shouldRestartForwardOnlyStream(
            record: stalled,
            active: true,
            lastForwardProgressAt: now.addingTimeInterval(-120),
            now: now,
            restartAttempts: DownloadStallRecoveryPolicy.defaultMaxAutomaticRestarts))
        #expect(DownloadStallRecoveryPolicy.shouldRestartForwardOnlyStream(
            record: stalled,
            active: true,
            lastForwardProgressAt: now.addingTimeInterval(-120),
            now: now,
            restartAttempts: 1))
    }
}
