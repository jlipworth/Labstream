import Foundation
import Testing
@testable import PMSKit

@Suite("Server-prep refresh policy")
struct ServerPrepRefreshPolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-server-prep-refresh.mp4")

    private func record(key: String,
                        status: DownloadStatus,
                        backend: DownloadBackendKind,
                        lane: DownloadLane,
                        resumeMode: DownloadResumeMode,
                        bytes: Int = 0,
                        progress: Double = 0,
                        optimizeTargetName: String? = nil,
                        embyJobID: Int? = nil) -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: key, backend: backend)
        let metadata = OfflineMetadata(ratingKey: ratingKey,
                                       title: "Title",
                                       type: "movie",
                                       optimizeTargetName: optimizeTargetName,
                                       backendKind: backend,
                                       downloadLane: lane,
                                       resumeMode: resumeMode,
                                       embyConvertJobID: embyJobID)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              bytes: bytes,
                              progress: progress,
                              status: status,
                              metadata: metadata)
    }

    @Test("Plex prep rows are candidates only before poller attachment")
    func plexCandidatesRespectPollerAttachment() {
        let plex = record(key: "1",
                          status: .queued,
                          backend: .plex,
                          lane: .optimize,
                          resumeMode: .serverPrepThenStatic,
                          optimizeTargetName: "TV - 8 Mbps")

        #expect(ServerPrepRefreshPolicy.isUnattachedServerPrepRow(plex,
                                                                  hasPlexPoller: false,
                                                                  isActiveJob: false))
        #expect(!ServerPrepRefreshPolicy.isUnattachedServerPrepRow(plex,
                                                                   hasPlexPoller: true,
                                                                   isActiveJob: false))

        let handedOff = record(key: "2",
                               status: .queued,
                               backend: .plex,
                               lane: .optimize,
                               resumeMode: .staticByteRange,
                               optimizeTargetName: "TV - 8 Mbps")
        #expect(!ServerPrepRefreshPolicy.isUnattachedServerPrepRow(handedOff,
                                                                   hasPlexPoller: false,
                                                                   isActiveJob: false))
    }

    @Test("Emby convert candidates require a persistent job and no active poller")
    func embyCandidatesRequireJobAndInactiveSlot() {
        let emby = record(key: "3",
                          status: .preparing,
                          backend: .emby,
                          lane: .optimize,
                          resumeMode: .serverPrepThenStatic,
                          embyJobID: 42)

        #expect(ServerPrepRefreshPolicy.shouldPollEmbyServerPrepWhileQueuePaused(emby))
        #expect(ServerPrepRefreshPolicy.isUnattachedServerPrepRow(emby,
                                                                  hasPlexPoller: false,
                                                                  isActiveJob: false))
        #expect(!ServerPrepRefreshPolicy.isUnattachedServerPrepRow(emby,
                                                                   hasPlexPoller: false,
                                                                   isActiveJob: true))

        let missingJob = record(key: "4",
                                status: .preparing,
                                backend: .emby,
                                lane: .optimize,
                                resumeMode: .serverPrepThenStatic)
        #expect(!ServerPrepRefreshPolicy.shouldPollEmbyServerPrepWhileQueuePaused(missingJob))
        #expect(!ServerPrepRefreshPolicy.isUnattachedServerPrepRow(missingJob,
                                                                   hasPlexPoller: false,
                                                                   isActiveJob: false))
    }

    @Test("Queue pause parks Plex prep while still kicking Emby conversion polling")
    func queuePausedPlanSplitsParkedAndPollableRows() {
        let plex = record(key: "5",
                          status: .queued,
                          backend: .plex,
                          lane: .optimize,
                          resumeMode: .serverPrepThenStatic,
                          optimizeTargetName: "TV - 8 Mbps")
        let emby = record(key: "6",
                          status: .preparing,
                          backend: .emby,
                          lane: .optimize,
                          resumeMode: .serverPrepThenStatic,
                          embyJobID: 99)

        let plan = ServerPrepRefreshPolicy.refreshPlan(records: [plex, emby],
                                                       isQueuePaused: true,
                                                       refreshKickScheduled: false,
                                                       refreshKickRecent: false,
                                                       hasPlexPoller: { _ in false },
                                                       isActiveJob: { _ in false })

        #expect(plan.parkWhileQueuePausedKeys == [plex.ratingKey])
        #expect(plan.pollEmbyWhileQueuePausedKeys == [emby.ratingKey])
        #expect(plan.shouldScheduleKick)
        #expect(plan.kickEmbyOnly)
        #expect(plan.parkedCounts == .init(plex: 1, emby: 0))
        #expect(plan.kickCounts == .init(plex: 0, emby: 1))
    }

    @Test("Refresh kick is debounced and counts all unattached rows while queue is running")
    func runningQueuePlanDebouncesKick() {
        let plex = record(key: "7",
                          status: .queued,
                          backend: .plex,
                          lane: .optimize,
                          resumeMode: .serverPrepThenStatic,
                          optimizeTargetName: "TV - 8 Mbps")
        let emby = record(key: "8",
                          status: .preparing,
                          backend: .emby,
                          lane: .optimize,
                          resumeMode: .serverPrepThenStatic,
                          embyJobID: 101)

        let plan = ServerPrepRefreshPolicy.refreshPlan(records: [plex, emby],
                                                       isQueuePaused: false,
                                                       refreshKickScheduled: true,
                                                       refreshKickRecent: false,
                                                       hasPlexPoller: { _ in false },
                                                       isActiveJob: { _ in false })

        #expect(plan.candidateKeys == [plex.ratingKey, emby.ratingKey])
        #expect(!plan.shouldScheduleKick)
        #expect(!plan.kickEmbyOnly)
        #expect(plan.kickCounts == .init(plex: 1, emby: 1))
    }
}
