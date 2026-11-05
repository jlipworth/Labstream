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

    // B09: an OS-initiated -999 (Background App Refresh off, insufficient resources, force quit)
    // is an interruption, not a user cancel: park the row at its durable checkpoint.
    @Test("A system-initiated cancel parks at the checkpoint instead of returning silently")
    func systemInitiatedCancelParks() {
        #expect(BackgroundRangeCompletionPolicy.disposition(
            hasError: true, errorCode: NSURLErrorCancelled, hasRequest: true,
            isSystemInitiatedCancel: true) == .parkSystemInterrupted)
        #expect(BackgroundRangeCompletionPolicy.disposition(
            hasError: true, errorCode: NSURLErrorCancelled, hasRequest: false,
            isSystemInitiatedCancel: true) == .parkSystemInterrupted)
        // App-initiated cancels (pause, cancel, supersede) stay silent.
        #expect(BackgroundRangeCompletionPolicy.disposition(
            hasError: true, errorCode: NSURLErrorCancelled, hasRequest: true,
            isSystemInitiatedCancel: false) == .cancelled)
    }
}

