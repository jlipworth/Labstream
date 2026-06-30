import Testing
@testable import PMSKit

@Suite("Download retry preparation policy")
struct DownloadRetryPreparationPolicyTests {
    @Test("Manual static resume while queue-paused is explicit")
    func manualStaticResumeWhileQueuePaused() {
        #expect(DownloadRetryPreparationPolicy.isManualStaticResumeWhileQueuePaused(isQueuePaused: true,
                                                                                   isStaticRangeRecord: true,
                                                                                   status: .paused))
        #expect(DownloadRetryPreparationPolicy.isManualStaticResumeWhileQueuePaused(isQueuePaused: true,
                                                                                   isStaticRangeRecord: true,
                                                                                   status: .failed))
        #expect(DownloadRetryPreparationPolicy.isManualStaticResumeWhileQueuePaused(isQueuePaused: true,
                                                                                   isStaticRangeRecord: true,
                                                                                   status: .queued))
        #expect(!DownloadRetryPreparationPolicy.isManualStaticResumeWhileQueuePaused(isQueuePaused: false,
                                                                                    isStaticRangeRecord: true,
                                                                                    status: .paused))
        #expect(!DownloadRetryPreparationPolicy.isManualStaticResumeWhileQueuePaused(isQueuePaused: true,
                                                                                    isStaticRangeRecord: false,
                                                                                    status: .paused))
        #expect(!DownloadRetryPreparationPolicy.isManualStaticResumeWhileQueuePaused(isQueuePaused: true,
                                                                                    isStaticRangeRecord: true,
                                                                                    status: .downloading))
    }

    @Test("Paused Emby convert rows re-enter server prep polling")
    func pausedEmbyConvertResume() {
        #expect(DownloadRetryPreparationPolicy.shouldResumePausedEmbyConvert(status: .paused,
                                                                            resumeMode: .serverPrepThenStatic,
                                                                            isEmbyRecord: true,
                                                                            hasEmbyConvertJobID: true))
        #expect(!DownloadRetryPreparationPolicy.shouldResumePausedEmbyConvert(status: .paused,
                                                                             resumeMode: .staticByteRange,
                                                                             isEmbyRecord: true,
                                                                             hasEmbyConvertJobID: true))
        #expect(!DownloadRetryPreparationPolicy.shouldResumePausedEmbyConvert(status: .paused,
                                                                             resumeMode: .serverPrepThenStatic,
                                                                             isEmbyRecord: true,
                                                                             hasEmbyConvertJobID: false))
    }

    @Test("Persisted resume data requires a paused row and a usable blob")
    func persistedResumeDataGate() {
        #expect(DownloadRetryPreparationPolicy.shouldResumePersistedURLSessionData(status: .paused,
                                                                                  supportsPersistedResumeData: true,
                                                                                  hasResumeData: true))
        #expect(!DownloadRetryPreparationPolicy.shouldResumePersistedURLSessionData(status: .failed,
                                                                                   supportsPersistedResumeData: true,
                                                                                   hasResumeData: true))
        #expect(!DownloadRetryPreparationPolicy.shouldResumePersistedURLSessionData(status: .paused,
                                                                                   supportsPersistedResumeData: false,
                                                                                   hasResumeData: true))
        #expect(!DownloadRetryPreparationPolicy.shouldResumePersistedURLSessionData(status: .paused,
                                                                                   supportsPersistedResumeData: true,
                                                                                   hasResumeData: false))
    }

    @Test("Paused Plex server prep reattaches only before static handoff")
    func pausedPlexServerPrepGate() {
        #expect(DownloadRetryPreparationPolicy.shouldResumePausedPlexServerPrep(status: .paused,
                                                                               resumeMode: .serverPrepThenStatic,
                                                                               isJellyfinRecord: false,
                                                                               isEmbyRecord: false,
                                                                               optimizeTargetName: "TV - 8 Mbps",
                                                                               hasIncompleteStaticPartial: false))
        #expect(!DownloadRetryPreparationPolicy.shouldResumePausedPlexServerPrep(status: .paused,
                                                                                resumeMode: .serverPrepThenStatic,
                                                                                isJellyfinRecord: false,
                                                                                isEmbyRecord: false,
                                                                                optimizeTargetName: "TV - 8 Mbps",
                                                                                hasIncompleteStaticPartial: true))
        #expect(!DownloadRetryPreparationPolicy.shouldResumePausedPlexServerPrep(status: .paused,
                                                                                resumeMode: .serverPrepThenStatic,
                                                                                isJellyfinRecord: false,
                                                                                isEmbyRecord: true,
                                                                                optimizeTargetName: "TV - 8 Mbps",
                                                                                hasIncompleteStaticPartial: false))
        #expect(!DownloadRetryPreparationPolicy.shouldResumePausedPlexServerPrep(status: .paused,
                                                                                resumeMode: .serverPrepThenStatic,
                                                                                isJellyfinRecord: false,
                                                                                isEmbyRecord: false,
                                                                                optimizeTargetName: "",
                                                                                hasIncompleteStaticPartial: false))
    }

    @Test("Retry async work stops once marker is removed, row disappears, or row is paused")
    func retryAttemptCanContinue() {
        #expect(DownloadRetryPreparationPolicy.attemptCanContinue(isRetrying: true,
                                                                  rowIsPresent: true,
                                                                  rowStatus: .failed))
        #expect(!DownloadRetryPreparationPolicy.attemptCanContinue(isRetrying: false,
                                                                   rowIsPresent: true,
                                                                   rowStatus: .failed))
        #expect(!DownloadRetryPreparationPolicy.attemptCanContinue(isRetrying: true,
                                                                   rowIsPresent: false,
                                                                   rowStatus: nil))
        #expect(!DownloadRetryPreparationPolicy.attemptCanContinue(isRetrying: true,
                                                                   rowIsPresent: true,
                                                                   rowStatus: .paused))
    }
}
