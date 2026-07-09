import Testing
@testable import PMSKit

struct CredentialValidationPolicyTests {
    @Test func classifiesOnly401AsInvalid() {
        #expect(CredentialValidationPolicy.decision(httpStatus: 200) == .valid)
        #expect(CredentialValidationPolicy.decision(httpStatus: 401) == .invalidCredential)
        #expect(CredentialValidationPolicy.decision(httpStatus: 403) == .preserveCredential)
        #expect(CredentialValidationPolicy.decision(httpStatus: 429) == .preserveCredential)
        #expect(CredentialValidationPolicy.decision(httpStatus: 500) == .preserveCredential)
    }

    @Test func classifies498OnlyForRefreshableCredentials() {
        #expect(CredentialValidationPolicy.decision(httpStatus: 498) == .preserveCredential)
        #expect(CredentialValidationPolicy.decision(httpStatus: 498,
                                                    supportsExpiredTokenRefresh: true)
            == .refreshExpiredCredential)
    }
}
