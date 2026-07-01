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

    @Test("Range HTTP retries are limited to transient proxy/server statuses and durable checkpoints")
    func rangeHTTPRetryGate() {
        #expect(BackgroundDownloadTransientRetryPolicy.rangeHTTPDecision(
            statusCode: 521,
            hasRequest: true,
            supportsDurableCheckpoint: true,
            currentRetryCount: 0
        ) == .retry(nextAttempt: 1))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeHTTPDecision(
            statusCode: 526,
            hasRequest: true,
            supportsDurableCheckpoint: true,
            currentRetryCount: 2
        ) == .retry(nextAttempt: 3))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeHTTPDecision(
            statusCode: 404,
            hasRequest: true,
            supportsDurableCheckpoint: true,
            currentRetryCount: 0
        ) == .reject(.nonTransientHTTPStatus))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeHTTPDecision(
            statusCode: 500,
            hasRequest: true,
            supportsDurableCheckpoint: true,
            currentRetryCount: 0
        ) == .reject(.nonTransientHTTPStatus))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeHTTPDecision(
            statusCode: 521,
            hasRequest: false,
            supportsDurableCheckpoint: true,
            currentRetryCount: 0
        ) == .reject(.missingRangeRequest))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeHTTPDecision(
            statusCode: 521,
            hasRequest: true,
            supportsDurableCheckpoint: false,
            currentRetryCount: 0
        ) == .reject(.unsupportedRangeSegment))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeHTTPDecision(
            statusCode: 521,
            hasRequest: true,
            supportsDurableCheckpoint: true,
            currentRetryCount: 3
        ) == .reject(.retryBudgetExhausted(nextAttempt: 4, maxRetries: 3)))
    }

    @Test("Range move retries only for file-missing Cocoa errors on durable checkpoint chunks")
    func rangeMoveRetryGate() {
        #expect(BackgroundDownloadTransientRetryPolicy.rangeMoveDecision(
            errorDomain: NSCocoaErrorDomain,
            errorCode: CocoaError.fileNoSuchFile.rawValue,
            hasRequest: true,
            supportsDurableCheckpoint: true,
            currentRetryCount: 0
        ) == .retry(nextAttempt: 1))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeMoveDecision(
            errorDomain: NSCocoaErrorDomain,
            errorCode: CocoaError.fileNoSuchFile.rawValue,
            hasRequest: false,
            supportsDurableCheckpoint: true,
            currentRetryCount: 0
        ) == .reject(.missingRangeRequest))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeMoveDecision(
            errorDomain: NSCocoaErrorDomain,
            errorCode: CocoaError.fileNoSuchFile.rawValue,
            hasRequest: true,
            supportsDurableCheckpoint: false,
            currentRetryCount: 0
        ) == .reject(.unsupportedRangeSegment))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeMoveDecision(
            errorDomain: NSCocoaErrorDomain,
            errorCode: CocoaError.fileNoSuchFile.rawValue,
            hasRequest: true,
            supportsDurableCheckpoint: true,
            currentRetryCount: 3
        ) == .reject(.retryBudgetExhausted(nextAttempt: 4, maxRetries: 3)))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeMoveDecision(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorNetworkConnectionLost,
            hasRequest: true,
            supportsDurableCheckpoint: true,
            currentRetryCount: 0
        ) == .reject(.nonTransientError))
    }

    @Test("Range HTTP rehydration is limited to auth statuses, durable checkpoints, and one attempt")
    func rangeHTTPRehydrationGate() {
        #expect(BackgroundDownloadTransientRetryPolicy.rangeRehydrationDecision(
            statusCode: 403,
            supportsDurableCheckpoint: true,
            currentRehydrationCount: 0
        ) == .retry(nextAttempt: 1))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeRehydrationDecision(
            statusCode: 401,
            supportsDurableCheckpoint: true,
            currentRehydrationCount: 0
        ) == .retry(nextAttempt: 1))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeRehydrationDecision(
            statusCode: 521,
            supportsDurableCheckpoint: true,
            currentRehydrationCount: 0
        ) == .reject(.nonTransientHTTPStatus))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeRehydrationDecision(
            statusCode: 403,
            supportsDurableCheckpoint: false,
            currentRehydrationCount: 0
        ) == .reject(.unsupportedRangeSegment))

        #expect(BackgroundDownloadTransientRetryPolicy.rangeRehydrationDecision(
            statusCode: 403,
            supportsDurableCheckpoint: true,
            currentRehydrationCount: 1
        ) == .reject(.retryBudgetExhausted(nextAttempt: 2, maxRetries: 1)))
    }

    @Test("Transient HTTP status set covers the proxy and origin-unavailable statuses used by downloads")
    func transientHTTPStatusCodes() {
        #expect(BackgroundDownloadTransientRetryPolicy.transientHTTPStatusCodes == [
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
        ])
    }

    @Test("Rehydratable HTTP status set covers auth and forbidden responses")
    func rehydratableHTTPStatusCodes() {
        #expect(BackgroundDownloadTransientRetryPolicy.rehydratableHTTPStatusCodes == [
            401,
            403,
        ])
    }
}
