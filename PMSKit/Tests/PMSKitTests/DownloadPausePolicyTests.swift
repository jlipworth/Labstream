import Foundation
import Testing
@testable import PMSKit

@Suite("Download pause policy")
struct DownloadPausePolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/visionplay-pause-policy.mp4")

    private func record(status: DownloadStatus,
                        backend: DownloadBackendKind = .plex,
                        lane: DownloadLane = .original,
                        resumeMode: DownloadResumeMode = .staticByteRange,
                        embyJobID: Int? = nil) -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: "item", backend: backend)
        let metadata = OfflineMetadata(ratingKey: ratingKey,
                                       title: "Title",
                                       type: "movie",
                                       backendKind: backend,
                                       downloadLane: lane,
                                       resumeMode: resumeMode,
                                       embyConvertJobID: embyJobID)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              bytes: 0,
                              progress: 0,
                              status: status,
                              metadata: metadata)
    }

    @Test("Static range queued/downloading rows choose checkpoint or immediate park by live task")
    func staticRangePauseActions() {
        #expect(DownloadPausePolicy.rowAction(status: .downloading,
                                             isStaticRangeRecord: true,
                                             isTrackingTransfer: true)
                == .checkpointPauseAndCancelTask)
        #expect(DownloadPausePolicy.rowAction(status: .queued,
                                             isStaticRangeRecord: true,
                                             isTrackingTransfer: false)
                == .parkStaticWithoutLiveTask)
    }

    @Test("Opaque or forward-only transfers pause through URLSession only")
    func nonStaticPauseAction() {
        #expect(DownloadPausePolicy.rowAction(status: .downloading,
                                             isStaticRangeRecord: false,
                                             isTrackingTransfer: true)
                == .cancelTaskOnly)
        #expect(DownloadPausePolicy.rowAction(status: .queued,
                                             isStaticRangeRecord: false,
                                             isTrackingTransfer: false)
                == .cancelTaskOnly)
    }

    @Test("Preparing rows park immediately and terminal rows ignore pause")
    func preparingAndTerminalActions() {
        #expect(DownloadPausePolicy.rowAction(status: .preparing,
                                             isStaticRangeRecord: false,
                                             isTrackingTransfer: false)
                == .parkPreparing)
        for status in [DownloadStatus.complete, .unverified, .failed, .paused] {
            #expect(DownloadPausePolicy.rowAction(status: status,
                                                 isStaticRangeRecord: true,
                                                 isTrackingTransfer: true)
                    == .ignore)
        }
    }

    @Test("Queue pause keeps persistent Emby server prep polling but pauses other active rows")
    func queuePauseSkipsPersistentEmbyConvertPolling() {
        let embyConvert = record(status: .preparing,
                                 backend: .emby,
                                 lane: .optimize,
                                 resumeMode: .serverPrepThenStatic,
                                 embyJobID: 42)
        #expect(!DownloadPausePolicy.shouldPauseDuringQueuePause(embyConvert))

        let plexPrep = record(status: .queued,
                              backend: .plex,
                              lane: .optimize,
                              resumeMode: .serverPrepThenStatic)
        #expect(DownloadPausePolicy.shouldPauseDuringQueuePause(plexPrep))
        #expect(!DownloadPausePolicy.shouldPauseDuringQueuePause(record(status: .paused)))
    }
}
