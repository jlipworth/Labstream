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

/// Pure, IO-free decisions for the chunked Range download lane (#169).
///
/// The static byte-range lane survives the headset coming off only as a true background
/// `URLSessionDownloadTask`, but a background task hands back its temp file only on completion —
/// it cannot byte-append into our durable partial mid-flight. So we download the file as a
/// sequence of bounded `Range` chunks and append each finished chunk into the durable partial.
/// That keeps the partial a real on-disk checkpoint (`DownloadStore.reconcile`'s
/// `hasAppRangeCheckpoint`) across force-quit/relaunch — only the in-flight chunk is ever re-fetched
/// — while each chunk transfer runs under `nsurlsessiond` and continues while the app is suspended.
///
/// `chunkSize <= 0` degrades to a single open-ended `bytes=offset-` request (used when the final
/// size is unknown and bounding is not worth a guess); the same append/finalize path still applies.
public struct RangeChunkPlanner: Equatable, Sendable {
    public let chunkSize: Int

    public init(chunkSize: Int) {
        self.chunkSize = chunkSize
    }

    /// The `Range` header value for a chunk starting at `offset`, or `nil` to omit the header
    /// entirely (a plain GET — only at offset 0 with no chunk bound).
    public func rangeHeaderValue(offset: Int, expectedBytes: Int?) -> String? {
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
        if let expectedBytes {
            if partialSize >= expectedBytes { return .complete }
            if chunkBytes <= 0 { return .stalled }
            return .continueFrom(offset: partialSize)
        }
        // Unknown final size: an open-ended chunk fetched the rest; a bounded chunk that came back
        // short (or empty) hit EOF; only a full-sized chunk implies more remains.
        if chunkSize <= 0 { return .complete }
        if chunkBytes <= 0 || chunkBytes < chunkSize { return .complete }
        return .continueFrom(offset: partialSize)
    }
}
