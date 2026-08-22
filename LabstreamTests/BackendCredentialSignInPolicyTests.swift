import Testing
@testable import Labstream

@Suite("Backend credential sign-in policy")
struct BackendCredentialSignInPolicyTests {
    @Test func jellyfinAllowsPasswordlessAccount() {
        #expect(BackendCredentialSignInPolicy.jellyfin.allowsSubmission(
            server: " https://jellyfin.example.test ",
            username: " viewer ",
            password: ""))
    }

    @Test func jellyfinStillRequiresServerAndUsername() {
        #expect(!BackendCredentialSignInPolicy.jellyfin.allowsSubmission(
            server: "   ", username: "viewer", password: ""))
        #expect(!BackendCredentialSignInPolicy.jellyfin.allowsSubmission(
            server: "https://jellyfin.example.test", username: "\n", password: ""))
    }

    @Test func embyStillRequiresPassword() {
        #expect(!BackendCredentialSignInPolicy.emby.allowsSubmission(
            server: "https://emby.example.test", username: "viewer", password: ""))
        #expect(!BackendCredentialSignInPolicy.emby.allowsSubmission(
            server: "https://emby.example.test", username: "viewer", password: " \n "))
        #expect(BackendCredentialSignInPolicy.emby.allowsSubmission(
            server: "https://emby.example.test", username: "viewer", password: "secret"))
    }
}
