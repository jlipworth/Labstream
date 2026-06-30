import Foundation
import Testing
@testable import PMSKit

@Suite("Download delete policy")
struct DownloadDeletePolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/visionplay-delete-policy.mp4")

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
}
