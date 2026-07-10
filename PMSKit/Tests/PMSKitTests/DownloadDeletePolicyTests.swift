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

    @Test("Preparing Emby convert rows cancel their server job when the persisted lane matches")
    func preparingEmbyConvertCancelsMatchingSession() {
        let row = record(status: .preparing, jobID: 42)
        #expect(DownloadDeletePolicy.embyConvertCancelDecision(for: row,
                                                               embySessionMatchesPersistedServer: true)
                == .cancel(jobID: 42))
    }

    @Test("Preparing Emby convert rows log skip when the lane is unavailable or mismatched")
    func preparingEmbyConvertSkipsMismatchedSession() {
        let row = record(status: .preparing, jobID: 99)
        #expect(DownloadDeletePolicy.embyConvertCancelDecision(for: row,
                                                               embySessionMatchesPersistedServer: false)
                == .skip(jobID: 99,
                         reason: DownloadDeletePolicy.embySessionUnavailableOrMismatchReason))
    }

    @Test("Rows without an active convert job need no server-side delete")
    func rowsWithoutPreparingConvertNeedNoServerCancel() {
        #expect(DownloadDeletePolicy.embyConvertCancelDecision(for: nil,
                                                               embySessionMatchesPersistedServer: true) == .none)
        #expect(DownloadDeletePolicy.embyConvertCancelDecision(for: record(status: .paused, jobID: 42),
                                                               embySessionMatchesPersistedServer: true) == .none)
        #expect(DownloadDeletePolicy.embyConvertCancelDecision(for: record(status: .preparing),
                                                               embySessionMatchesPersistedServer: true) == .none)
    }

    @Test("A failed Emby row whose persisted Convert job may still be Converting cancels the job")
    func failedEmbyRowWithPersistedJobStillCancels() {
        // Terminal poll failures (e.g. 401/403) fail the row app-side while the server keeps
        // converting; the persisted jobID is the only remaining handle at delete time.
        let row = record(status: .failed, jobID: 7)
        #expect(DownloadDeletePolicy.embyConvertCancelDecision(for: row,
                                                               embySessionMatchesPersistedServer: true)
                == .cancel(jobID: 7))
        #expect(DownloadDeletePolicy.embyConvertCancelDecision(for: row,
                                                               embySessionMatchesPersistedServer: false)
                == .skip(jobID: 7,
                         reason: DownloadDeletePolicy.embySessionUnavailableOrMismatchReason))
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

    @Test("Deleting a Plex row still in server prep cancels its optimize queue item")
    func plexPrepPhaseDeleteCancels() {
        for status in [DownloadStatus.queued, .preparing, .failed] {
            #expect(DownloadDeletePolicy.plexOptimizeCancelDecision(
                for: plexRecord(status: status),
                plexSessionMatchesPersistedServer: true)
                == .cancel(queueTitle: "Title [Labstream abcd1234]"))
        }
    }

    @Test("Deleting a Plex row after the rendered-Part handoff or completion never cancels")
    func plexCompletedRenderDeleteDoesNotCancel() {
        // Handed off: resume mode rewritten to staticByteRange at startOptimizedPartDownload.
        #expect(DownloadDeletePolicy.plexOptimizeCancelDecision(
            for: plexRecord(status: .downloading, resumeMode: .staticByteRange),
            plexSessionMatchesPersistedServer: true) == .none)
        // Completed download: the type-42 item is the rendered version other rows may reuse.
        #expect(DownloadDeletePolicy.plexOptimizeCancelDecision(
            for: plexRecord(status: .complete, resumeMode: .staticByteRange),
            plexSessionMatchesPersistedServer: true) == .none)
        // Paused is an intentional keep, not an abandon.
        #expect(DownloadDeletePolicy.plexOptimizeCancelDecision(
            for: plexRecord(status: .paused),
            plexSessionMatchesPersistedServer: true) == .none)
    }

    @Test("Plex delete-time cancel needs a persisted queue title and a Plex row")
    func plexCancelRequiresHandleAndBackend() {
        #expect(DownloadDeletePolicy.plexOptimizeCancelDecision(
            for: nil, plexSessionMatchesPersistedServer: true) == .none)
        #expect(DownloadDeletePolicy.plexOptimizeCancelDecision(
            for: plexRecord(status: .queued, queueTitle: nil),
            plexSessionMatchesPersistedServer: true) == .none)
        // An Emby prep row must never route into the Plex optimize cancel.
        #expect(DownloadDeletePolicy.plexOptimizeCancelDecision(
            for: record(status: .preparing, jobID: 42),
            plexSessionMatchesPersistedServer: true) == .none)
    }

    @Test("Plex session mismatch or unavailability skips instead of cancelling")
    func plexSessionMismatchSkips() {
        #expect(DownloadDeletePolicy.plexOptimizeCancelDecision(
            for: plexRecord(status: .queued),
            plexSessionMatchesPersistedServer: false)
            == .skip(queueTitle: "Title [Labstream abcd1234]",
                     reason: DownloadDeletePolicy.plexSessionUnavailableOrMismatchReason))
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
