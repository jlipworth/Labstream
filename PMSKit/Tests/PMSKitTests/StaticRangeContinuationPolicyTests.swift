import Testing
@testable import PMSKit

/// Routing tables for the three continuation functions. Precedence in every function is
/// halt > retry exhausted > request availability; the two retry functions differ only in the
/// backend-request reason (`.requestRebuildNeeded` vs `.validatorChanged`).
@Suite("Static range continuation policy")
struct StaticRangeContinuationPolicyTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let note: String
        let isHalted: Bool
        let retryAttempt: StaticRangeRetryAttempt
        let hasRequest: Bool
        let expected: StaticRangeContinuationDisposition

        init(_ note: String, isHalted: Bool, isExhausted: Bool = false, hasRequest: Bool,
             expected: StaticRangeContinuationDisposition) {
            self.note = note
            self.isHalted = isHalted
            self.retryAttempt = StaticRangeRetryAttempt(attempt: isExhausted ? 4 : 1, isExhausted: isExhausted)
            self.hasRequest = hasRequest
            self.expected = expected
        }

        var testDescription: String { note }
    }

    @Test("Finished body routing", arguments: [
        Row("stops when pause or delete already owns the row",
            isHalted: true, hasRequest: true, expected: .halted),
        Row("adopted remainder requests backend auth rebuild",
            isHalted: false, hasRequest: false, expected: .requestNeeded(.requestRebuildNeeded)),
        Row("in-memory remainder continues directly",
            isHalted: false, hasRequest: true, expected: .startInSession),
    ])
    func afterFinishedBody(_ row: Row) {
        #expect(StaticRangeContinuationPolicy.afterFinishedBody(
            isHalted: row.isHalted,
            hasRequest: row.hasRequest
        ) == row.expected)
    }

    @Test("Offset mismatch routing", arguments: [
        Row("halt wins before considering retry exhaustion",
            isHalted: true, isExhausted: true, hasRequest: true, expected: .halted),
        Row("fails when retry budget is exhausted",
            isHalted: false, isExhausted: true, hasRequest: true, expected: .failExhausted),
        Row("adopted remainder routes through backend rebuild",
            isHalted: false, hasRequest: false, expected: .requestNeeded(.requestRebuildNeeded)),
        Row("retries in-session when request is available",
            isHalted: false, hasRequest: true, expected: .startInSession),
    ])
    func afterOffsetMismatch(_ row: Row) {
        #expect(StaticRangeContinuationPolicy.afterOffsetMismatch(
            isHalted: row.isHalted,
            retryAttempt: row.retryAttempt,
            hasRequest: row.hasRequest
        ) == row.expected)
    }

    @Test("Validator change routing", arguments: [
        Row("halt wins before unstable-source failure",
            isHalted: true, isExhausted: true, hasRequest: true, expected: .halted),
        Row("fails when restart budget is exhausted",
            isHalted: false, isExhausted: true, hasRequest: true, expected: .failExhausted),
        Row("adopted remainder routes through backend restart",
            isHalted: false, hasRequest: false, expected: .requestNeeded(.validatorChanged)),
        Row("restarts in-session when request is available",
            isHalted: false, hasRequest: true, expected: .startInSession),
    ])
    func afterValidatorChange(_ row: Row) {
        #expect(StaticRangeContinuationPolicy.afterValidatorChange(
            isHalted: row.isHalted,
            retryAttempt: row.retryAttempt,
            hasRequest: row.hasRequest
        ) == row.expected)
    }
}
