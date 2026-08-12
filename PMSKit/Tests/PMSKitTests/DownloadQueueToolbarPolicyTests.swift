import Testing
@testable import PMSKit

@Suite("Download queue toolbar policy")
struct DownloadQueueToolbarPolicyTests {

    @Test("active downloads show Pause All")
    func activeDownloadsShowPauseAll() throws {
        for active in [DownloadStatus.queued, .preparing, .downloading] {
            let action = try #require(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                                        statuses: [active]))
            #expect(action == .pauseQueue)
            #expect(action.title == "Pause All")
            #expect(action.systemImage == "pause.circle")
        }
    }

    @Test("idle incomplete downloads show Resume All")
    func idleIncompleteDownloadsShowResumeAll() throws {
        for incomplete in [DownloadStatus.paused, .failed] {
            let action = try #require(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                                        statuses: [incomplete]))
            #expect(action == .resumeQueue)
            #expect(action.title == "Resume All")
            #expect(action.systemImage == "play.circle")
        }
    }

    @Test("idle incomplete downloads dominate active mixed state")
    func idleIncompleteDownloadsDominateActiveMixedState() {
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: [.paused, .downloading]) == .resumeQueue)
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: [.failed, .downloading]) == .resumeQueue)
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: [.paused, .queued]) == .resumeQueue)
    }

    @Test("queue-paused state always shows Resume All")
    func queuePausedAlwaysShowsResumeAll() {
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: true,
                                                  statuses: [DownloadStatus.complete, .failed]) == .resumeQueue)
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: true,
                                                  statuses: [DownloadStatus.queued, .preparing, .downloading]) == .resumeQueue)
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: true,
                                                  statuses: []) == .resumeQueue)
    }

    @Test("finished rows with running queue hide toolbar action")
    func finishedRowsWithRunningQueueHideToolbarAction() {
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: [DownloadStatus.complete, .unverified]) == nil)
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: []) == nil)
    }

    @Test("resume queue retry target policy is memoryless")
    func resumeQueueRetryTargetPolicyIsMemoryless() {
        #expect(DownloadQueueToolbarPolicy.shouldRetryWhenResumingQueue(.paused))
        #expect(DownloadQueueToolbarPolicy.shouldRetryWhenResumingQueue(.failed))

        #expect(!DownloadQueueToolbarPolicy.shouldRetryWhenResumingQueue(.queued))
        #expect(!DownloadQueueToolbarPolicy.shouldRetryWhenResumingQueue(.preparing))
        #expect(!DownloadQueueToolbarPolicy.shouldRetryWhenResumingQueue(.downloading))
        #expect(!DownloadQueueToolbarPolicy.shouldRetryWhenResumingQueue(.complete))
        #expect(!DownloadQueueToolbarPolicy.shouldRetryWhenResumingQueue(.unverified))
    }
}
