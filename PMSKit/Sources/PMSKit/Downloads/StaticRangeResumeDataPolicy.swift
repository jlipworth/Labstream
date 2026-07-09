import Foundation

/// Pure decisions for holding a continuous-remainder Range transfer's progress in URLSession
/// resume data.
///
/// A continuous remainder parks ALL remaining bytes in one OS temp until completion, so a plain
/// cancel or a task failure would discard arbitrarily many non-durable bytes (up to the whole
/// remainder of a multi-GB file). Resume data is the only handle the OS gives us on that temp:
/// pauses cancel by producing it, failures re-resume from it (budget-bounded), and parking a row
/// persists it for a later manual Resume.
///
/// Correctness backstop: adoption verifies the blob's original Range offset against the durable
/// partial, and every completed body still passes the append-time Content-Range / validator
/// checks, so a blob the OS resumed strangely degrades to a wasted fetch, never a corrupt file.
public enum StaticRangeResumeDataPolicy {
    public static let defaultMaxBlobResumes = 3

    public enum PauseDisposition: Sendable, Equatable {
        /// Cancel via `cancel(byProducingResumeData:)` so the OS-temp progress survives the pause.
        case cancelProducingResumeData
    }

    public enum FailureResumeRejection: Sendable, Equatable {
        case cancelled
        case missingResumeData
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

    public enum DurableFallbackReason: String, Sendable, Equatable {
        /// URLSession explicitly rejected the resume blob, or its backing temp disappeared.
        case resumeDataCannotResume
        /// The app rejected the blob before starting it because its original Range no longer
        /// matched the durable partial, or because blob-resume retries were exhausted.
        case resumeDataRejected
    }

    public static func pauseDisposition() -> PauseDisposition {
        .cancelProducingResumeData
    }

    /// Whether a failed remainder task should be re-resumed from the blob the OS handed back.
    /// The blob's presence is the OS's own statement that the transfer is resumable, so any
    /// non-cancel error qualifies; the budget bounds pathological resume loops.
    public static func failureResumeDecision(errorCode: Int?,
                                             hasResumeData: Bool,
                                             currentBlobResumeCount: Int,
                                             maxBlobResumes: Int = defaultMaxBlobResumes) -> FailureResumeDecision {
        if errorCode == NSURLErrorCancelled {
            return .reject(.cancelled)
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

    /// URLSession resume data is the first recovery path for continuous remainders, but if the OS
    /// says the blob cannot be resumed (commonly because its temp file vanished) the safe fallback is
    /// to discard the blob and restart from the durable partial with a fresh open-ended Range.
    public static func durableFallbackReason(errorDomain: String,
                                             errorCode: Int,
                                             hasResumeData: Bool) -> DurableFallbackReason? {
        // If URLSession handed back another blob, try/adopt that before discarding temp progress.
        guard !hasResumeData else { return nil }
        if errorDomain == NSURLErrorDomain,
           [
               // URLSession may surface an invalid/corrupt resume blob as raw-data decode failure.
               NSURLErrorCannotDecodeRawData,
               // A blob whose backing temp disappeared commonly reports a missing/unopenable file.
               NSURLErrorFileDoesNotExist,
               NSURLErrorCannotOpenFile,
           ].contains(errorCode) {
            return .resumeDataCannotResume
        }
        if errorDomain == NSCocoaErrorDomain,
           errorCode == CocoaError.fileNoSuchFile.rawValue {
            return .resumeDataCannotResume
        }
        return nil
    }

    /// Persist the blob when parking a row (`.paused`/`.queued`) so a manual Resume — even after
    /// a relaunch — continues the OS-temp progress instead of re-fetching it.
    public static func shouldPersistBlobOnPark(hasResumeData: Bool,
                                               resumeDataWasRejected: Bool = false) -> Bool {
        hasResumeData && !resumeDataWasRejected
    }
}
