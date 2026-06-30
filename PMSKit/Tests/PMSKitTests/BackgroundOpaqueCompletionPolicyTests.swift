import Foundation
import Testing
@testable import PMSKit

@Suite("Background opaque completion policy")
struct BackgroundOpaqueCompletionPolicyTests {

    @Test("Cancellation is not a failed transfer")
    func cancelled() {
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: NSURLErrorCancelled,
            hasResumeData: true,
            supportsPersistedResumeData: true
        ) == .cancelled)
    }

    @Test("Resume data pauses persisted-resume-safe static lanes")
    func pauseWithResumeData() {
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            supportsPersistedResumeData: true
        ) == .pauseWithResumeData)
    }

    @Test("Forward-only streams fail even if URLSession provides resume data")
    func failNonResumableStream() {
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            supportsPersistedResumeData: false
        ) == .failNonResumableStream)
    }

    @Test("Non-cancelled errors without resume data fail normally")
    func failWithoutResumeData() {
        #expect(BackgroundOpaqueCompletionPolicy.disposition(
            errorCode: NSURLErrorCannotConnectToHost,
            hasResumeData: false,
            supportsPersistedResumeData: true
        ) == .fail)
    }
}
