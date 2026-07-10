import Testing
@testable import PMSKit

@Suite("Emby convert poll health policy")
struct EmbyConvertPollHealthPolicyTests {
    @Test("Persistent failures become terminal only at the consecutive budget")
    func persistentBudget() {
        var state = EmbyConvertPollHealthPolicy.State()
        for _ in 1..<EmbyConvertPollHealthPolicy.consecutiveFailureBudget {
            #expect(EmbyConvertPollHealthPolicy.registerFailure(state: &state) == .keepPolling)
        }
        #expect(EmbyConvertPollHealthPolicy.registerFailure(state: &state) == .failPersistent)
        #expect(state.consecutiveFailures == EmbyConvertPollHealthPolicy.consecutiveFailureBudget)
    }

    @Test("One successful status response resets the consecutive failure run")
    func successResets() {
        var state = EmbyConvertPollHealthPolicy.State(consecutiveFailures: 59)
        EmbyConvertPollHealthPolicy.registerSuccess(state: &state)
        #expect(state == EmbyConvertPollHealthPolicy.State())
        #expect(EmbyConvertPollHealthPolicy.registerFailure(state: &state) == .keepPolling)
    }
}
