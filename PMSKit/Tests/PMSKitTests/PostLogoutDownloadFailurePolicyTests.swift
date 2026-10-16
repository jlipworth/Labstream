import Testing
@testable import PMSKit

@Suite("Post-logout download failure policy")
struct PostLogoutDownloadFailurePolicyTests {

    @Test func authStatusWithoutLiveSessionDefers() {
        #expect(PostLogoutDownloadFailurePolicy.disposition(httpStatus: 401, hasLiveSession: false) == .deferAwaitingSession)
        #expect(PostLogoutDownloadFailurePolicy.disposition(httpStatus: 403, hasLiveSession: false) == .deferAwaitingSession)
    }

    @Test func authStatusWhileStillSignedInStillFails() {
        // A genuine 401/403 while the session is live is a real error the user must see.
        #expect(PostLogoutDownloadFailurePolicy.disposition(httpStatus: 401, hasLiveSession: true) == .fail)
        #expect(PostLogoutDownloadFailurePolicy.disposition(httpStatus: 403, hasLiveSession: true) == .fail)
    }

    @Test func nonAuthStatusAlwaysFailsEvenWithoutSession() {
        // Only 401/403 are logout casualties; other failures are not remapped even if the session
        // happens to be absent at error time.
        for status in [200, 404, 416, 500, 502, 503] {
            #expect(PostLogoutDownloadFailurePolicy.disposition(httpStatus: status, hasLiveSession: false) == .fail)
            #expect(PostLogoutDownloadFailurePolicy.disposition(httpStatus: status, hasLiveSession: true) == .fail)
        }
    }

    @Test func deferrableAuthStatusSet() {
        #expect(PostLogoutDownloadFailurePolicy.isDeferrableAuthStatus(401))
        #expect(PostLogoutDownloadFailurePolicy.isDeferrableAuthStatus(403))
        #expect(!PostLogoutDownloadFailurePolicy.isDeferrableAuthStatus(400))
        #expect(!PostLogoutDownloadFailurePolicy.isDeferrableAuthStatus(404))
        #expect(!PostLogoutDownloadFailurePolicy.isDeferrableAuthStatus(500))
        #expect(!PostLogoutDownloadFailurePolicy.isDeferrableAuthStatus(200))
    }
}

@Suite("Terminal auth message mapping")
struct DownloadTerminalAuthMessagePolicyTests {
    @Test("Exact 401/403 terminal messages map to auth-dead")
    func authDeadMessages() {
        #expect(DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Server returned HTTP 401."))
        #expect(DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Server returned HTTP 403."))
    }

    @Test("Other terminal messages are never remapped")
    func nonAuthMessages() {
        #expect(!DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Server returned HTTP 404."))
        #expect(!DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Server returned HTTP 500."))
        #expect(!DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Server returned HTTP 401"))
        #expect(!DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage("Transfer timed out."))
        #expect(!DownloadTerminalAuthMessagePolicy.isAuthDeadTransferMessage(""))
    }
}
