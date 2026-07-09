import Foundation
import Testing
@testable import PMSKit

@Suite("Background range completion policy")
struct BackgroundRangeCompletionPolicyTests {
    @Test("Successful range completions are handled by didFinishDownloading")
    func successAlreadyHandled() {
        #expect(BackgroundRangeCompletionPolicy.disposition(
            hasError: false,
            errorCode: nil,
            hasRequest: true
        ) == .successAlreadyHandled)
    }

    @Test("Cancelled range tasks do not fail or pause the row")
    func cancelled() {
        #expect(BackgroundRangeCompletionPolicy.disposition(
            hasError: true,
            errorCode: NSURLErrorCancelled,
            hasRequest: true
        ) == .cancelled)
    }

    @Test("Adopted failed remainders need backend request rebuild")
    func adoptedFailureNeedsRequest() {
        #expect(BackgroundRangeCompletionPolicy.disposition(
            hasError: true,
            errorCode: NSURLErrorNetworkConnectionLost,
            hasRequest: false
        ) == .requestNeeded(.requestRebuildNeeded))
    }

    @Test("In-memory failed remainders become resumable pauses")
    func inMemoryFailurePauses() {
        #expect(BackgroundRangeCompletionPolicy.disposition(
            hasError: true,
            errorCode: NSURLErrorNetworkConnectionLost,
            hasRequest: true
        ) == .pauseResumable)
    }
}
