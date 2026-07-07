import Foundation

/// Pure, privacy-safe completion-validation decisions shared by BOTH download transfer pipelines:
/// the opaque background `downloadTask` path (`didFinishDownloadingTo`) and the app-managed
/// byte-range `dataTask` path (`didCompleteWithError` range branch).
///
/// Historically each pipeline re-implemented "is this finished transfer a usable video, and what
/// row status should it get?" and the two DRIFTED (GH #135): the range path skipped the
/// `hev1`→`hvc1` HEVC tag fixup (#127 black-screen on every static MP4 download), skipped the
/// duration truncation guard, and condemned an inconclusive playability probe to `.failed` instead
/// of the #98 `.unverified` leniency the opaque path applies. Centralizing the *decidable* parts
/// here lets `BackgroundDownloadSession` funnel both pipelines through one finalize path, so a
/// static `hev1` download is fixed up and a probe miss is treated identically regardless of how the
/// bytes arrived.
///
/// Everything here is a pure function over value inputs — no IO, no AVFoundation — so the rules are
/// unit-testable. The impure steps (the on-disk `HEVCTagFixup.rewriteFile`, the AVFoundation
/// playability probe) stay in the session and feed their results into these decisions.
public enum DownloadCompletionValidation {

    /// MP4-family containers whose ISO-BMFF sample entries can carry an `hev1` FourCC that
    /// AVFoundation black-screens. The `hev1`→`hvc1` fixup is gated on the CONTAINER, not the lane
    /// (#127): a Plex `.original`/`.existingVersion` static download of a server-original MP4/MOV
    /// can be `hev1`-tagged just as easily as the #83 compatible-remux output. Other containers
    /// (mkv, …) are skipped — the FourCC rewrite doesn't apply to them.
    public static let hevcFixupContainers: Set<String> = ["mp4", "m4v", "mov"]

    /// Whether the post-download `hev1`→`hvc1` fixup should run for a file with this path
    /// extension. `HEVCTagFixup.rewriteFile` itself no-ops (returns 0) on non-HEVC / non-`hev1`
    /// bodies, so this is purely the cheap container gate that decides whether to bother scanning.
    public static func needsHEVCTagFixup(pathExtension: String) -> Bool {
        hevcFixupContainers.contains(pathExtension.lowercased())
    }

    /// A finished transfer whose HTTP response is an error page rather than a media body. Returns a
    /// privacy-safe failure reason (suitable for `.invalidDownload`), or nil when the response looks
    /// like real media. Mirrors the opaque pipeline's status + MIME guard so the rule is captured in
    /// one tested place. (An HTML/JSON/XML body is a backend error page, not a container; a truncated
    /// transcode still passes here and is caught later by the playability/truncation checks.)
    public static func errorPageReason(httpStatusCode: Int?, mimeType: String?) -> String? {
        if let status = httpStatusCode, !(200...299).contains(status) {
            return "Server returned HTTP \(status)."
        }
        if let mime = mimeType?.lowercased(),
           mime.hasPrefix("text/") || mime.contains("application/json") || mime.contains("application/xml") {
            return "Server returned a \(mime) page, not a video."
        }
        return nil
    }

    /// A decoded file shorter than this fraction of its expected source duration is treated as
    /// truncated rather than a legitimately short clip.
    public static let truncationThreshold = 0.80

    /// Whether a played-but-short file is TRUNCATED versus the expected source duration. A transcode
    /// that aborts early (or a static download the server cut short while still returning 2xx) can
    /// open and play its first second and otherwise pass the probe; a decoded duration far under the
    /// source's means it's incomplete. Decides only when BOTH durations are known and positive — a
    /// legitimate short clip compares against its own short duration and is not truncated.
    public static func isTruncated(expectedDurationMs: Int?, actualDurationMs: Int?) -> Bool {
        guard let expectedDurationMs, expectedDurationMs > 0,
              let actualDurationMs else { return false }
        return Double(actualDurationMs) < Double(expectedDurationMs) * truncationThreshold
    }

    /// The terminal outcome for a finished transfer, derived from the playability-probe result plus
    /// the source/decoded durations. The session maps each case to a row status + diagnostics:
    /// `.complete` → `.complete`; `.emptyFile` / `.truncated` → delete file + `.failed`;
    /// `.incompleteBytes` → KEEP the partial file as a resume checkpoint + `.failed`;
    /// `.unverified` → keep the file playable but `.unverified` (the #98 leniency: the probe is an
    /// intermittent false-negative on COMPLETE files, so never delete/`.failed` good bytes on a
    /// probe miss). Zero-byte "downloads" are not good bytes; they are a transfer failure and must
    /// stay retryable instead of becoming a playable unverified row.
    public enum CompletionOutcome: Equatable, Sendable {
        case complete
        case emptyFile
        /// The transfer produced fewer bytes than the source's EXACT byte size — a static
        /// byte-for-byte download can only be complete at exactly the source size. The playability
        /// probe cannot be trusted here in either direction: an MP4 with a leading moov opens,
        /// plays, and reports its FULL metadata duration from a fraction of its bytes (headset
        /// evidence: rows finalized `.complete` at one 64 MB chunk of a 5.9 GB file after an HTTP
        /// 416), and one with a trailing moov just probe-misses into a stuck `.unverified` loop.
        case incompleteBytes(actualBytes: Int, expectedBytes: Int)
        case truncated(actualDurationMs: Int, expectedDurationMs: Int)
        case unverified(reason: String)
    }

    /// Whether a finished transfer's byte count falls short of the source's exact size.
    /// `expectedExactBytes` must be an EXACT size (static-lane Content-Length / source part size),
    /// never a transcode estimate — estimates would misfire here.
    public static func isIncomplete(downloadedBytes: Int?, expectedExactBytes: Int?) -> Bool {
        guard let downloadedBytes, let expectedExactBytes, expectedExactBytes > 0 else { return false }
        return downloadedBytes > 0 && downloadedBytes < expectedExactBytes
    }

    /// Decide the terminal outcome. `played` and `probeReason` come from the AVFoundation
    /// playability probe (after the #98 retries); the durations come from the source metadata and
    /// the probe's decoded duration. `expectedExactBytes` is the source's exact byte size when the
    /// lane knows it (static byte-range downloads), nil for transcode lanes whose expected size is
    /// only an estimate.
    public static func outcome(played: Bool,
                               probeReason: String,
                               expectedDurationMs: Int?,
                               actualDurationMs: Int?,
                               downloadedBytes: Int? = nil,
                               expectedExactBytes: Int? = nil) -> CompletionOutcome {
        if let downloadedBytes, downloadedBytes <= 0 {
            return .emptyFile
        }
        if isIncomplete(downloadedBytes: downloadedBytes, expectedExactBytes: expectedExactBytes),
           let downloadedBytes, let expectedExactBytes {
            return .incompleteBytes(actualBytes: downloadedBytes, expectedBytes: expectedExactBytes)
        }
        guard played else { return .unverified(reason: probeReason) }
        if isTruncated(expectedDurationMs: expectedDurationMs, actualDurationMs: actualDurationMs),
           let expectedDurationMs, let actualDurationMs {
            return .truncated(actualDurationMs: actualDurationMs, expectedDurationMs: expectedDurationMs)
        }
        return .complete
    }
}
