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
