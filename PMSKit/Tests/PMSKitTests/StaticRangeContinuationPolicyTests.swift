import Testing
@testable import PMSKit

@Suite("Static range continuation policy")
struct StaticRangeContinuationPolicyTests {
    @Test("Finished bodies stop when pause or delete already owns the row")
    func finishedBodyHalted() {
        #expect(StaticRangeContinuationPolicy.afterFinishedBody(
            isHalted: true,
            hasRequest: true
        ) == .halted)
    }

    @Test("Finished adopted remainders request backend auth rebuild")
    func finishedAdoptedRemainderRequestsBackend() {
        #expect(StaticRangeContinuationPolicy.afterFinishedBody(
            isHalted: false,
            hasRequest: false
        ) == .requestNeeded(.requestRebuildNeeded))
    }

    @Test("Finished in-memory remainders continue directly")
    func finishedInMemoryRemainderContinues() {
        #expect(StaticRangeContinuationPolicy.afterFinishedBody(
            isHalted: false,
            hasRequest: true
        ) == .startInSession)
    }

    @Test("Offset mismatches stop behind halt before considering retry exhaustion")
    func offsetMismatchHaltedWins() {
        #expect(StaticRangeContinuationPolicy.afterOffsetMismatch(
            isHalted: true,
            retryAttempt: StaticRangeRetryAttempt(attempt: 4, isExhausted: true),
            hasRequest: true
        ) == .halted)
    }

    @Test("Offset mismatches fail when retry budget is exhausted")
    func offsetMismatchExhaustedFails() {
        #expect(StaticRangeContinuationPolicy.afterOffsetMismatch(
            isHalted: false,
            retryAttempt: StaticRangeRetryAttempt(attempt: 4, isExhausted: true),
            hasRequest: true
        ) == .failExhausted)
    }

    @Test("Offset mismatches route adopted remainders through backend rebuild")
    func offsetMismatchAdoptedRequestsBackend() {
        #expect(StaticRangeContinuationPolicy.afterOffsetMismatch(
            isHalted: false,
            retryAttempt: StaticRangeRetryAttempt(attempt: 1, isExhausted: false),
            hasRequest: false
        ) == .requestNeeded(.requestRebuildNeeded))
    }

    @Test("Offset mismatches retry in-session when request is available")
    func offsetMismatchInSessionRetries() {
        #expect(StaticRangeContinuationPolicy.afterOffsetMismatch(
            isHalted: false,
            retryAttempt: StaticRangeRetryAttempt(attempt: 1, isExhausted: false),
            hasRequest: true
        ) == .startInSession)
    }

    @Test("Validator changes stop behind halt before unstable-source failure")
    func validatorChangeHaltedWins() {
        #expect(StaticRangeContinuationPolicy.afterValidatorChange(
            isHalted: true,
            retryAttempt: StaticRangeRetryAttempt(attempt: 4, isExhausted: true),
            hasRequest: true
        ) == .halted)
    }

    @Test("Validator changes fail when restart budget is exhausted")
    func validatorChangeExhaustedFails() {
        #expect(StaticRangeContinuationPolicy.afterValidatorChange(
            isHalted: false,
            retryAttempt: StaticRangeRetryAttempt(attempt: 4, isExhausted: true),
            hasRequest: true
        ) == .failExhausted)
    }

    @Test("Validator changes route adopted remainders through backend restart")
    func validatorChangeAdoptedRequestsBackend() {
        #expect(StaticRangeContinuationPolicy.afterValidatorChange(
            isHalted: false,
            retryAttempt: StaticRangeRetryAttempt(attempt: 1, isExhausted: false),
            hasRequest: false
        ) == .requestNeeded(.validatorChanged))
    }

    @Test("Validator changes restart in-session when request is available")
    func validatorChangeInSessionRetries() {
        #expect(StaticRangeContinuationPolicy.afterValidatorChange(
            isHalted: false,
            retryAttempt: StaticRangeRetryAttempt(attempt: 1, isExhausted: false),
            hasRequest: true
        ) == .startInSession)
    }
}
