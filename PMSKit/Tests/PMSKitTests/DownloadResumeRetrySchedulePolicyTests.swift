import Testing
@testable import PMSKit

@Suite("Download resume retry schedule policy")
struct DownloadResumeRetrySchedulePolicyTests {
    @Test("Cold-launch retry cadence stays bounded but long enough for backend hydration")
    func retryDelays() {
        #expect(DownloadResumeRetrySchedulePolicy.retryDelaysSeconds == [1.0, 5.0, 15.0, 30.0, 60.0])
    }

    @Test("Queue pause resumes only persistent Emby convert polling")
    func serverPrepAction() {
        #expect(DownloadResumeRetrySchedulePolicy.serverPrepAction(isQueuePaused: true)
                == .resumePendingEmbyConvertOnly)
        #expect(DownloadResumeRetrySchedulePolicy.serverPrepAction(isQueuePaused: false)
                == .resumePendingServerPrep)
    }
}
