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

    @Test("paused downloads show Resume Queue")
    func pausedDownloadsShowResumeQueue() throws {
        let action = try #require(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                                    statuses: [.paused]))
        #expect(action == .resumeQueue)
        #expect(action.title == "Resume Queue")
        #expect(action.systemImage == "play.circle")
    }

    @Test("active downloads dominate paused mixed state")
    func activeDownloadsDominatePausedMixedState() {
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: [.paused, .downloading]) == .pauseQueue)
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: true,
                                                  statuses: [.paused, .queued]) == .pauseQueue)
    }

    @Test("queue-paused state with no active work shows Resume Queue")
    func queuePausedWithoutActiveWorkShowsResumeQueue() {
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: true,
                                                  statuses: [DownloadStatus.complete, .failed]) == .resumeQueue)
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: true,
                                                  statuses: []) == .resumeQueue)
    }

    @Test("terminal rows with running queue hide toolbar action")
    func terminalRowsWithRunningQueueHideToolbarAction() {
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: [DownloadStatus.complete, .unverified, .failed]) == nil)
        #expect(DownloadQueueToolbarPolicy.action(isQueuePaused: false,
                                                  statuses: []) == nil)
    }
}
