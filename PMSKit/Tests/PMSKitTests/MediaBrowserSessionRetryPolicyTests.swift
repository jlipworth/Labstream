import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser session retry policy")
struct MediaBrowserSessionRetryPolicyTests {
    @Test("HTTP 401 and 403 retry only within the bounded budget")
    func authStatusesRetryWithinBudget() {
        #expect(MediaBrowserSessionRetryPolicy.shouldRetryHTTPStatus(401, currentRetryCount: 0))
        #expect(MediaBrowserSessionRetryPolicy.shouldRetryHTTPStatus(403, currentRetryCount: 1))
        #expect(!MediaBrowserSessionRetryPolicy.shouldRetryHTTPStatus(403, currentRetryCount: 2))
        #expect(!MediaBrowserSessionRetryPolicy.shouldRetryHTTPStatus(404, currentRetryCount: 0))
        #expect(!MediaBrowserSessionRetryPolicy.shouldRetryHTTPStatus(500, currentRetryCount: 0))
    }

    @Test("Transient URL errors retry only for NSURLErrorDomain")
    func transientURLErrorsRetryWithinBudget() {
        #expect(MediaBrowserSessionRetryPolicy.shouldRetryURLError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            currentRetryCount: 0))
        #expect(MediaBrowserSessionRetryPolicy.shouldRetryURLError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            currentRetryCount: 1))
        #expect(!MediaBrowserSessionRetryPolicy.shouldRetryURLError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            currentRetryCount: 2))
        #expect(!MediaBrowserSessionRetryPolicy.shouldRetryURLError(
            domain: NSCocoaErrorDomain,
            code: NSURLErrorTimedOut,
            currentRetryCount: 0))
    }

    @Test("Retry delays use a small bounded backoff")
    func retryDelays() {
        #expect(MediaBrowserSessionRetryPolicy.retryDelaySeconds(nextAttempt: 1) == 1)
        #expect(MediaBrowserSessionRetryPolicy.retryDelaySeconds(nextAttempt: 2) == 2)
        #expect(MediaBrowserSessionRetryPolicy.retryDelaySeconds(nextAttempt: 3) == 4)
    }
}
