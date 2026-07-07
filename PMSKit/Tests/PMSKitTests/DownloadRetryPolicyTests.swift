import Foundation
import Testing
@testable import PMSKit

@Suite("Download retry policy")
struct DownloadRetryPolicyTests {
    @Test("Plex server-prep candidate requires queued zero-byte server-prep mode")
    func plexServerPrepCandidateRequiresServerPrepMode() throws {
        let url = URL(fileURLWithPath: "/tmp/labstream-plex-prep.mp4")
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
        let url = URL(fileURLWithPath: "/tmp/labstream-plex-prep-nonzero.mp4")
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
        let url = URL(fileURLWithPath: "/tmp/labstream-partial.mp4")
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

        #expect(DownloadRetryPolicy.shouldPromotePausedStaticPartial(
            record,
            fileExists: { $0 == url },
            fileSize: { $0 == url ? 15 * 1_024 * 1_024 : nil }
        ))
    }

    @Test("Does not promote live forward-only or missing partial rows")
    func doesNotPromoteUnsafeRows() throws {
        let url = URL(fileURLWithPath: "/tmp/labstream-live.ts")
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
        #expect(!DownloadRetryPolicy.shouldPromotePausedStaticPartial(
            liveRecord,
            fileExists: { _ in true },
            fileSize: { _ in 15 * 1_024 * 1_024 }
        ))

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
        #expect(!DownloadRetryPolicy.shouldPromotePausedStaticPartial(
            staticRecordWithoutFile,
            fileExists: { _ in false },
            fileSize: { _ in nil }
        ))
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
                                      status: .complete,
                                      metadata: metadata)
        let unstarted = DownloadRecord(ratingKey: "emby:item-4",
                                       title: "Static",
                                       localURL: url,
                                       bytes: 0,
                                       progress: 0,
                                       status: .paused,
                                       metadata: metadata)

        #expect(!DownloadRetryPolicy.shouldPromotePausedStaticPartial(
            complete,
            fileExists: { _ in true },
            fileSize: { _ in 10_000 }
        ))
        #expect(!DownloadRetryPolicy.shouldPromotePausedStaticPartial(
            unstarted,
            fileExists: { _ in true },
            fileSize: { _ in 0 }
        ))
    }

    @Test("Paused full durable static file promotes so finalization can run")
    func pausedFullDurableStaticFilePromotesForFinalization() throws {
        let url = URL(fileURLWithPath: "/tmp/labstream-full-but-unfinalized.mp4")
        let metadata = OfflineMetadata(ratingKey: "emby:item-full",
                                       title: "Full",
                                       type: "movie",
                                       downloadLane: .original,
                                       resumeMode: .staticByteRange)
        let record = DownloadRecord(ratingKey: "emby:item-full",
                                    title: "Full",
                                    localURL: url,
                                    bytes: 10_000,
                                    progress: 1.0,
                                    status: .paused,
                                    metadata: metadata)

        #expect(DownloadRetryPolicy.shouldPromotePausedStaticPartial(
            record,
            fileExists: { _ in true },
            fileSize: { _ in 10_000 }
        ))
    }

    @Test("Optimistic row bytes without durable partial do not promote")
    func optimisticRowBytesWithoutDurablePartialDoNotPromote() throws {
        let url = URL(fileURLWithPath: "/tmp/labstream-optimistic-temp.mp4")
        let record = DownloadRecord(ratingKey: "emby:item-optimistic",
                                    title: "Optimistic",
                                    localURL: url,
                                    bytes: 64 * 1_024 * 1_024,
                                    progress: 0.5,
                                    status: .paused,
                                    metadata: OfflineMetadata(ratingKey: "emby:item-optimistic",
                                                              title: "Optimistic",
                                                              type: "movie",
                                                              downloadLane: .original,
                                                              resumeMode: .staticByteRange))

        #expect(!DownloadRetryPolicy.shouldPromotePausedStaticPartial(
            record,
            fileExists: { $0 == url },
            fileSize: { _ in 0 }
        ))
    }

    @Test("Durable partial promotes even when persisted row bytes are stale")
    func durablePartialPromotesWhenRowBytesAreStale() throws {
        let url = URL(fileURLWithPath: "/tmp/labstream-stale-row.mp4")
        let record = DownloadRecord(ratingKey: "emby:item-stale",
                                    title: "Stale Row",
                                    localURL: url,
                                    bytes: 0,
                                    progress: 0,
                                    status: .paused,
                                    metadata: OfflineMetadata(ratingKey: "emby:item-stale",
                                                              title: "Stale Row",
                                                              type: "movie",
                                                              downloadLane: .original,
                                                              resumeMode: .staticByteRange))

        #expect(DownloadRetryPolicy.shouldPromotePausedStaticPartial(
            record,
            fileExists: { $0 == url },
            fileSize: { _ in 8 * 1_024 * 1_024 }
        ))
    }

    @Test("Stale queued static partial demotes only when no live task owns it")
    func staleQueuedStaticPartialDemotesOnlyWhenInactive() throws {
        let url = URL(fileURLWithPath: "/tmp/labstream-queued-partial.mp4")
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

        #expect(DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(
            record,
            isActive: false,
            fileExists: { $0 == url },
            fileSize: { _ in 25 * 1_024 * 1_024 }
        ))
        #expect(!DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(
            record,
            isActive: true,
            fileExists: { $0 == url },
            fileSize: { _ in 25 * 1_024 * 1_024 }
        ))
        #expect(!DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(
            record,
            isActive: false,
            hasPendingResumeIntent: true,
            fileExists: { $0 == url },
            fileSize: { _ in 25 * 1_024 * 1_024 }
        ))
        #expect(!DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(
            record,
            isActive: false,
            fileExists: { _ in false },
            fileSize: { _ in nil }
        ))
    }

    @Test("Plex static partial uses same stale queued demotion policy")
    func plexStaticPartialUsesSamePolicy() throws {
        let url = URL(fileURLWithPath: "/tmp/labstream-plex-partial.mp4")
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

        #expect(DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(
            record,
            isActive: false,
            fileExists: { $0 == url },
            fileSize: { _ in 10 * 1_024 * 1_024 }
        ))
    }

}
