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
/// Content-Range mismatch attempts until a response body is actually appended to the durable partial.
public struct StaticRangeRetryBudget: Sendable, Equatable {
    public let maxValidatorChangeRestarts: Int
    public let maxOffsetMismatchRetries: Int

    private var validatorChangeRestarts: [String: Int] = [:]
    /// Offset mismatches are segment-local. Parallel look-ahead segments can be internally resumed
    /// independently by CFNetwork; allowing sibling offsets to consume one row-wide budget made a
    /// valid durable checkpoint terminally fail even though no single segment exhausted its retry
    /// allowance.
    private var offsetMismatchRetries: [String: [Int: Int]] = [:]

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

    public mutating func resetOffsetMismatch(downloadID: String, segmentOffset: Int) {
        offsetMismatchRetries[downloadID]?[segmentOffset] = nil
        if offsetMismatchRetries[downloadID]?.isEmpty == true {
            offsetMismatchRetries[downloadID] = nil
        }
    }

    public mutating func recordValidatorChange(downloadID: String) -> StaticRangeRetryAttempt {
        let attempt = (validatorChangeRestarts[downloadID] ?? 0) + 1
        validatorChangeRestarts[downloadID] = attempt
        return StaticRangeRetryAttempt(
            attempt: attempt,
            isExhausted: attempt > maxValidatorChangeRestarts
        )
    }

    public mutating func recordOffsetMismatch(downloadID: String,
                                              segmentOffset: Int) -> StaticRangeRetryAttempt {
        let attempt = (offsetMismatchRetries[downloadID]?[segmentOffset] ?? 0) + 1
        if attempt <= maxOffsetMismatchRetries {
            offsetMismatchRetries[downloadID, default: [:]][segmentOffset] = attempt
        }
        return StaticRangeRetryAttempt(
            attempt: attempt,
            isExhausted: attempt > maxOffsetMismatchRetries
        )
    }
}
