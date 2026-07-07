import Foundation

/// How a finished Range chunk's temp file should be folded into the durable partial.
public enum RangeChunkWrite: Equatable, Sendable {
    /// HTTP 206: the body is `[offset, …)`; append it onto the existing durable partial.
    case append
    /// HTTP 200: the server ignored `Range` and sent the entire resource; the temp IS the
    /// whole file, so the durable partial must be replaced (truncated) rather than appended —
    /// otherwise real bytes land after a stale prefix and corrupt the file (#135 H5 lesson).
    case replaceWhole
    /// HTTP 416: the requested offset is at/after EOF, so the durable partial already holds the
    /// whole file. Nothing to write — finalize/validate what is on disk.
    case alreadyComplete
    /// Any other status is a hard server error for this chunk.
    case failServer(status: Int)
}

/// What to do after a 206 chunk has been appended to the durable partial.
public enum RangeChunkNext: Equatable, Sendable {
    /// The durable partial now holds the whole file — finalize/validate it.
    case complete
    /// More remains; start the next chunk at this durable-partial offset.
    case continueFrom(offset: Int)
    /// The chunk reported success but added no bytes while bytes still remain — refuse to spin.
    case stalled
}

/// Shape of the next background-owned static-byte-range transfer.
public enum RangeTransferSegmentKind: String, Equatable, Sendable {
    /// Foreground/active app path: bounded slices give frequent durable checkpoints.
    case boundedCheckpoint
    /// Legacy off-head path: bounded slices let `nsurlsessiond` own a background task while
    /// capping non-durable temp progress between app wakeups. No longer produced for new
    /// segments (each wakeup feeds the OS resume rate limiter — #212); retained to classify
    /// reattached tasks from older sessions.
    case backgroundCheckpoint
    /// Off-head/background path (#212): one open-ended remainder task so `nsurlsessiond`
    /// finishes the file without waking the app per chunk. Temp progress is non-durable until
    /// completion; pause/failure hold it in URLSession resume data.
    case continuousRemainder
}

/// Concrete request/validation plan for one static-byte-range background transfer.
public struct RangeTransferSegmentPlan: Equatable, Sendable {
    public let kind: RangeTransferSegmentKind
    public let rangeHeaderValue: String?
    /// Expected bytes for THIS transfer segment, when knowable. Used only for safety checks such as
    /// adopting URLSession's internal resume of a closed Range request; never used as durable bytes.
    public let expectedSegmentBytes: Int?

    public init(kind: RangeTransferSegmentKind,
                rangeHeaderValue: String?,
                expectedSegmentBytes: Int?) {
        self.kind = kind
        self.rangeHeaderValue = rangeHeaderValue
        self.expectedSegmentBytes = expectedSegmentBytes
    }
}

/// Pure, IO-free decisions for the chunked Range download lane (#169).
///
/// The static byte-range lane survives the headset coming off only as a true background
/// `URLSessionDownloadTask`, but a background task hands back its temp file only on completion —
/// it cannot byte-append into our durable partial mid-flight. While active, we download bounded
/// `Range` chunks and append each finished chunk into the durable partial. When the app is likely
/// going off-head, the next plan is one open-ended continuous remainder (#212) so `nsurlsessiond`
/// finishes the file without waking the app per chunk; pause/failure hold the remainder's
/// non-durable temp in URLSession resume data.
/// The partial remains the real checkpoint (`DownloadStore.reconcile`'s `hasAppRangeCheckpoint`)
/// across force-quit/relaunch: if an in-flight segment is lost, only bytes already appended to that
/// partial are durable.
///
/// `chunkSize <= 0` degrades to a single open-ended `bytes=offset-` request; the same
/// append/finalize path still applies.
public struct RangeChunkPlanner: Equatable, Sendable {
    public let chunkSize: Int
    public let backgroundChunkSize: Int

    public init(chunkSize: Int, backgroundChunkSize: Int? = nil) {
        self.chunkSize = chunkSize
        self.backgroundChunkSize = backgroundChunkSize ?? chunkSize
    }

    /// The `Range` header value for a chunk starting at `offset`, or `nil` to omit the header
    /// entirely (a plain GET — only at offset 0 with no chunk bound).
    public func rangeHeaderValue(offset: Int, expectedBytes: Int?) -> String? {
        segmentPlan(offset: offset,
                    expectedBytes: expectedBytes,
                    kind: .boundedCheckpoint).rangeHeaderValue
    }

    /// Build the request plan for the next static-byte-range transfer.
    public func segmentPlan(offset: Int,
                            expectedBytes: Int?,
                            kind: RangeTransferSegmentKind) -> RangeTransferSegmentPlan {
        switch kind {
        case .boundedCheckpoint, .backgroundCheckpoint:
            return RangeTransferSegmentPlan(
                kind: kind,
                rangeHeaderValue: boundedRangeHeaderValue(offset: offset,
                                                          expectedBytes: expectedBytes,
                                                          chunkSize: chunkSize(for: kind)),
                expectedSegmentBytes: expectedSegmentBytes(
                    offset: offset,
                    expectedBytes: expectedBytes,
                    kind: kind
                )
            )
        case .continuousRemainder:
            let safeOffset = max(0, offset)
            return RangeTransferSegmentPlan(
                kind: kind,
                rangeHeaderValue: "bytes=\(safeOffset)-",
                expectedSegmentBytes: expectedSegmentBytes(
                    offset: safeOffset,
                    expectedBytes: expectedBytes,
                    kind: kind
                )
            )
        }
    }

    private func chunkSize(for kind: RangeTransferSegmentKind) -> Int {
        kind == .backgroundCheckpoint ? backgroundChunkSize : chunkSize
    }

    private func boundedRangeHeaderValue(offset: Int, expectedBytes: Int?, chunkSize: Int) -> String? {
        guard chunkSize > 0 else {
            return offset > 0 ? "bytes=\(offset)-" : nil
        }
        var upper = offset + chunkSize - 1
        if let expectedBytes {
            upper = min(upper, expectedBytes - 1)
        }
        // Offset is at/after the known EOF: ask open-ended so the server answers 416 and we
        // resolve completion from the durable partial rather than inventing a backwards range.
        guard upper >= offset else { return "bytes=\(offset)-" }
        return "bytes=\(offset)-\(upper)"
    }

    /// Expected body bytes for this segment, when the total object size is known or the segment is a
    /// bounded chunk. Nil means "not knowable from the plan" and callers must not use it to accept a
    /// potentially gapped append.
    public func expectedSegmentBytes(offset: Int,
                                     expectedBytes: Int?,
                                     kind: RangeTransferSegmentKind) -> Int? {
        switch kind {
        case .continuousRemainder:
            guard let expectedBytes else { return nil }
            return max(0, expectedBytes - max(0, offset))
        case .boundedCheckpoint, .backgroundCheckpoint:
            let plannedChunkSize = chunkSize(for: kind)
            guard plannedChunkSize > 0 else {
                guard let expectedBytes else { return nil }
                return max(0, expectedBytes - max(0, offset))
            }
            if let expectedBytes {
                return max(0, min(plannedChunkSize, expectedBytes - max(0, offset)))
            }
            return plannedChunkSize
        }
    }

    /// How to incorporate a finished chunk given its HTTP status and the offset it began at.
    public func writeDecision(httpStatus: Int, offset: Int) -> RangeChunkWrite {
        switch httpStatus {
        case 206: return .append
        case 200: return .replaceWhole
        case 416: return .alreadyComplete
        default: return .failServer(status: httpStatus)
        }
    }

    /// After a 206 chunk has been appended, decide whether the download is finished.
    /// Only meaningful for the `.append` path; 200/416 resolve via `writeDecision` directly.
    public func nextStep(partialSize: Int, expectedBytes: Int?, chunkBytes: Int) -> RangeChunkNext {
        nextStep(partialSize: partialSize,
                 expectedBytes: expectedBytes,
                 chunkBytes: chunkBytes,
                 kind: .boundedCheckpoint)
    }

    /// Decide the next transfer after appending a 206 body. Continuous-remainder transfers still
    /// continue when a known-size response ended short, but an unknown-size open-ended remainder is
    /// by definition the final segment and must not be followed by a blind 64 MB chunk.
    public func nextStep(partialSize: Int,
                         expectedBytes: Int?,
                         chunkBytes: Int,
                         kind: RangeTransferSegmentKind) -> RangeChunkNext {
        if let expectedBytes {
            if partialSize >= expectedBytes { return .complete }
            if chunkBytes <= 0 { return .stalled }
            return .continueFrom(offset: partialSize)
        }
        if kind == .continuousRemainder { return .complete }
        // Unknown final size: an open-ended chunk fetched the rest; a bounded chunk that came back
        // short (or empty) hit EOF; only a full-sized chunk implies more remains.
        let plannedChunkSize = chunkSize(for: kind)
        if plannedChunkSize <= 0 { return .complete }
        if chunkBytes <= 0 || chunkBytes < plannedChunkSize { return .complete }
        return .continueFrom(offset: partialSize)
    }
}
