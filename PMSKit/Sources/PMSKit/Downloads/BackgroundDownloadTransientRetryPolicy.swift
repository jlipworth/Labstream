import Foundation

public enum BackgroundDownloadTransientRetryRejection: Sendable, Equatable {
    case nonTransientError
    case nonTransientHTTPStatus
    case missingResumeData
    case unsupportedResumeData
    case unsupportedRangeSegment
    case missingRangeRequest
    case retryBudgetExhausted(nextAttempt: Int, maxRetries: Int)
}

public enum BackgroundDownloadTransientRetryDecision: Sendable, Equatable {
    case retry(nextAttempt: Int)
    case reject(BackgroundDownloadTransientRetryRejection)
}

/// Pure retry-gating decisions for transient background transfer failures.
///
/// Opaque URLSession downloads can retry only when the OS provides resume data and the row's lane
/// explicitly supports persisted resume blobs. App-managed static Range downloads retry by issuing
/// a fresh Range request from the durable app-owned checkpoint, so they require the original
/// authenticated request still to be in memory.
public enum BackgroundDownloadTransientRetryPolicy {
    public static let defaultMaxRetries = 3
    public static let defaultMaxRangeMoveRetries = 3
    public static let defaultMaxRangeRehydrations = 3

    /// HTTP statuses where repeating the identical Range request is unlikely to help, but rebuilding
    /// the backend/playback negotiation can mint a fresh authorized static-file request.
    public static let rehydratableHTTPStatusCodes: Set<Int> = [
        401,
        403,
    ]

    /// Server-side / edge-proxy HTTP responses that are usually transient for a static file chunk.
    ///
    /// Keep this intentionally narrower than "all 5xx": permanent origin application failures
    /// should still surface quickly, while proxy overload/network-transition cases get the same
    /// bounded self-healing behavior as URLSession transport drops.
    public static let transientHTTPStatusCodes: Set<Int> = [
        502,
        503,
        504,
        520,
        521,
        522,
        523,
        524,
        525,
        526,
    ]

    public static let transientErrorCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
    ]

    public static func opaqueDownloadDecision(errorDomain: String,
                                              errorCode: Int,
                                              hasResumeData: Bool,
                                              supportsResumeData: Bool,
                                              currentRetryCount: Int,
                                              maxRetries: Int = defaultMaxRetries) -> BackgroundDownloadTransientRetryDecision {
        guard isTransientURLError(domain: errorDomain, code: errorCode) else {
            return .reject(.nonTransientError)
        }
        guard hasResumeData else {
            return .reject(.missingResumeData)
        }
        guard supportsResumeData else {
            return .reject(.unsupportedResumeData)
        }
        return retryBudgetDecision(currentRetryCount: currentRetryCount, maxRetries: maxRetries)
    }

    public static func rangeDecision(errorDomain: String,
                                     errorCode: Int,
                                     hasRequest: Bool,
                                     currentRetryCount: Int,
                                     maxRetries: Int = defaultMaxRetries) -> BackgroundDownloadTransientRetryDecision {
        guard isTransientURLError(domain: errorDomain, code: errorCode) else {
            return .reject(.nonTransientError)
        }
        guard hasRequest else {
            return .reject(.missingRangeRequest)
        }
        return retryBudgetDecision(currentRetryCount: currentRetryCount, maxRetries: maxRetries)
    }

    public static func rangeRehydrationDecision(statusCode: Int,
                                                supportsDurableCheckpoint: Bool,
                                                currentRehydrationCount: Int,
                                                maxRehydrations: Int = defaultMaxRangeRehydrations) -> BackgroundDownloadTransientRetryDecision {
        guard rehydratableHTTPStatusCodes.contains(statusCode) else {
            return .reject(.nonTransientHTTPStatus)
        }
        guard supportsDurableCheckpoint else {
            return .reject(.unsupportedRangeSegment)
        }
        return retryBudgetDecision(currentRetryCount: currentRehydrationCount,
                                   maxRetries: maxRehydrations)
    }

    public static func rangeHTTPDecision(statusCode: Int,
                                         hasRequest: Bool,
                                         supportsDurableCheckpoint: Bool,
                                         currentRetryCount: Int,
                                         maxRetries: Int = defaultMaxRetries) -> BackgroundDownloadTransientRetryDecision {
        guard transientHTTPStatusCodes.contains(statusCode) else {
            return .reject(.nonTransientHTTPStatus)
        }
        guard supportsDurableCheckpoint else {
            return .reject(.unsupportedRangeSegment)
        }
        guard hasRequest else {
            return .reject(.missingRangeRequest)
        }
        return retryBudgetDecision(currentRetryCount: currentRetryCount, maxRetries: maxRetries)
    }

    /// A finished app-managed Range chunk can occasionally report delegate completion but then fail
    /// to move/stash/append because the temporary file or durable partial disappeared during a
    /// headset-off/background reattach race. Treat file-missing Cocoa errors like a transient Range
    /// chunk failure: keep the last app-owned checkpoint and rebuild/retry from there.
    ///
    /// Unlike the 416/HTTP paths this takes no segment-kind gate (#220): a move failure commits no
    /// bytes, so re-requesting from the durable partial's size is valid for every segment kind,
    /// including a continuous remainder. `.missingRangeRequest` routes the caller to rehydration.
    public static func rangeMoveDecision(errorDomain: String,
                                         errorCode: Int,
                                         hasRequest: Bool,
                                         currentRetryCount: Int,
                                         maxRetries: Int = defaultMaxRangeMoveRetries) -> BackgroundDownloadTransientRetryDecision {
        guard errorDomain == NSCocoaErrorDomain,
              errorCode == CocoaError.fileNoSuchFile.rawValue else {
            return .reject(.nonTransientError)
        }
        guard hasRequest else {
            return .reject(.missingRangeRequest)
        }
        return retryBudgetDecision(currentRetryCount: currentRetryCount, maxRetries: maxRetries)
    }

    private static func isTransientURLError(domain: String, code: Int) -> Bool {
        domain == NSURLErrorDomain && transientErrorCodes.contains(code)
    }

    private static func retryBudgetDecision(currentRetryCount: Int,
                                            maxRetries: Int) -> BackgroundDownloadTransientRetryDecision {
        let nextAttempt = currentRetryCount + 1
        guard nextAttempt <= maxRetries else {
            return .reject(.retryBudgetExhausted(nextAttempt: nextAttempt, maxRetries: maxRetries))
        }
        return .retry(nextAttempt: nextAttempt)
    }
}
