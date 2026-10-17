import Foundation
import Testing
@testable import PMSKit

@Suite("Download delete policy")
struct DownloadDeletePolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-delete-policy.mp4")

    private func record(status: DownloadStatus,
                        backend: DownloadBackendKind = .emby,
                        jobID: Int? = nil) -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: "item", backend: backend)
        let metadata = OfflineMetadata(ratingKey: ratingKey,
                                       title: "Title",
                                       type: "movie",
                                       backendKind: backend,
                                       downloadLane: .optimize,
                                       resumeMode: .serverPrepThenStatic,
                                       embyConvertJobID: jobID)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              bytes: 0,
                              progress: 0,
                              status: status,
                              metadata: metadata)
    }

    @Test("The deletion note covers Emby Convert rows still in server prep")
    func embyPrepDeletionDisclosesCancel() {
        #expect(DownloadDeletePolicy.deletionCancelsServerPrep(record(status: .preparing, jobID: 42)))
        #expect(DownloadDeletePolicy.deletionCancelsServerPrep(record(status: .paused, jobID: 42)))
        #expect(!DownloadDeletePolicy.deletionCancelsServerPrep(record(status: .preparing)))
        #expect(!DownloadDeletePolicy.deletionCancelsServerPrep(record(status: .complete, jobID: 42)))
        #expect(!DownloadDeletePolicy.deletionCancelsServerPrep(nil))
    }

    // MARK: - Plex optimize delete-time cancel

    private func plexRecord(status: DownloadStatus,
                            resumeMode: DownloadResumeMode = .serverPrepThenStatic,
                            queueTitle: String? = "Title [Labstream abcd1234]") -> DownloadRecord {
        let metadata = OfflineMetadata(ratingKey: "101",
                                       title: "Title",
                                       type: "movie",
                                       optimizeTargetName: "Medium",
                                       optimizeQueueTitle: queueTitle,
                                       backendKind: .plex,
                                       downloadLane: .optimize,
                                       resumeMode: resumeMode)
        return DownloadRecord(ratingKey: "101",
                              title: "Title",
                              localURL: url,
                              bytes: 0,
                              progress: 0,
                              status: status,
                              metadata: metadata)
    }

    @Test("Deleting a Plex row still in server prep owes its optimize queue item, paused included (D2)")
    func plexPrepPhaseDeleteOwesCleanup() {
        for status in [DownloadStatus.queued, .preparing, .paused, .failed] {
            #expect(DownloadDeletePolicy.plexOptimizeCleanupQueueTitle(
                for: plexRecord(status: status)) == "Title [Labstream abcd1234]")
            #expect(DownloadDeletePolicy.deletionCancelsServerPrep(plexRecord(status: status)))
        }
    }

    @Test("Deleting a Plex row after the rendered-Part handoff or completion owes nothing")
    func plexCompletedRenderDeleteOwesNothing() {
        // Handed off: resume mode rewritten to staticByteRange at startOptimizedPartDownload.
        #expect(DownloadDeletePolicy.plexOptimizeCleanupQueueTitle(
            for: plexRecord(status: .downloading, resumeMode: .staticByteRange)) == nil)
        // Completed download: the type-42 item is the rendered version other rows may reuse.
        #expect(DownloadDeletePolicy.plexOptimizeCleanupQueueTitle(
            for: plexRecord(status: .complete, resumeMode: .staticByteRange)) == nil)
        #expect(!DownloadDeletePolicy.deletionCancelsServerPrep(
            plexRecord(status: .complete, resumeMode: .staticByteRange)))
    }

    @Test("Plex delete-time cleanup needs a persisted queue title and a Plex row")
    func plexCleanupRequiresHandleAndBackend() {
        #expect(DownloadDeletePolicy.plexOptimizeCleanupQueueTitle(for: nil) == nil)
        #expect(DownloadDeletePolicy.plexOptimizeCleanupQueueTitle(
            for: plexRecord(status: .queued, queueTitle: nil)) == nil)
        // An Emby prep row must never route into the Plex optimize cleanup.
        #expect(DownloadDeletePolicy.plexOptimizeCleanupQueueTitle(
            for: record(status: .preparing, jobID: 42)) == nil)
    }

    // MARK: - Plex prep poller orphan-exit gate

    @Test("The Plex prep poller continues only while the row exists and owns its slot")
    func plexPrepPollerContinuationGate() {
        #expect(ServerPrepRefreshPolicy.plexPrepPollerShouldContinue(rowExists: true, slotActive: true))
        #expect(!ServerPrepRefreshPolicy.plexPrepPollerShouldContinue(rowExists: false, slotActive: true))
        #expect(!ServerPrepRefreshPolicy.plexPrepPollerShouldContinue(rowExists: true, slotActive: false))
        #expect(!ServerPrepRefreshPolicy.plexPrepPollerShouldContinue(rowExists: false, slotActive: false))
    }
}
