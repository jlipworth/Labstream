import Foundation

/// Bounded retry policy for active MediaBrowser session requests that can briefly fail during
/// network transitions even though the saved credentials are still valid.
///
/// This intentionally mirrors the download range rehydration posture for 401/403 without turning
/// every auth failure into an infinite loop: a small number of delayed retries gives Wi-Fi/VPN/server
/// session state time to settle, then the caller still surfaces the terminal status normally.
public enum MediaBrowserSessionRetryPolicy {
    public static let defaultMaxRetries = 2

    public static let retryableHTTPStatusCodes: Set<Int> = [
        401,
        403,
    ]

    public static let retryableURLErrorCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
    ]

    public static func shouldRetryHTTPStatus(_ statusCode: Int,
                                             currentRetryCount: Int,
                                             maxRetries: Int = defaultMaxRetries) -> Bool {
        retryableHTTPStatusCodes.contains(statusCode) && currentRetryCount < maxRetries
    }

    public static func shouldRetryURLError(domain: String,
                                           code: Int,
                                           currentRetryCount: Int,
                                           maxRetries: Int = defaultMaxRetries) -> Bool {
        domain == NSURLErrorDomain
            && retryableURLErrorCodes.contains(code)
            && currentRetryCount < maxRetries
    }

    public static func retryDelaySeconds(nextAttempt: Int) -> Double {
        switch nextAttempt {
        case 1: return 1
        case 2: return 2
        default: return 4
        }
    }
}
