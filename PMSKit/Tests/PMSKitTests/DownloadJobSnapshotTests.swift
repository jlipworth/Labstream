import Foundation
import Testing
@testable import PMSKit

@Suite("Download job snapshot")
struct DownloadJobSnapshotTests {
    private func record(ratingKey: String = "emby:item-1",
                        status: DownloadStatus,
                        lane: DownloadLane = .compatibleRemux,
                        resumeMode: DownloadResumeMode? = .staticByteRange,
                        serverPrepared: Bool = true,
                        bytes: Int = 0,
                        progress: Double = 0) -> DownloadRecord {
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
                                                 resumeMode: resumeMode,
                                                 serverPreparedVersion: serverPrepared))
    }

    @Test("Snapshot preserves backend lane resume and server-prepared metadata")
    func preservesMetadata() {
        let snapshot = DownloadJobSnapshot(record: record(status: .downloading, bytes: 42, progress: 0.5))
        #expect(snapshot.ratingKey == "emby:item-1")
        #expect(snapshot.status == .downloading)
        #expect(snapshot.backend == .emby)
        #expect(snapshot.lane == .compatibleRemux)
        #expect(snapshot.resumeMode == .staticByteRange)
        #expect(snapshot.isServerPreparedVersion)
        #expect(snapshot.bytes == 42)
        #expect(snapshot.progress == 0.5)
    }

    @Test("Persisted phase separates terminal and active durable statuses")
    func persistedPhase() {
        #expect(DownloadJobSnapshot(record: record(status: .queued)).persistedPhase == .queued)
        #expect(DownloadJobSnapshot(record: record(status: .preparing)).persistedPhase == .activeServerPrep)
        #expect(DownloadJobSnapshot(record: record(status: .downloading, bytes: 0)).persistedPhase == .queued)
        #expect(DownloadJobSnapshot(record: record(status: .downloading, bytes: 10)).persistedPhase == .activeTransfer)
        #expect(DownloadJobSnapshot(record: record(status: .complete)).persistedPhase == .complete(isUnverified: false))
        #expect(DownloadJobSnapshot(record: record(status: .unverified)).persistedPhase == .complete(isUnverified: true))
        #expect(DownloadJobSnapshot(record: record(status: .failed)).persistedPhase == .failed(isRetrying: false))
        #expect(DownloadJobSnapshot(record: record(status: .paused)).persistedPhase == .paused)
    }

    @Test("Phase active-work classification excludes terminal and waiting phases")
    func activeWorkClassification() {
        #expect(DownloadJobPhase.queued.isActiveWork)
        #expect(DownloadJobPhase.activeTransfer.isActiveWork)
        #expect(DownloadJobPhase.serverPrepQueued.isActiveWork)
        #expect(!DownloadJobPhase.paused.isActiveWork)
        #expect(!DownloadJobPhase.failed(isRetrying: true).isActiveWork)
        #expect(!DownloadJobPhase.complete(isUnverified: true).isActiveWork)
        #expect(!DownloadJobPhase.waitingForBackend.isActiveWork)
    }
}
