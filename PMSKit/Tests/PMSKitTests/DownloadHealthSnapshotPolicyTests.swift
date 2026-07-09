import Foundation
import Testing
@testable import PMSKit

@Suite("Download health snapshot policy")
struct DownloadHealthSnapshotPolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-health-policy.mp4")

    private func record(_ status: DownloadStatus, key: String) -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: key, backend: .jellyfin)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              bytes: 0,
                              progress: 0,
                              status: status)
    }

    @Test("Snapshot derives active row and runtime counts")
    func derivesCounts() {
        let session = DownloadHealthSessionSnapshot(opaqueInflightCount: 1,
                                                    rangeInflightCount: 2,
                                                    haltedRangeKeyCount: 3,
                                                    pendingBackgroundCompletionOperationCount: 4,
                                                    deferredBackgroundCompletionIdentifierCount: 5,
                                                    backgroundCompletionHandlerCount: 6,
                                                    finalizingRatingKeyCount: 7,
                                                    pendingTempCleanupBytes: 8)
        let snapshot = DownloadHealthSnapshotPolicy.makeSnapshot(
            records: [record(.queued, key: "queued"),
                      record(.preparing, key: "preparing"),
                      record(.downloading, key: "downloading"),
                      record(.complete, key: "complete"),
                      record(.failed, key: "failed")],
            activeJobCount: 11,
            retryingCount: 12,
            retryHandoffCount: 13,
            pendingStaticResumeCount: 14,
            finalizingStaticRecoveryCount: 15,
            serverPrepPollerCount: 16,
            jellyfinKeepaliveCount: 17,
            forwardStallWatchCount: 18,
            session: session)

        #expect(snapshot.recordCount == 5)
        #expect(snapshot.activeRecordCount == 3)
        #expect(snapshot.queuedCount == 1)
        #expect(snapshot.preparingCount == 1)
        #expect(snapshot.downloadingCount == 1)
        #expect(snapshot.activeJobCount == 11)
        #expect(snapshot.session == session)
        #expect(snapshot.hasWork)
    }

    @Test("Recording requires active row or session work and honors throttle")
    func shouldRecord() {
        let now = Date(timeIntervalSince1970: 1_000)
        let idle = DownloadHealthSnapshotPolicy.makeSnapshot(records: [record(.complete, key: "complete")],
                                                             activeJobCount: 0,
                                                             retryingCount: 0,
                                                             retryHandoffCount: 0,
                                                             pendingStaticResumeCount: 0,
                                                             finalizingStaticRecoveryCount: 0,
                                                             serverPrepPollerCount: 0,
                                                             jellyfinKeepaliveCount: 0,
                                                             forwardStallWatchCount: 0,
                                                             session: DownloadHealthSessionSnapshot())
        #expect(!DownloadHealthSnapshotPolicy.shouldRecord(snapshot: idle, lastRecordedAt: nil, now: now))

        let active = DownloadHealthSnapshotPolicy.makeSnapshot(records: [record(.downloading, key: "active")],
                                                               activeJobCount: 0,
                                                               retryingCount: 0,
                                                               retryHandoffCount: 0,
                                                               pendingStaticResumeCount: 0,
                                                               finalizingStaticRecoveryCount: 0,
                                                               serverPrepPollerCount: 0,
                                                               jellyfinKeepaliveCount: 0,
                                                               forwardStallWatchCount: 0,
                                                               session: DownloadHealthSessionSnapshot())
        #expect(DownloadHealthSnapshotPolicy.shouldRecord(snapshot: active, lastRecordedAt: nil, now: now))
        #expect(!DownloadHealthSnapshotPolicy.shouldRecord(snapshot: active,
                                                          lastRecordedAt: now.addingTimeInterval(-59),
                                                          now: now))
        #expect(DownloadHealthSnapshotPolicy.shouldRecord(snapshot: active,
                                                         lastRecordedAt: now.addingTimeInterval(-60),
                                                         now: now))

        let sessionOnly = DownloadHealthSnapshotPolicy.makeSnapshot(records: [],
                                                                    activeJobCount: 0,
                                                                    retryingCount: 0,
                                                                    retryHandoffCount: 0,
                                                                    pendingStaticResumeCount: 0,
                                                                    finalizingStaticRecoveryCount: 0,
                                                                    serverPrepPollerCount: 0,
                                                                    jellyfinKeepaliveCount: 0,
                                                                    forwardStallWatchCount: 0,
                                                                    session: DownloadHealthSessionSnapshot(rangeInflightCount: 1))
        #expect(DownloadHealthSnapshotPolicy.shouldRecord(snapshot: sessionOnly, lastRecordedAt: nil, now: now))
    }

    @Test("Diagnostic fields keep existing keys")
    func diagnosticFields() {
        let snapshot = DownloadHealthSnapshotPolicy.makeSnapshot(
            records: [record(.preparing, key: "preparing")],
            activeJobCount: 2,
            retryingCount: 3,
            retryHandoffCount: 4,
            pendingStaticResumeCount: 5,
            finalizingStaticRecoveryCount: 6,
            serverPrepPollerCount: 7,
            jellyfinKeepaliveCount: 8,
            forwardStallWatchCount: 9,
            session: DownloadHealthSessionSnapshot(opaqueInflightCount: 10,
                                                   rangeInflightCount: 11,
                                                   haltedRangeKeyCount: 12,
                                                   pendingBackgroundCompletionOperationCount: 13,
                                                   deferredBackgroundCompletionIdentifierCount: 14,
                                                   backgroundCompletionHandlerCount: 15,
                                                   finalizingRatingKeyCount: 16,
                                                   pendingTempCleanupBytes: 17))
        let fields = DownloadHealthSnapshotPolicy.diagnosticFields(for: snapshot)

        #expect(fields["record_count"] == .int(1))
        #expect(fields["preparing_count"] == .int(1))
        #expect(fields["active_job_count"] == .int(2))
        #expect(fields["retrying_count"] == .int(3))
        #expect(fields["session_inflight_count"] == .int(10))
        #expect(fields["session_range_inflight_count"] == .int(11))
        #expect(fields["session_pending_background_ops"] == .int(13))
        #expect(fields["session_pending_temp_cleanup_bytes"] == .int(17))
        #expect(fields.count == 21)
    }
}
