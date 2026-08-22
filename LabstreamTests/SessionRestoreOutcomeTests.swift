import Testing
@testable import Labstream

@Suite("Session restore UI outcome")
struct SessionRestoreOutcomeTests {
    @Test("distinguishes usable, retained-unavailable, and sign-in-required restores")
    func resolvesRestoreStates() {
        #expect(SessionRestoreOutcome.resolve(reportedRestored: true,
                                              hasUsableSession: true) == .restored)
        #expect(SessionRestoreOutcome.resolve(reportedRestored: true,
                                              hasUsableSession: false) == .temporarilyUnavailable)
        #expect(SessionRestoreOutcome.resolve(reportedRestored: false,
                                              hasUsableSession: false) == .requiresSignIn)
    }
}
