import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pure HTTP-header policy for the static byte-range transfer engine.
///
/// `BackgroundDownloadSession` owns URLSession tasks, temp files, and durable append/finalize side
/// effects. This helper owns only the string-level HTTP semantics needed for the single open-ended
/// remainder model and for safely dropping legacy closed-Range tasks on reattach.
public enum RangeTransferHTTPPolicy {
    /// #220: whether an HTTP 200 body may replace the whole durable partial.
    ///
    /// A 200 to a ranged request means the server ignored/refused the range — the body is either
    /// the whole CURRENT resource (safe to adopt) or a truncated/garbage payload (must not clobber
    /// a good partial checkpoint). Adopt only when the body is plausibly whole: its size matches
    /// the expected total, the resource demonstrably changed (both validators present and
    /// different — the body is the whole NEW resource, whatever its size), or no expected total is
    /// known so there is no basis to reject. A size mismatch on an unchanged or unknowable
    /// resource is a truncated body → reject so the caller discards and retries from the durable
    /// checkpoint. Independently of the expected total, a body smaller than the response's own
    /// declared `Content-Length` is truncated by definition — the validator-diff branch must not
    /// adopt it just because the resource changed (audit B.3 residual weakness).
    public static func shouldAdoptReplaceWholeBody(stashBytes: Int?,
                                                   expectedBytes: Int?,
                                                   storedValidator: String?,
                                                   responseValidator: String?,
                                                   responseContentLength: Int? = nil) -> Bool {
        if let responseContentLength, responseContentLength > 0,
           let stashBytes, stashBytes != responseContentLength {
            return false
        }
        guard let expectedBytes, expectedBytes > 0 else { return true }
        guard let stashBytes else { return false }
        if stashBytes == expectedBytes { return true }
        if let storedValidator, let responseValidator, storedValidator != responseValidator {
            return true
        }
        return false
    }

    /// Classify the `Range` header shape without treating closed ranges as adoptable work.
    public static func rangeRequestShape(_ rangeHeader: String?) -> StaticRangeRequestShape {
        guard let rangeHeader else { return .missing }
        let normalized = rangeHeader
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.hasPrefix("bytes=") else { return .invalid }
        let byteSpec = normalized
            .dropFirst("bytes=".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if byteSpec.range(of: #"^\d+-$"#, options: .regularExpression) != nil {
            return .openEnded
        }
        if byteSpec.range(of: #"^\d+-\d+$"#, options: .regularExpression) != nil {
            return .closed
        }
        return .invalid
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

    /// Whether a completed temp file can be accepted when URLSession internally resumed an
    /// open-ended Range request while the app was suspended. The response may report a later server
    /// offset even though URLSession assembled the full originally requested remainder in the temp
    /// file. Accept only when that resumed offset sits inside the planned body and the temp byte
    /// count exactly matches the expected body size; otherwise appending would risk a gap or overlap.
    public static func isCompleteInternallyResumedRangeBody(baseOffset: Int,
                                                           contentRangeStart: Int?,
                                                           stashBytes: Int?,
                                                           expectedBodyBytes: Int?) -> Bool {
        guard let contentRangeStart,
              let stashBytes,
              let expectedBodyBytes,
              contentRangeStart > baseOffset,
              contentRangeStart < baseOffset + expectedBodyBytes,
              stashBytes == expectedBodyBytes else { return false }
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

    /// The inclusive END bound of a closed `bytes=start-end` Range header, or nil for an
    /// open-ended (`bytes=start-`), absent, or malformed header. Used at reattach/lazy-adoption to
    /// recover a marked closed-range segment's byte length as `end - start + 1`.
    public static func rangeRequestEnd(_ rangeHeader: String?) -> Int? {
        guard let value = rangeHeader?.trimmingCharacters(in: .whitespaces),
              value.lowercased().hasPrefix("bytes=") else { return nil }
        let rangeSpec = value.dropFirst("bytes=".count)
        let parts = rangeSpec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        // Only a fully-bounded `start-end` range yields a length. A suffix range (`bytes=-N`) has an
        // empty start and is not something we ever emit for a segment, so treat it as no end bound.
        guard parts.count == 2 else { return nil }
        let start = parts[0].trimmingCharacters(in: .whitespaces)
        let end = parts[1].trimmingCharacters(in: .whitespaces)
        guard !start.isEmpty, !end.isEmpty else { return nil }
        return Int(end)
    }
}
