import Foundation
import Testing
@testable import PMSKit

@Suite("Download retry policy")
struct DownloadRetryPolicyTests {
    @Test("Paused Emby existing-version static partial promotes before backend retry")
    func pausedEmbyExistingVersionStaticPartialPromotes() throws {
        let url = URL(fileURLWithPath: "/tmp/visionplay-partial.mp4")
        let metadata = OfflineMetadata(ratingKey: "emby:item-1",
                                       title: "Offline Title",
                                       type: "movie",
                                       mediaSourceID: "converted-source",
                                       downloadLane: .original,
                                       resumeMode: .staticByteRange,
                                       serverPreparedVersion: true)
        let record = DownloadRecord(ratingKey: "emby:item-1",
                                    title: "Offline Title",
                                    localURL: url,
                                    bytes: 15 * 1_024 * 1_024,
                                    progress: 0.12,
                                    status: .paused,
                                    metadata: metadata)

        #expect(DownloadRetryPolicy.shouldPromotePausedStaticPartial(record, fileExists: { $0 == url }))
    }

    @Test("Does not promote live forward-only or missing partial rows")
    func doesNotPromoteUnsafeRows() throws {
        let url = URL(fileURLWithPath: "/tmp/visionplay-live.ts")
        let liveMetadata = OfflineMetadata(ratingKey: "emby:item-2",
                                           title: "Live Title",
                                           type: "movie",
                                           downloadLane: .optimize,
                                           resumeMode: .liveForwardOnly)
        let liveRecord = DownloadRecord(ratingKey: "emby:item-2",
                                        title: "Live Title",
                                        localURL: url,
                                        bytes: 15 * 1_024 * 1_024,
                                        progress: 0.12,
                                        status: .paused,
                                        metadata: liveMetadata)
        #expect(!DownloadRetryPolicy.shouldPromotePausedStaticPartial(liveRecord, fileExists: { _ in true }))

        let staticRecordWithoutFile = DownloadRecord(ratingKey: "emby:item-3",
                                                     title: "Missing Partial",
                                                     localURL: url,
                                                     bytes: 15 * 1_024 * 1_024,
                                                     progress: 0.12,
                                                     status: .paused,
                                                     metadata: OfflineMetadata(ratingKey: "emby:item-3",
                                                                               title: "Missing Partial",
                                                                               type: "movie",
                                                                               downloadLane: .original,
                                                                               resumeMode: .staticByteRange))
        #expect(!DownloadRetryPolicy.shouldPromotePausedStaticPartial(staticRecordWithoutFile, fileExists: { _ in false }))
    }

    @Test("Complete or unstarted static rows do not promote")
    func completeOrUnstartedRowsDoNotPromote() throws {
        let metadata = OfflineMetadata(ratingKey: "emby:item-4",
                                       title: "Static",
                                       type: "movie",
                                       downloadLane: .original,
                                       resumeMode: .staticByteRange)
        let url = URL(fileURLWithPath: "/tmp/static.mp4")
        let complete = DownloadRecord(ratingKey: "emby:item-4",
                                      title: "Static",
                                      localURL: url,
                                      bytes: 10_000,
                                      progress: 1.0,
                                      status: .paused,
                                      metadata: metadata)
        let unstarted = DownloadRecord(ratingKey: "emby:item-4",
                                       title: "Static",
                                       localURL: url,
                                       bytes: 0,
                                       progress: 0,
                                       status: .paused,
                                       metadata: metadata)

        #expect(!DownloadRetryPolicy.shouldPromotePausedStaticPartial(complete, fileExists: { _ in true }))
        #expect(!DownloadRetryPolicy.shouldPromotePausedStaticPartial(unstarted, fileExists: { _ in true }))
    }
    @Test("Stale queued static partial demotes only when no live task owns it")
    func staleQueuedStaticPartialDemotesOnlyWhenInactive() throws {
        let url = URL(fileURLWithPath: "/tmp/visionplay-queued-partial.mp4")
        let metadata = OfflineMetadata(ratingKey: "emby:item-queued",
                                       title: "Queued Partial",
                                       type: "movie",
                                       mediaSourceID: "converted-source",
                                       downloadLane: .original,
                                       resumeMode: .staticByteRange,
                                       serverPreparedVersion: true)
        let record = DownloadRecord(ratingKey: "emby:item-queued",
                                    title: "Queued Partial",
                                    localURL: url,
                                    bytes: 25 * 1_024 * 1_024,
                                    progress: 0.25,
                                    status: .queued,
                                    metadata: metadata)

        #expect(DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(record, isActive: false, fileExists: { $0 == url }))
        #expect(!DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(record, isActive: true, fileExists: { $0 == url }))
        #expect(!DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(record, isActive: false, fileExists: { _ in false }))
    }

}
