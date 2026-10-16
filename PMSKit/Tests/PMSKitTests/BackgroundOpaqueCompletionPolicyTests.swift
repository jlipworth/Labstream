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
}
