import Foundation
import Testing
@testable import PMSKit

@Suite("Static range refresh cleanup policy")
struct StaticRangeRefreshCleanupPolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-static-range-refresh-cleanup.mp4")

    private func record(_ key: String, status: DownloadStatus) -> DownloadRecord {
        let metadata = OfflineMetadata(ratingKey: key,
                                       title: "Title",
                                       type: "movie",
                                       backendKind: .plex,
                                       downloadLane: .original,
                                       resumeMode: .staticByteRange)
        return DownloadRecord(ratingKey: key,
                              title: "Title",
                              localURL: url,
                              bytes: 0,
                              progress: 0,
                              status: status,
                              metadata: metadata)
    }

    @Test("Finalizing cleanup treats all terminal file outcomes as terminal")
    func finalizingTerminalKeys() {
        let records = [record("complete", status: .complete),
                       record("unverified", status: .unverified),
                       record("failed", status: .failed),
                       record("downloading", status: .downloading)]
        #expect(StaticRangeRefreshCleanupPolicy.finalizingTerminalKeys(records: records)
                == ["complete", "unverified", "failed"])
    }

    @Test("Manual queue-resume markers survive retry handoff failed rows")
    func manualQueueResumeTerminalKeysRespectRetryHandoff() {
        let records = [record("failed-handoff", status: .failed),
                       record("failed-final", status: .failed),
                       record("complete", status: .complete),
                       record("paused", status: .paused)]
        let keys = StaticRangeRefreshCleanupPolicy.manualQueueResumeTerminalKeys(
            records: records,
            retryHandoffKeys: ["failed-handoff"],
            retryingKeys: ["failed-handoff"]
        )
        #expect(keys == ["failed-final", "complete"])
    }

    @Test("Checkpoint pause overlay requires a live downloading transfer")
    func checkpointPauseKeepPredicate() {
        #expect(StaticRangeRefreshCleanupPolicy.shouldKeepCheckpointPause(record: record("a", status: .downloading),
                                                                         isTrackingTransfer: true))
        #expect(!StaticRangeRefreshCleanupPolicy.shouldKeepCheckpointPause(record: record("b", status: .downloading),
                                                                          isTrackingTransfer: false))
        #expect(!StaticRangeRefreshCleanupPolicy.shouldKeepCheckpointPause(record: record("c", status: .paused),
                                                                          isTrackingTransfer: true))
        #expect(!StaticRangeRefreshCleanupPolicy.shouldKeepCheckpointPause(record: nil,
                                                                          isTrackingTransfer: true))
    }

    @Test("Live range overlays stay only for active or checkpoint-pausing keys")
    func liveRangeProgressKeepPredicate() {
        #expect(StaticRangeRefreshCleanupPolicy.shouldKeepLiveRangeProgress(key: "active",
                                                                           activeDownloadingKeys: ["active"],
                                                                           checkpointPauseKeys: []))
        #expect(StaticRangeRefreshCleanupPolicy.shouldKeepLiveRangeProgress(key: "pausing",
                                                                           activeDownloadingKeys: [],
                                                                           checkpointPauseKeys: ["pausing"]))
        #expect(!StaticRangeRefreshCleanupPolicy.shouldKeepLiveRangeProgress(key: "stale",
                                                                            activeDownloadingKeys: ["active"],
                                                                            checkpointPauseKeys: ["pausing"]))
    }
}
