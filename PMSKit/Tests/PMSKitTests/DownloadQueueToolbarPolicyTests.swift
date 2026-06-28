import Testing
@testable import PMSKit

@Suite("Download queue toolbar policy")
struct DownloadQueueToolbarPolicyTests {

    @Test("active downloads show Pause Queue")
    func activeDownloadsShowPauseQueue() throws {
        for active in [DownloadStatus.queued, .preparing, .downloading] {
            let action = try #require(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                                        statuses: [active]))
            #expect(action == .pauseQueue)
            #expect(action.title == "Pause Queue")
            #expect(action.systemImage == "pause.circle")
        }
    }

    @Test("idle incomplete downloads show Resume Queue")
    func idleIncompleteDownloadsShowResumeQueue() throws {
        for incomplete in [DownloadStatus.paused, .failed] {
            let action = try #require(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                                        statuses: [incomplete]))
            #expect(action == .resumeQueue)
            #expect(action.title == "Resume Queue")
            #expect(action.systemImage == "play.circle")
        }
    }

    @Test("active downloads dominate incomplete mixed state")
    func activeDownloadsDominateIncompleteMixedState() {
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: [.paused, .downloading]) == .pauseQueue)
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: [.failed, .downloading]) == .pauseQueue)
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: [.paused, .queued]) == .pauseQueue)
    }

    @Test("queue-paused state always shows Resume Queue")
    func queuePausedAlwaysShowsResumeQueue() {
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
