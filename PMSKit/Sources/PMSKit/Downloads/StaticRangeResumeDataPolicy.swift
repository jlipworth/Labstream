import Foundation

/// Pure decisions for holding a continuous-remainder Range transfer's progress in URLSession
/// resume data.
///
/// A continuous remainder parks ALL remaining bytes in one OS temp until completion, so a plain
/// cancel or a task failure would discard arbitrarily many non-durable bytes (up to the whole
/// remainder of a multi-GB file). Resume data is the only handle the OS gives us on that temp:
/// pauses cancel by producing it, failures re-resume from it (budget-bounded), and parking a row
/// persists it for a later manual Resume. Bounded checkpoint chunks keep their existing
/// fresh-request retry lane — their worst-case loss is one chunk, and blob-resuming a closed
/// Range request is exactly the combination the documented background resume bug mangles.
///
/// Correctness backstop: adoption verifies the blob's original Range offset against the durable
/// partial, and every completed body still passes the append-time Content-Range / validator
/// checks, so a blob the OS resumed strangely degrades to a wasted fetch, never a corrupt file.
public enum StaticRangeResumeDataPolicy {
    public static let defaultMaxBlobResumes = 3

    public enum PauseDisposition: Sendable, Equatable {
        /// Cancel via `cancel(byProducingResumeData:)` so the OS-temp progress survives the pause.
        case cancelProducingResumeData
        /// Plain cancel; the app-owned durable checkpoint bounds the loss to one chunk.
        case checkpointCancel
    }

    public enum FailureResumeRejection: Sendable, Equatable {
        case cancelled
        case missingResumeData
        case unsupportedSegment
        case budgetExhausted(nextAttempt: Int, maxResumes: Int)
    }

    public enum FailureResumeDecision: Sendable, Equatable {
        case resume(nextAttempt: Int)
        case reject(FailureResumeRejection)
    }

    public enum AdoptionDecision: Sendable, Equatable {
        case adopt(baseOffset: Int)
        case rejectStale(blobOffset: Int?, durableBytes: Int)
    }

    public static func pauseDisposition(segmentKind: RangeTransferSegmentKind) -> PauseDisposition {
        segmentKind == .continuousRemainder ? .cancelProducingResumeData : .checkpointCancel
    }

    /// Whether a failed remainder task should be re-resumed from the blob the OS handed back.
    /// The blob's presence is the OS's own statement that the transfer is resumable, so any
    /// non-cancel error qualifies; the budget bounds pathological resume loops.
    public static func failureResumeDecision(errorCode: Int?,
                                             hasResumeData: Bool,
                                             segmentKind: RangeTransferSegmentKind,
                                             currentBlobResumeCount: Int,
                                             maxBlobResumes: Int = defaultMaxBlobResumes) -> FailureResumeDecision {
        if errorCode == NSURLErrorCancelled {
            return .reject(.cancelled)
        }
        guard segmentKind == .continuousRemainder else {
            return .reject(.unsupportedSegment)
        }
        guard hasResumeData else {
            return .reject(.missingResumeData)
        }
        let nextAttempt = currentBlobResumeCount + 1
        guard nextAttempt <= maxBlobResumes else {
            return .reject(.budgetExhausted(nextAttempt: nextAttempt, maxResumes: maxBlobResumes))
        }
        return .resume(nextAttempt: nextAttempt)
    }

    /// A blob-resumed task is only authoritative when its original request's Range offset equals
    /// the durable partial size — anything else is stale (the partial advanced or the blob is
    /// from a different lifecycle) and must not publish progress or append later.
    public static func adoptionDecision(blobRangeOffset: Int?,
                                        durableBytes: Int) -> AdoptionDecision {
        guard let blobRangeOffset, blobRangeOffset == durableBytes else {
            return .rejectStale(blobOffset: blobRangeOffset, durableBytes: durableBytes)
        }
        return .adopt(baseOffset: blobRangeOffset)
    }

    /// Persist the blob when parking a row (`.paused`/`.queued`) so a manual Resume — even after
    /// a relaunch — continues the OS-temp progress instead of re-fetching it.
    public static func shouldPersistBlobOnPark(hasResumeData: Bool,
                                               segmentKind: RangeTransferSegmentKind) -> Bool {
        hasResumeData && segmentKind == .continuousRemainder
    }
}
