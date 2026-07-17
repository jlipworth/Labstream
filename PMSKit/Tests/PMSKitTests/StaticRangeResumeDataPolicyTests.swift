import Foundation
import Testing
@testable import PMSKit

@Suite("Static range resume data policy")
struct StaticRangeResumeDataPolicyTests {
    @Test("Pausing a remainder produces resume data")
    func pauseProducesResumeData() {
        #expect(StaticRangeResumeDataPolicy.pauseDisposition() == .cancelProducingResumeData)
    }

    @Test("Remainder failure with a blob resumes, budget-bounded")
    func remainderFailureWithBlobResumes() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            currentBlobResumeCount: 0
        ) == .resume(nextAttempt: 1))
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorTimedOut,
            hasResumeData: true,
            currentBlobResumeCount: 2
        ) == .resume(nextAttempt: 3))
    }

    @Test("Non-transient-looking errors still blob-resume when the OS handed back a blob")
    func nonTransientErrorWithBlobStillResumes() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorUnknown,
            hasResumeData: true,
            currentBlobResumeCount: 0
        ) == .resume(nextAttempt: 1))
    }

    @Test("Cancellation never blob-resumes")
    func cancelledNeverResumes() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorCancelled,
            hasResumeData: true,
            currentBlobResumeCount: 0
        ) == .reject(.cancelled))
    }

    @Test("Missing blob rejects")
    func missingBlobRejects() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: false,
            currentBlobResumeCount: 0
        ) == .reject(.missingResumeData))
    }

    @Test("Closed range never blob-resumes even when URLSession supplies resume data")
    func closedRangeNeverBlobResumes() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            currentBlobResumeCount: 0,
            isClosedRange: true
        ) == .reject(.closedRange))
    }

    @Test("Blob resume budget exhausts")
    func blobResumeBudgetExhausts() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            currentBlobResumeCount: 3
        ) == .reject(.budgetExhausted(nextAttempt: 4, maxResumes: 3)))
    }

    @Test("Blob whose Range offset matches the durable partial is adopted")
    func matchingOffsetAdopts() {
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: 1_000, durableBytes: 1_000
        ) == .adopt(baseOffset: 1_000))
    }

    @Test("Persisted closed-range blobs are rejected before adoption")
    func closedRangeBlobAdoptionIsRefused() {
        #expect(!StaticRangeResumeDataPolicy.shouldAdoptBlob(hasClosedRangeEnd: true))
        #expect(StaticRangeResumeDataPolicy.shouldAdoptBlob(hasClosedRangeEnd: false))
    }

    @Test("Blob whose Range offset disagrees with the durable partial is stale")
    func mismatchedOffsetRejects() {
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: 500, durableBytes: 1_000
        ) == .rejectStale(blobOffset: 500, durableBytes: 1_000))
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: 2_000, durableBytes: 1_000
        ) == .rejectStale(blobOffset: 2_000, durableBytes: 1_000))
    }

    @Test("Retrying a live train segment adopts the blob at the segment's own base offset")
    func segmentRetryAdoptsAtSegmentBase() {
        // Mid-train segment: durable belongs to the head (0 here), the blob to the segment.
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: 1_536, durableBytes: 0, segmentBaseOffset: 1_536
        ) == .adopt(baseOffset: 1_536))
        // A blob from some other lifecycle/offset is still stale.
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: 512, durableBytes: 0, segmentBaseOffset: 1_536
        ) == .rejectStale(blobOffset: 512, durableBytes: 0))
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: nil, durableBytes: 0, segmentBaseOffset: 1_536
        ) == .rejectStale(blobOffset: nil, durableBytes: 0))
        // nil segmentBaseOffset keeps the durable-offset rule (persisted-blob adoption path).
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: 1_000, durableBytes: 1_000, segmentBaseOffset: nil
        ) == .adopt(baseOffset: 1_000))
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: 1_536, durableBytes: 0, segmentBaseOffset: nil
        ) == .rejectStale(blobOffset: 1_536, durableBytes: 0))
    }

    @Test("Blob without a parseable Range offset is stale")
    func missingOffsetRejects() {
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: nil, durableBytes: 1_000
        ) == .rejectStale(blobOffset: nil, durableBytes: 1_000))
    }

    @Test("Cannot-resume resume data falls back to the durable partial")
    func cannotResumeFallsBackToDurablePartial() {
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorCannotDecodeRawData,
            hasResumeData: false
        ) == .resumeDataCannotResume)
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorFileDoesNotExist,
            hasResumeData: false
        ) == .resumeDataCannotResume)
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSCocoaErrorDomain,
            errorCode: CocoaError.fileNoSuchFile.rawValue,
            hasResumeData: false
        ) == .resumeDataCannotResume)
    }

    @Test("Fallback does not discard a new blob or apply to unrelated errors")
    func durableFallbackDoesNotPreemptNewBlobOrUnrelatedErrors() {
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorCannotDecodeRawData,
            hasResumeData: true
        ) == nil)
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: false
        ) == nil)
    }

    @Test("Parking with a blob persists it unless the blob was rejected")
    func parkingPersistsBlob() {
        #expect(StaticRangeResumeDataPolicy.shouldPersistBlobOnPark(hasResumeData: true))
        #expect(!StaticRangeResumeDataPolicy.shouldPersistBlobOnPark(hasResumeData: false))
        #expect(!StaticRangeResumeDataPolicy.shouldPersistBlobOnPark(
            hasResumeData: true,
            resumeDataWasRejected: true
        ))
    }

    @Test("No closed segment persists URLSession resume data on pause")
    func closedSegmentsNeverPersistBlobOnPause() {
        let seg = 512 * 1_024 * 1_024
        let durable = 0
        for index in 0..<8 {
            #expect(!StaticRangeResumeDataPolicy.shouldPersistSegmentBlobOnPause(
                segmentBaseOffset: index * seg, durableBytes: durable),
                "closed segment at offset \(index * seg) must not persist a URLSession blob")
        }
        #expect(!StaticRangeResumeDataPolicy.shouldPersistSegmentBlobOnPause(
            segmentBaseOffset: 1_048_576, durableBytes: 1_048_576))
    }
}
