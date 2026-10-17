import Foundation
import Testing
@testable import PMSKit

@Suite("Background opaque completion policy")
struct BackgroundOpaqueCompletionPolicyTests {

    @Test("Opaque completion maps to the expected disposition", arguments: [
        // Cancellation is not a failed transfer.
        (NSURLErrorCancelled, true, true, .cancelled),
        // Resume data pauses persisted-resume-safe static lanes.
        (NSURLErrorNetworkConnectionLost, true, true, .pauseWithResumeData),
        // Forward-only streams fail even if URLSession provides resume data.
        (NSURLErrorNetworkConnectionLost, true, false, .failNonResumableStream),
        // Non-cancelled errors without resume data fail normally.
        (NSURLErrorCannotConnectToHost, false, true, .fail),
    ] as [(Int, Bool, Bool, BackgroundOpaqueCompletionDisposition)])
    func disposition(errorCode: Int,
                     hasResumeData: Bool,
                     supportsPersistedResumeData: Bool,
                     expected: BackgroundOpaqueCompletionDisposition) {
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: errorCode,
            hasResumeData: hasResumeData,
            supportsPersistedResumeData: supportsPersistedResumeData
        ) == expected)
    }

    // B09: an OS-initiated -999 on the forward-only lane fails retryable with a real reason
    // instead of leaving the row `.downloading` with no task.
    @Test("A system-initiated cancel is a retryable interruption, never a silent cancel")
    func systemInitiatedCancelIsRetryableInterruption() {
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: NSURLErrorCancelled, hasResumeData: false,
            supportsPersistedResumeData: false,
            isSystemInitiatedCancel: true) == .failSystemInterrupted)
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: NSURLErrorCancelled, hasResumeData: true,
            supportsPersistedResumeData: false,
            isSystemInitiatedCancel: true) == .failSystemInterrupted)
        // A resume-safe lane keeps the blob as a resumable pause.
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: NSURLErrorCancelled, hasResumeData: true,
            supportsPersistedResumeData: true,
            isSystemInitiatedCancel: true) == .pauseWithResumeData)
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: NSURLErrorCancelled, hasResumeData: false,
            supportsPersistedResumeData: false,
            isSystemInitiatedCancel: false) == .cancelled)
    }

    @Test("Only a -999 carrying the background cancellation reason is system-initiated")
    func classifiesSystemInitiatedCancel() {
        let system = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [
            NSURLErrorBackgroundTaskCancelledReasonKey:
                NSURLErrorCancelledReasonBackgroundUpdatesDisabled,
        ])
        let app = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let other = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [
            NSURLErrorBackgroundTaskCancelledReasonKey:
                NSURLErrorCancelledReasonInsufficientSystemResources,
        ])
        #expect(BackgroundSystemCancellationPolicy.isSystemInitiatedCancel(system))
        #expect(!BackgroundSystemCancellationPolicy.isSystemInitiatedCancel(app))
        #expect(!BackgroundSystemCancellationPolicy.isSystemInitiatedCancel(other))
    }

    // B26: a full disk on the forward-only lane is storage-full, never a "will resume" pause, a
    // "can't resume" stream failure, or a generic "system code 640" failure.
    @Test("Out-of-space completions classify as storage-full before any other disposition")
    func outOfSpaceIsStorageFull() {
        for (hasResumeData, supports) in [(false, false), (true, false), (true, true)] {
            #expect(BackgroundOpaqueCompletionPolicy.disposition(
                errorCode: NSURLErrorCannotWriteToFile, hasResumeData: hasResumeData,
                supportsPersistedResumeData: supports, isOutOfSpace: true) == .failStorageFull)
        }
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: NSURLErrorCannotWriteToFile, hasResumeData: false,
            supportsPersistedResumeData: false, isOutOfSpace: false) == .fail)
    }
}

