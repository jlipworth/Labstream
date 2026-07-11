import Testing
@testable import PMSKit

@Suite("Static range retry budget")
struct StaticRangeRetryBudgetTests {

    private func key(_ downloadID: String, attemptID: String = "attempt-a") -> StaticRangeRetryKey {
        StaticRangeRetryKey(downloadID: downloadID, attemptID: attemptID)
    }

    @Test("Offset mismatch retries exhaust after the configured budget")
    func offsetMismatchBudget() {
        var budget = StaticRangeRetryBudget(maxValidatorChangeRestarts: 3, maxOffsetMismatchRetries: 2)

        #expect(budget.recordOffsetMismatch(key: key("row"), segmentOffset: 0) == StaticRangeRetryAttempt(attempt: 1, isExhausted: false))
        #expect(budget.recordOffsetMismatch(key: key("row"), segmentOffset: 0) == StaticRangeRetryAttempt(attempt: 2, isExhausted: false))
        #expect(budget.recordOffsetMismatch(key: key("row"), segmentOffset: 0) == StaticRangeRetryAttempt(attempt: 3, isExhausted: true))
        // Exhausted attempts do not keep increasing persisted state forever; the next retry remains
        // the first over-budget attempt until the caller resets.
        #expect(budget.recordOffsetMismatch(key: key("row"), segmentOffset: 0) == StaticRangeRetryAttempt(attempt: 3, isExhausted: true))
    }

    @Test("Validator changes count restarts until reset")
    func validatorChangeBudget() {
        var budget = StaticRangeRetryBudget(maxValidatorChangeRestarts: 1, maxOffsetMismatchRetries: 3)

        #expect(budget.recordValidatorChange(key: key("row")) == StaticRangeRetryAttempt(attempt: 1, isExhausted: false))
        #expect(budget.recordValidatorChange(key: key("row")) == StaticRangeRetryAttempt(attempt: 2, isExhausted: true))

        budget.reset(key: key("row"))
        #expect(budget.recordValidatorChange(key: key("row")) == StaticRangeRetryAttempt(attempt: 1, isExhausted: false))
    }

    @Test("Budgets are isolated per download")
    func budgetsArePerDownload() {
        var budget = StaticRangeRetryBudget(maxValidatorChangeRestarts: 1, maxOffsetMismatchRetries: 1)

        #expect(!budget.recordOffsetMismatch(key: key("a"), segmentOffset: 0).isExhausted)
        #expect(!budget.recordOffsetMismatch(key: key("b"), segmentOffset: 0).isExhausted)
        #expect(budget.recordOffsetMismatch(key: key("a"), segmentOffset: 0).isExhausted)
        #expect(!budget.recordValidatorChange(key: key("a")).isExhausted)
        #expect(!budget.recordValidatorChange(key: key("b")).isExhausted)
    }

    @Test("Resetting one budget does not erase the other row")
    func resetIsScoped() {
        var budget = StaticRangeRetryBudget(maxValidatorChangeRestarts: 1, maxOffsetMismatchRetries: 1)
        _ = budget.recordOffsetMismatch(key: key("a"), segmentOffset: 0)
        _ = budget.recordOffsetMismatch(key: key("b"), segmentOffset: 0)

        budget.reset(key: key("a"))

        #expect(!budget.recordOffsetMismatch(key: key("a"), segmentOffset: 0).isExhausted)
        #expect(budget.recordOffsetMismatch(key: key("b"), segmentOffset: 0).isExhausted)
    }

    @Test("Parallel segment offsets do not consume each other's mismatch budget")
    func offsetMismatchBudgetIsPerSegment() {
        var budget = StaticRangeRetryBudget(maxValidatorChangeRestarts: 1,
                                            maxOffsetMismatchRetries: 1)

        #expect(!budget.recordOffsetMismatch(key: key("row"), segmentOffset: 0).isExhausted)
        #expect(!budget.recordOffsetMismatch(key: key("row"), segmentOffset: 512).isExhausted)
        #expect(budget.recordOffsetMismatch(key: key("row"), segmentOffset: 0).isExhausted)
        #expect(budget.recordOffsetMismatch(key: key("row"), segmentOffset: 512).isExhausted)

        budget.resetOffsetMismatch(key: key("row"), segmentOffset: 0)
        #expect(!budget.recordOffsetMismatch(key: key("row"), segmentOffset: 0).isExhausted)
        #expect(budget.recordOffsetMismatch(key: key("row"), segmentOffset: 512).isExhausted)
    }
    @Test("Replacement attempts for one download have isolated budgets")
    func budgetsArePerAttempt() {
        var budget = StaticRangeRetryBudget(maxValidatorChangeRestarts: 1,
                                            maxOffsetMismatchRetries: 1)
        let attemptA = key("row", attemptID: "attempt-a")
        let attemptB = key("row", attemptID: "attempt-b")

        #expect(!budget.recordValidatorChange(key: attemptA).isExhausted)
        #expect(budget.recordValidatorChange(key: attemptA).isExhausted)
        #expect(!budget.recordValidatorChange(key: attemptB).isExhausted)

        #expect(!budget.recordOffsetMismatch(key: attemptA, segmentOffset: 512).isExhausted)
        #expect(budget.recordOffsetMismatch(key: attemptA, segmentOffset: 512).isExhausted)
        #expect(!budget.recordOffsetMismatch(key: attemptB, segmentOffset: 512).isExhausted)

        budget.reset(key: attemptA)
        #expect(!budget.recordValidatorChange(key: attemptA).isExhausted)
        #expect(budget.recordValidatorChange(key: attemptB).isExhausted)
    }

}
