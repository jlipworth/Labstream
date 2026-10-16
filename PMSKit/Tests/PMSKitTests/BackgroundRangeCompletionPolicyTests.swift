import Foundation
import Testing
@testable import PMSKit

@Suite("Background range completion policy")
struct BackgroundRangeCompletionPolicyTests {
    @Test("Range completion maps to the expected disposition", arguments: [
        // Successful range completions are handled by didFinishDownloading.
        (false, nil, true, .successAlreadyHandled),
        // Cancelled range tasks do not fail or pause the row.
        (true, NSURLErrorCancelled, true, .cancelled),
        // Adopted failed remainders need backend request rebuild.
        (true, NSURLErrorNetworkConnectionLost, false, .requestNeeded(.requestRebuildNeeded)),
        // In-memory failed remainders become resumable pauses.
        (true, NSURLErrorNetworkConnectionLost, true, .pauseResumable),
    ] as [(Bool, Int?, Bool, BackgroundRangeCompletionDisposition)])
    func disposition(hasError: Bool,
                     errorCode: Int?,
                     hasRequest: Bool,
                     expected: BackgroundRangeCompletionDisposition) {
        #expect(BackgroundRangeCompletionPolicy.disposition(
            hasError: hasError,
            errorCode: errorCode,
            hasRequest: hasRequest
        ) == expected)
    }
}
