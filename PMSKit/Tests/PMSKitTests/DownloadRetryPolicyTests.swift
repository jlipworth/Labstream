import Foundation
import Testing
@testable import PMSKit

@Suite("Download retry policy")
struct DownloadRetryPolicyTests {
    @Test("Plex server-prep candidate requires queued zero-byte server-prep mode")
    func plexServerPrepCandidateRequiresServerPrepMode() throws {
        let url = URL(fileURLWithPath: "/tmp/visionplay-plex-prep.mp4")
        let prepMetadata = OfflineMetadata(ratingKey: "12345",
                                           title: "Plex Prep",
                                           type: "movie",
                                           optimizeTargetName: "Original",
                                           downloadLane: .optimize,
                                           resumeMode: .serverPrepThenStatic)
        let prepRecord = DownloadRecord(ratingKey: "12345",
                                        title: "Plex Prep",
                                        localURL: url,
                                        status: .queued,
                                        metadata: prepMetadata)

        #expect(DownloadRetryPolicy.isPlexServerPrepResumeCandidate(prepRecord))

        var handoffMetadata = prepMetadata
        handoffMetadata.resumeMode = .staticByteRange
        handoffMetadata.serverPreparedVersion = true
        let handoffRecord = DownloadRecord(ratingKey: "12345",
                                           title: "Plex Prep",
                                           localURL: url,
                                           status: .queued,
                                           metadata: handoffMetadata)

        #expect(!DownloadRetryPolicy.isPlexServerPrepResumeCandidate(handoffRecord))
    }

    @Test("Plex server-prep candidate rejects non-Plex and non-zero rows")
    func plexServerPrepCandidateRejectsWrongBackendOrProgress() throws {
        let url = URL(fileURLWithPath: "/tmp/visionplay-plex-prep-nonzero.mp4")
        let plexMetadata = OfflineMetadata(ratingKey: "12345",
                                           title: "Plex Prep",
                                           type: "movie",
                                           optimizeTargetName: "Original",
                                           downloadLane: .optimize,
                                           resumeMode: .serverPrepThenStatic)
        let downloading = DownloadRecord(ratingKey: "12345",
                                         title: "Plex Prep",
                                         localURL: url,
                                         bytes: 1,
                                         progress: 0.01,
                                         status: .queued,
                                         metadata: plexMetadata)
        #expect(!DownloadRetryPolicy.isPlexServerPrepResumeCandidate(downloading))

        let jellyfinMetadata = OfflineMetadata(ratingKey: "jellyfin:12345",
                                               title: "Jellyfin Prep",
                                               type: "movie",
                                               optimizeTargetName: "1080p",
                                               backendKind: .jellyfin,
                                               downloadLane: .optimize,
                                               resumeMode: .serverPrepThenStatic)
        let jellyfin = DownloadRecord(ratingKey: "jellyfin:12345",
                                      title: "Jellyfin Prep",
                                      localURL: url,
                                      status: .queued,
                                      metadata: jellyfinMetadata)
        #expect(!DownloadRetryPolicy.isPlexServerPrepResumeCandidate(jellyfin))
    }

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

    @Test("Plex static partial uses same stale queued demotion policy")
    func plexStaticPartialUsesSamePolicy() throws {
        let url = URL(fileURLWithPath: "/tmp/visionplay-plex-partial.mp4")
        let metadata = OfflineMetadata(ratingKey: "12345",
                                       title: "Plex Static",
                                       type: "movie",
                                       downloadLane: .original,
                                       resumeMode: .staticByteRange)
        let record = DownloadRecord(ratingKey: "12345",
                                    title: "Plex Static",
                                    localURL: url,
                                    bytes: 10 * 1_024 * 1_024,
                                    progress: 0.10,
                                    status: .queued,
                                    metadata: metadata)

        #expect(DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(record, isActive: false, fileExists: { $0 == url }))
    }

}
