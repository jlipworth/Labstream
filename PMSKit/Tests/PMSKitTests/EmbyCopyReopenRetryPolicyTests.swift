import Testing
@testable import PMSKit

@Suite struct EmbyCopyReopenRetryPolicyTests {
    private func retry(isEmby: Bool = true, copy: Bool = true, ceiling: Int = 0, approved: Bool = false,
                       used: Bool = false, terminal: Bool = false) -> Bool {
        EmbyCopyReopenRetryPolicy.shouldRetry(isEmby: isEmby, videoCopyEnforced: copy,
            bitrateCeilingKbps: ceiling, videoTranscodeApproved: approved,
            retryAlreadyUsed: used, failureIsTerminal: terminal)
    }

    @Test func retriesAVerifiedEmbyCopyFailureOnce() {
        #expect(retry())
        #expect(!retry(used: true))
    }

    @Test func leavesOtherLanesAndTerminalFailuresToTheExistingPath() {
        #expect(!retry(isEmby: false))
        #expect(!retry(copy: false))
        #expect(!retry(ceiling: 8_000))
        #expect(!retry(approved: true))
        #expect(!retry(terminal: true))
    }
}
