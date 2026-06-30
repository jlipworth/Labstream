import Foundation

public struct StaticRangeRetryAttempt: Sendable, Equatable {
    public let attempt: Int
    public let isExhausted: Bool

    public init(attempt: Int, isExhausted: Bool) {
        self.attempt = attempt
        self.isExhausted = isExhausted
    }
}

/// IO-free retry counters for the static byte-range transfer engine.
///
/// These counters deliberately live outside generic URLSession retry state: progress callbacks can
/// reset transient network retry counts, but they must not erase consecutive validator-change or
/// Content-Range mismatch attempts until a chunk is actually appended to the durable partial.
public struct StaticRangeRetryBudget: Sendable, Equatable {
    public let maxValidatorChangeRestarts: Int
    public let maxOffsetMismatchRetries: Int

    private var validatorChangeRestarts: [String: Int] = [:]
    private var offsetMismatchRetries: [String: Int] = [:]

    public init(maxValidatorChangeRestarts: Int = 3, maxOffsetMismatchRetries: Int = 3) {
        self.maxValidatorChangeRestarts = max(0, maxValidatorChangeRestarts)
        self.maxOffsetMismatchRetries = max(0, maxOffsetMismatchRetries)
    }

    public mutating func reset(downloadID: String) {
        validatorChangeRestarts[downloadID] = nil
        offsetMismatchRetries[downloadID] = nil
    }

    public mutating func resetOffsetMismatch(downloadID: String) {
        offsetMismatchRetries[downloadID] = nil
    }

    public mutating func recordValidatorChange(downloadID: String) -> StaticRangeRetryAttempt {
        let attempt = (validatorChangeRestarts[downloadID] ?? 0) + 1
        validatorChangeRestarts[downloadID] = attempt
        return StaticRangeRetryAttempt(
            attempt: attempt,
            isExhausted: attempt > maxValidatorChangeRestarts
        )
    }

    public mutating func recordOffsetMismatch(downloadID: String) -> StaticRangeRetryAttempt {
        let attempt = (offsetMismatchRetries[downloadID] ?? 0) + 1
        if attempt <= maxOffsetMismatchRetries {
            offsetMismatchRetries[downloadID] = attempt
        }
        return StaticRangeRetryAttempt(
            attempt: attempt,
            isExhausted: attempt > maxOffsetMismatchRetries
        )
    }
}
