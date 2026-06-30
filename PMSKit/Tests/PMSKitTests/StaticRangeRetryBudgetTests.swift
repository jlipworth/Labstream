import Testing
@testable import PMSKit

@Suite("Static range retry budget")
struct StaticRangeRetryBudgetTests {

    @Test("Offset mismatch retries exhaust after the configured budget")
    func offsetMismatchBudget() {
        var budget = StaticRangeRetryBudget(maxValidatorChangeRestarts: 3, maxOffsetMismatchRetries: 2)

        #expect(budget.recordOffsetMismatch(downloadID: "row") == StaticRangeRetryAttempt(attempt: 1, isExhausted: false))
        #expect(budget.recordOffsetMismatch(downloadID: "row") == StaticRangeRetryAttempt(attempt: 2, isExhausted: false))
        #expect(budget.recordOffsetMismatch(downloadID: "row") == StaticRangeRetryAttempt(attempt: 3, isExhausted: true))
        // Exhausted attempts do not keep increasing persisted state forever; the next retry remains
        // the first over-budget attempt until the caller resets.
        #expect(budget.recordOffsetMismatch(downloadID: "row") == StaticRangeRetryAttempt(attempt: 3, isExhausted: true))
    }

    @Test("Validator changes count restarts until reset")
    func validatorChangeBudget() {
        var budget = StaticRangeRetryBudget(maxValidatorChangeRestarts: 1, maxOffsetMismatchRetries: 3)

        #expect(budget.recordValidatorChange(downloadID: "row") == StaticRangeRetryAttempt(attempt: 1, isExhausted: false))
        #expect(budget.recordValidatorChange(downloadID: "row") == StaticRangeRetryAttempt(attempt: 2, isExhausted: true))

        budget.reset(downloadID: "row")
        #expect(budget.recordValidatorChange(downloadID: "row") == StaticRangeRetryAttempt(attempt: 1, isExhausted: false))
    }

    @Test("Budgets are isolated per download")
    func budgetsArePerDownload() {
        var budget = StaticRangeRetryBudget(maxValidatorChangeRestarts: 1, maxOffsetMismatchRetries: 1)

        #expect(!budget.recordOffsetMismatch(downloadID: "a").isExhausted)
        #expect(!budget.recordOffsetMismatch(downloadID: "b").isExhausted)
        #expect(budget.recordOffsetMismatch(downloadID: "a").isExhausted)
        #expect(!budget.recordValidatorChange(downloadID: "a").isExhausted)
        #expect(!budget.recordValidatorChange(downloadID: "b").isExhausted)
    }

    @Test("Resetting one budget does not erase the other row")
    func resetIsScoped() {
        var budget = StaticRangeRetryBudget(maxValidatorChangeRestarts: 1, maxOffsetMismatchRetries: 1)
        _ = budget.recordOffsetMismatch(downloadID: "a")
        _ = budget.recordOffsetMismatch(downloadID: "b")

        budget.reset(downloadID: "a")

        #expect(!budget.recordOffsetMismatch(downloadID: "a").isExhausted)
        #expect(budget.recordOffsetMismatch(downloadID: "b").isExhausted)
    }
}
