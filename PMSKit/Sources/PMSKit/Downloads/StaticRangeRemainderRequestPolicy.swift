import Foundation

/// How a finished static Range response body should be folded into the durable partial.
public enum StaticRangeBodyWrite: Equatable, Sendable {
    /// HTTP 206: the body is `[offset, …)`; append it onto the existing durable partial.
    case append
    /// HTTP 200: the server ignored `Range` and sent the entire resource; the temp IS the
    /// whole file, so the durable partial must be replaced (truncated) rather than appended.
    case replaceWhole
    /// HTTP 416: the requested offset is at/after EOF, so the durable partial already holds the
    /// whole file. Nothing to write — finalize/validate what is on disk.
    case alreadyComplete
    /// Any other status is a hard server error for this response body.
    case failServer(status: Int)
}

/// What to do after a 206 response body has been appended to the durable partial.
public enum StaticRangeRemainderNext: Equatable, Sendable {
    /// The durable partial now holds the whole file — finalize/validate it.
    case complete
    /// More remains; start a fresh open-ended remainder at this durable-partial offset.
    case continueFrom(offset: Int)
    /// The response reported success but added no bytes while bytes still remain — refuse to spin.
    case stalled
}

/// Shape of the only static-byte-range transfer Labstream now creates.
public enum RangeTransferSegmentKind: String, Equatable, Sendable {
    /// One open-ended remainder task so `nsurlsessiond` owns the remaining transfer. In-flight temp
    /// progress is non-durable until completion; pause/failure hold it in URLSession resume data,
    /// with the durable partial as fallback.
    case continuousRemainder
}

/// String-level shape of a task's `Range` request header.
public enum StaticRangeRequestShape: String, Equatable, Sendable {
    case missing
    case openEnded = "open_ended"
    case closed
    case invalid
}

/// Concrete request/validation plan for one static-byte-range background transfer.
public struct RangeTransferSegmentPlan: Equatable, Sendable {
    public let kind: RangeTransferSegmentKind
    public let rangeHeaderValue: String
    /// Expected bytes for THIS response body, when knowable. Used only for safety checks such as
    /// accepting URLSession's internally resumed body; never used as durable bytes.
    public let expectedBodyBytes: Int?

    public init(kind: RangeTransferSegmentKind = .continuousRemainder,
                rangeHeaderValue: String,
                expectedBodyBytes: Int?) {
        self.kind = kind
        self.rangeHeaderValue = rangeHeaderValue
        self.expectedBodyBytes = expectedBodyBytes
    }
}

/// Pure, IO-free decisions for the static Range download lane (#227/#231).
///
/// Labstream now uses one open-ended `Range: bytes=<durableOffset>-` background
/// `URLSessionDownloadTask` for the remaining bytes in every scene phase. URLSession resume data is
/// the first recovery path for non-durable in-flight temp bytes; if it is unavailable or stale, the
/// durable partial file size is the fallback checkpoint and a new open-ended remainder is created.
public struct StaticRangeRemainderRequestPolicy: Equatable, Sendable {
    public init() {}

    /// Build the request plan for the next static-byte-range transfer.
    public func segmentPlan(offset: Int, expectedBytes: Int?) -> RangeTransferSegmentPlan {
        let safeOffset = max(0, offset)
        return RangeTransferSegmentPlan(
            rangeHeaderValue: "bytes=\(safeOffset)-",
            expectedBodyBytes: expectedBodyBytes(offset: safeOffset, expectedBytes: expectedBytes)
        )
    }

    /// Expected body bytes for this open-ended remainder, when the total object size is known.
    /// Nil means "not knowable from the plan" and callers must not use it to accept a gapped append.
    public func expectedBodyBytes(offset: Int, expectedBytes: Int?) -> Int? {
        guard let expectedBytes else { return nil }
        return max(0, expectedBytes - max(0, offset))
    }

    /// How to incorporate a finished response given its HTTP status.
    public func writeDecision(httpStatus: Int) -> StaticRangeBodyWrite {
        switch httpStatus {
        case 206: return .append
        case 200: return .replaceWhole
        case 416: return .alreadyComplete
        default: return .failServer(status: httpStatus)
        }
    }

    /// After a 206 response body has been appended, decide whether the download is finished.
    /// Only meaningful for the `.append` path; 200/416 resolve via `writeDecision` directly.
    public func nextStep(partialSize: Int,
                         expectedBytes: Int?,
                         bodyBytes: Int) -> StaticRangeRemainderNext {
        if let expectedBytes {
            if partialSize >= expectedBytes { return .complete }
            if bodyBytes <= 0 { return .stalled }
            return .continueFrom(offset: partialSize)
        }
        // Unknown-size open-ended remainder: a successful response is the final body.
        return .complete
    }
}
