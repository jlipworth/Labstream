import Foundation
import Testing
@testable import PMSKit

@Suite("Background download transient retry policy")
struct BackgroundDownloadTransientRetryPolicyTests {

    @Test("Opaque downloads require transient URL errors, resume data, supported lane, and budget")
    func opaqueDownloadRetryGate() {
        #expect(BackgroundDownloadTransientRetryPolicy.opaqueDownloadDecision(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            supportsResumeData: true,
            currentRetryCount: 0
        ) == .retry(nextAttempt: 1))

        #expect(BackgroundDownloadTransientRetryPolicy.opaqueDownloadDecision(
            errorDomain: NSCocoaErrorDomain,
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            supportsResumeData: true,
            currentRetryCount: 0
        ) == .reject(.nonTransientError))

        #expect(BackgroundDownloadTransientRetryPolicy.opaqueDownloadDecision(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: false,
            supportsResumeData: true,
            currentRetryCount: 0
        ) == .reject(.missingResumeData))

        #expect(BackgroundDownloadTransientRetryPolicy.opaqueDownloadDecision(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            supportsResumeData: false,
            currentRetryCount: 0
        ) == .reject(.unsupportedResumeData))

        #expect(BackgroundDownloadTransientRetryPolicy.opaqueDownloadDecision(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            supportsResumeData: true,
            currentRetryCount: 3
        ) == .reject(.retryBudgetExhausted(nextAttempt: 4, maxRetries: 3)))
    }

    @Test("Range retries require transient URL errors, an in-memory request, and budget")
    func rangeRetryGate() {
        #expect(BackgroundDownloadTransientRetryPolicy.rangeDecision(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorTimedOut,
            hasRequest: true,
            currentRetryCount: 2
        ) == .retry(nextAttempt: 3))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeDecision(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorBadURL,
            hasRequest: true,
            currentRetryCount: 0
        ) == .reject(.nonTransientError))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeDecision(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorTimedOut,
            hasRequest: false,
            currentRetryCount: 0
        ) == .reject(.missingRangeRequest))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeDecision(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorTimedOut,
            hasRequest: true,
            currentRetryCount: 3
        ) == .reject(.retryBudgetExhausted(nextAttempt: 4, maxRetries: 3)))
    }

    @Test("Transient error code set preserves the network drop cases used by downloads")
    func transientErrorCodes() {
        #expect(BackgroundDownloadTransientRetryPolicy.transientErrorCodes == [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
        ])
    }
}
