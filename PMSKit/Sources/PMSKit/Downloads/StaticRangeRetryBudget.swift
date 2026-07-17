import Foundation

public struct StaticRangeRetryAttempt: Sendable, Equatable {
    public let attempt: Int
    public let isExhausted: Bool

    public init(attempt: Int, isExhausted: Bool) {
        self.attempt = attempt
        self.isExhausted = isExhausted
    }
}

/// Ownership key for one static-range retry lifecycle. Kept independent of app-layer download
/// types so PMSKit callers can supply whichever durable attempt token they persist.
public struct StaticRangeRetryKey: Hashable, Sendable {
    public let downloadID: String
    public let attemptID: String

    public init(downloadID: String, attemptID: String) {
        self.downloadID = downloadID
        self.attemptID = attemptID
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

    private var validatorChangeRestarts: [StaticRangeRetryKey: Int] = [:]
    /// Offset mismatches are segment-local. Parallel look-ahead segments can be internally resumed
    /// independently by CFNetwork; allowing sibling offsets to consume one row-wide budget made a
    /// valid durable checkpoint terminally fail even though no single segment exhausted its retry
    /// allowance.
    private var offsetMismatchRetries: [StaticRangeRetryKey: [Int: Int]] = [:]

    public init(maxValidatorChangeRestarts: Int = 3, maxOffsetMismatchRetries: Int = 3) {
        self.maxValidatorChangeRestarts = max(0, maxValidatorChangeRestarts)
        self.maxOffsetMismatchRetries = max(0, maxOffsetMismatchRetries)
    }

    public mutating func reset(key: StaticRangeRetryKey) {
        validatorChangeRestarts[key] = nil
        offsetMismatchRetries[key] = nil
    }

    public mutating func resetOffsetMismatch(key: StaticRangeRetryKey) {
        offsetMismatchRetries[key] = nil
    }

    public mutating func resetOffsetMismatch(key: StaticRangeRetryKey, segmentOffset: Int) {
        offsetMismatchRetries[key]?[segmentOffset] = nil
        if offsetMismatchRetries[key]?.isEmpty == true {
            offsetMismatchRetries[key] = nil
        }
    }

    public mutating func recordValidatorChange(key: StaticRangeRetryKey) -> StaticRangeRetryAttempt {
        let attempt = (validatorChangeRestarts[key] ?? 0) + 1
        validatorChangeRestarts[key] = attempt
        return StaticRangeRetryAttempt(
            attempt: attempt,
            isExhausted: attempt > maxValidatorChangeRestarts
        )
    }

    public mutating func recordOffsetMismatch(key: StaticRangeRetryKey,
                                              segmentOffset: Int) -> StaticRangeRetryAttempt {
        let attempt = (offsetMismatchRetries[key]?[segmentOffset] ?? 0) + 1
        if attempt <= maxOffsetMismatchRetries {
            offsetMismatchRetries[key, default: [:]][segmentOffset] = attempt
        }
        return StaticRangeRetryAttempt(
            attempt: attempt,
            isExhausted: attempt > maxOffsetMismatchRetries
        )
    }
}
