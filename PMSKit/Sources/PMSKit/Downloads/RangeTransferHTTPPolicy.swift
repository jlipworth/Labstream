import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pure HTTP-header policy for the static byte-range transfer engine.
///
/// `BackgroundDownloadSession` owns URLSession tasks, temp files, and durable append/finalize side
/// effects. This helper owns only the string-level HTTP semantics that decide how an adopted or
/// newly-started Range task should be classified and validated. Keeping it in PMSKit pins the
/// subtle recovery behavior without needing app-target tests.
public enum RangeTransferHTTPPolicy {
    public static func isDurableCheckpointSegment(_ kind: RangeTransferSegmentKind) -> Bool {
        kind == .boundedCheckpoint || kind == .backgroundCheckpoint
    }

    /// A durable checkpoint segment is a closed Range request. If URLSession reports substantially
    /// more bytes than that closed segment could contain, the task is no longer useful as a
    /// checkpoint: letting it continue can park gigabytes in a temp file while the durable partial
    /// stays pinned at the old 64MB boundary.
    public static func isDurableSegmentOverrun(segmentKind: RangeTransferSegmentKind,
                                               chunkBytesWritten: Int,
                                               expectedSegmentBytes: Int?,
                                               graceBytes: Int) -> Bool {
        guard isDurableCheckpointSegment(segmentKind),
              let expectedSegmentBytes,
              expectedSegmentBytes > 0,
              graceBytes >= 0 else { return false }
        return chunkBytesWritten > expectedSegmentBytes + graceBytes
    }

    /// #220: whether an HTTP 200 body may replace the whole durable partial.
    ///
    /// A 200 to a ranged request means the server ignored/refused the range — the body is either
    /// the whole CURRENT resource (safe to adopt) or a truncated/garbage payload (must not clobber
    /// a good partial checkpoint). Adopt only when the body is plausibly whole: its size matches
    /// the expected total, the resource demonstrably changed (both validators present and
    /// different — the body is the whole NEW resource, whatever its size), or no expected total is
    /// known so there is no basis to reject. A size mismatch on an unchanged or unknowable
    /// resource is a truncated body → reject so the caller discards and retries from the durable
    /// checkpoint.
    public static func shouldAdoptReplaceWholeBody(stashBytes: Int?,
                                                   expectedBytes: Int?,
                                                   storedValidator: String?,
                                                   responseValidator: String?) -> Bool {
        guard let expectedBytes, expectedBytes > 0 else { return true }
        guard let stashBytes else { return false }
        if stashBytes == expectedBytes { return true }
        if let storedValidator, let responseValidator, storedValidator != responseValidator {
            return true
        }
        return false
    }

    /// Classify a task's `Range` header back into the segment strategy that created it.
    ///
    /// Only a single open-ended byte range (`bytes=<offset>-`) is a continuous remainder. Closed
    /// ranges are durable checkpoints; closed ranges larger than the active foreground chunk size are
    /// treated as older/larger background checkpoint segments when reattached after relaunch.
    public static func segmentKind(rangeHeader: String?, foregroundChunkSize: Int) -> RangeTransferSegmentKind {
        guard let rangeHeader else { return .boundedCheckpoint }
        let normalized = rangeHeader
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.hasPrefix("bytes=") else { return .boundedCheckpoint }
        let byteSpec = normalized
            .dropFirst("bytes=".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if byteSpec.range(of: #"^\d+-$"#, options: .regularExpression) != nil {
            return .continuousRemainder
        }
        if let length = closedRangeLength(byteSpec), length > foregroundChunkSize {
            return .backgroundCheckpoint
        }
        return .boundedCheckpoint
    }

    public static func closedRangeLength(_ byteSpec: String) -> Int? {
        guard byteSpec.range(of: #"^\d+-\d+$"#, options: .regularExpression) != nil else {
            return nil
        }
        let bounds = byteSpec.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let lower = Int(bounds[0]),
              let upper = Int(bounds[1]),
              upper >= lower else { return nil }
        return upper - lower + 1
    }

    /// HTTP validator for `If-Range`: prefer a strong `ETag`, fall back to `Last-Modified`.
    public static func strongIfRangeValidator(etag: String?, lastModified: String?) -> String? {
        if let etag = etag?.trimmingCharacters(in: .whitespaces),
           !etag.isEmpty, !etag.hasPrefix("W/"), !etag.hasPrefix("w/") {
            return etag
        }
        if let lastModified, !lastModified.isEmpty { return lastModified }
        return nil
    }

    public static func rangeValidator(from response: HTTPURLResponse?) -> String? {
        guard let response else { return nil }
        return strongIfRangeValidator(etag: response.value(forHTTPHeaderField: "ETag"),
                                      lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
    }

    /// Lower bound of `Content-Range: bytes <start>-<end>/<total>`, or nil if absent/unparseable.
    public static func contentRangeStart(_ value: String?) -> Int? {
        guard let value,
              let spec = value.split(separator: " ").last,
              let start = spec.split(separator: "-").first else { return nil }
        return Int(start)
    }

    public static func contentRangeStart(from response: HTTPURLResponse?) -> Int? {
        contentRangeStart(response?.value(forHTTPHeaderField: "Content-Range"))
    }

    /// Total size from `Content-Range: bytes <start>-<end>/<total>`, or nil for `*`/absent.
    public static func contentRangeTotal(_ value: String?) -> Int? {
        guard let value,
              let spec = value.split(separator: " ").last,
              let total = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).last,
              total != "*" else { return nil }
        return Int(total)
    }

    public static func contentRangeTotal(from response: HTTPURLResponse?) -> Int? {
        contentRangeTotal(response?.value(forHTTPHeaderField: "Content-Range"))
    }

    /// Whether a completed temp file can be accepted when URLSession internally resumed a closed
    /// Range request while the app was suspended. The response may report a later server offset even
    /// though URLSession assembled the full originally requested chunk in the temp file. Accept only
    /// when that resumed offset sits inside the planned segment and the temp byte count exactly
    /// matches the requested segment size; otherwise appending would risk a gap or overlap.
    public static func isCompleteInternallyResumedRangeChunk(baseOffset: Int,
                                                            contentRangeStart: Int?,
                                                            stashBytes: Int?,
                                                            expectedSegmentBytes: Int?) -> Bool {
        guard let contentRangeStart,
              let stashBytes,
              let expectedSegmentBytes,
              contentRangeStart > baseOffset,
              contentRangeStart < baseOffset + expectedSegmentBytes,
              stashBytes == expectedSegmentBytes else { return false }
        return true
    }

    public static func rangeRequestStart(_ rangeHeader: String?) -> Int? {
        guard let value = rangeHeader?.trimmingCharacters(in: .whitespaces),
              value.lowercased().hasPrefix("bytes=") else { return nil }
        let rangeSpec = value.dropFirst("bytes=".count)
        guard let start = rangeSpec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first,
              !start.isEmpty else { return nil }
        return Int(start)
    }

    public static func rangeRequestStart(from request: URLRequest?) -> Int? {
        rangeRequestStart(request?.value(forHTTPHeaderField: "Range"))
    }
}
