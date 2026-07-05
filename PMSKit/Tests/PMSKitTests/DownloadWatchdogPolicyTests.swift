import Foundation
import Testing
@testable import PMSKit

@Suite("Download watchdog policy")
struct DownloadWatchdogPolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-watchdog-policy.mp4")

    private func record(status: DownloadStatus,
                        backend: DownloadBackendKind = .jellyfin,
                        lane: DownloadLane = .compatibleRemux,
                        resumeMode: DownloadResumeMode = .liveForwardOnly) -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: "item", backend: backend)
        let metadata = OfflineMetadata(ratingKey: ratingKey,
                                       title: "Title",
                                       type: "movie",
                                       backendKind: backend,
                                       downloadLane: lane,
                                       resumeMode: resumeMode)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              bytes: 0,
                              progress: 0,
                              status: status,
                              metadata: metadata)
    }

    @Test("Watchdog cadence remains stable")
    func cadence() {
        #expect(DownloadWatchdogPolicy.refreshIntervalSeconds == 15.0)
    }

    @Test("Preparing rows always need watchdog refreshes")
    func preparingRowsNeedWatchdog() {
        #expect(DownloadWatchdogPolicy.requiresWatchdog(record(status: .preparing,
                                                              backend: .emby,
                                                              lane: .optimize,
                                                              resumeMode: .serverPrepThenStatic)))
    }

    @Test("Forward-only MediaBrowser streams need watchdog refreshes")
    func forwardOnlyRowsNeedWatchdog() {
        #expect(DownloadWatchdogPolicy.requiresWatchdog(record(status: .downloading)))
        #expect(!DownloadWatchdogPolicy.requiresWatchdog(record(status: .downloading,
                                                               backend: .plex,
                                                               lane: .original,
                                                               resumeMode: .staticByteRange)))
    }

    @Test("Collections require watchdog when any row does")
    func collectionPredicate() {
        let complete = record(status: .complete, backend: .plex, lane: .original, resumeMode: .staticByteRange)
        let prep = record(status: .preparing, backend: .emby, lane: .optimize, resumeMode: .serverPrepThenStatic)
        #expect(!DownloadWatchdogPolicy.requiresWatchdog(records: [complete]))
        #expect(DownloadWatchdogPolicy.requiresWatchdog(records: [complete, prep]))
    }
}
