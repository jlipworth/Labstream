import Foundation
import Testing
@testable import PMSKit

@Suite("Static range resume data policy")
struct StaticRangeResumeDataPolicyTests {

    // MARK: Pause disposition

    @Test("Pausing a continuous remainder produces resume data")
    func remainderPauseProducesResumeData() {
        #expect(StaticRangeResumeDataPolicy.pauseDisposition(segmentKind: .continuousRemainder)
            == .cancelProducingResumeData)
    }

    @Test("Pausing bounded checkpoint segments cancels at the durable checkpoint")
    func boundedPauseUsesCheckpointCancel() {
        #expect(StaticRangeResumeDataPolicy.pauseDisposition(segmentKind: .boundedCheckpoint)
            == .checkpointCancel)
        #expect(StaticRangeResumeDataPolicy.pauseDisposition(segmentKind: .backgroundCheckpoint)
            == .checkpointCancel)
    }

    // MARK: Failure resume decision

    @Test("Remainder failure with a blob resumes, budget-bounded")
    func remainderFailureWithBlobResumes() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            segmentKind: .continuousRemainder,
            currentBlobResumeCount: 0
        ) == .resume(nextAttempt: 1))
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorTimedOut,
            hasResumeData: true,
            segmentKind: .continuousRemainder,
            currentBlobResumeCount: 2
        ) == .resume(nextAttempt: 3))
    }

    @Test("Non-transient-looking errors still blob-resume when the OS handed back a blob")
    func nonTransientErrorWithBlobStillResumes() {
        // The blob's presence IS the OS's statement that the transfer is resumable; the code
        // matters less than the blob. (A long headset-off produces errors outside the narrow
        // transient set with valid resume data.)
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorUnknown,
            hasResumeData: true,
            segmentKind: .continuousRemainder,
            currentBlobResumeCount: 0
        ) == .resume(nextAttempt: 1))
    }

    @Test("Cancellation never blob-resumes")
    func cancelledNeverResumes() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorCancelled,
            hasResumeData: true,
            segmentKind: .continuousRemainder,
            currentBlobResumeCount: 0
        ) == .reject(.cancelled))
    }

    @Test("Missing blob rejects")
    func missingBlobRejects() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: false,
            segmentKind: .continuousRemainder,
            currentBlobResumeCount: 0
        ) == .reject(.missingResumeData))
    }

    @Test("Bounded checkpoint segments use the fresh-request retry lane, not blobs")
    func boundedSegmentsRejectBlobResume() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            segmentKind: .boundedCheckpoint,
            currentBlobResumeCount: 0
        ) == .reject(.unsupportedSegment))
    }

    @Test("Blob resume budget exhausts")
    func blobResumeBudgetExhausts() {
        #expect(StaticRangeResumeDataPolicy.failureResumeDecision(
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: true,
            segmentKind: .continuousRemainder,
            currentBlobResumeCount: 3
        ) == .reject(.budgetExhausted(nextAttempt: 4, maxResumes: 3)))
    }

    // MARK: Adoption of a blob-resumed task

    @Test("Blob whose Range offset matches the durable partial is adopted")
    func matchingOffsetAdopts() {
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: 1_000, durableBytes: 1_000
        ) == .adopt(baseOffset: 1_000))
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

    @Test("Blob without a parseable Range offset is stale")
    func missingOffsetRejects() {
        #expect(StaticRangeResumeDataPolicy.adoptionDecision(
            blobRangeOffset: nil, durableBytes: 1_000
        ) == .rejectStale(blobOffset: nil, durableBytes: 1_000))
    }

    // MARK: Durable partial fallback

    @Test("Cannot-resume resume data falls back to the durable partial")
    func cannotResumeFallsBackToDurablePartial() {
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorCannotDecodeRawData,
            hasResumeData: false,
            segmentKind: .continuousRemainder
        ) == .resumeDataCannotResume)
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorFileDoesNotExist,
            hasResumeData: false,
            segmentKind: .continuousRemainder
        ) == .resumeDataCannotResume)
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSCocoaErrorDomain,
            errorCode: CocoaError.fileNoSuchFile.rawValue,
            hasResumeData: false,
            segmentKind: .continuousRemainder
        ) == .resumeDataCannotResume)
    }

    @Test("Fallback does not discard a new blob or apply to legacy bounded tasks")
    func durableFallbackDoesNotPreemptNewBlobOrLegacyTasks() {
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorCannotDecodeRawData,
            hasResumeData: true,
            segmentKind: .continuousRemainder
        ) == nil)
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorCannotDecodeRawData,
            hasResumeData: false,
            segmentKind: .boundedCheckpoint
        ) == nil)
        #expect(StaticRangeResumeDataPolicy.durableFallbackReason(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorNetworkConnectionLost,
            hasResumeData: false,
            segmentKind: .continuousRemainder
        ) == nil)
    }

    // MARK: Persist on park

    @Test("Parking a remainder with a blob persists it")
    func parkingRemainderPersistsBlob() {
        #expect(StaticRangeResumeDataPolicy.shouldPersistBlobOnPark(
            hasResumeData: true, segmentKind: .continuousRemainder
        ))
    }

    @Test("Parking without a blob or on bounded segments persists nothing")
    func parkingWithoutBlobPersistsNothing() {
        #expect(!StaticRangeResumeDataPolicy.shouldPersistBlobOnPark(
            hasResumeData: false, segmentKind: .continuousRemainder
        ))
        #expect(!StaticRangeResumeDataPolicy.shouldPersistBlobOnPark(
            hasResumeData: true, segmentKind: .boundedCheckpoint
        ))
        #expect(!StaticRangeResumeDataPolicy.shouldPersistBlobOnPark(
            hasResumeData: true, segmentKind: .backgroundCheckpoint
        ))
        #expect(!StaticRangeResumeDataPolicy.shouldPersistBlobOnPark(
            hasResumeData: true,
            segmentKind: .continuousRemainder,
            resumeDataWasRejected: true
        ))
    }
}
