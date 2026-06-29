import Foundation

/// Pure derivation of the unified download progress fraction shown by the offline
/// Downloads UI (#97).
///
/// The three backends report progress differently:
/// - Plex original/optimized and Jellyfin/Emby `?static=true` originals stream a static
///   file with a real `Content-Length`, so `DownloadRecord.progress` is an EXACT 0…1
///   fraction.
/// - Jellyfin/Emby transcoded downloads stream straight from the live transcoder with NO
///   `Content-Length`, so `progress` stays `0` while `bytes` climb. For those rows we derive
///   an ESTIMATED fraction from `bytes / estimatedTotalBytes`, where `estimatedTotalBytes` is
///   the same duration×target-bitrate estimate that already powers the ETA — no new server
///   calls.
///
/// Keeping the selection rule and clamps here (rather than in the view) makes them unit-testable
/// without an app test target, and guarantees Plex/Jellyfin/Emby all present the same way.
public enum DownloadProgressDisplay {

    /// The unified fraction for a row's bar + caption.
    public struct Fraction: Sendable, Equatable {
        /// 0…1 progress to drive `ProgressView(value:)` and the `%` caption.
        public let value: Double
        /// `true` when `value` is the duration×bitrate ESTIMATE (no `Content-Length`), so the
        /// UI can mark it approximate (e.g. `~63%`). `false` for an exact `Content-Length` fraction.
        public let isEstimated: Bool

        public init(value: Double, isEstimated: Bool) {
            self.value = value
            self.isEstimated = isEstimated
        }
    }

    /// Upper bound for the estimated fraction. An estimate must NEVER read 100% before the
    /// real terminal `.complete` status flips the row — completion keys off `record.isComplete`,
    /// never the bar — so a clamped "almost there" ceiling keeps visual ≠ completion decoupled.
    public static let estimatedCeiling = 0.99

    /// Shared display state for the post-transfer phase: the byte transfer is done (the exact
    /// progress source reached 100%), but the row has not yet reached a terminal validated status.
    ///
    /// This intentionally keys off the backend-agnostic record shape (`.downloading` + exact
    /// progress at 1.0) rather than Plex/Jellyfin/Emby specifics. It lets the app present an honest
    /// "verifying/finalizing" caption while the shared transfer-finalization path runs HEVC tag
    /// fixup, local playback validation, and truncation checks.
    public static func isTransferFinalizing(status: DownloadStatus, progress: Double) -> Bool {
        status == .downloading && progress.isFinite && progress >= 1.0
    }

    /// Shared display state for server-side preparation handoff (#186): the server reports the
    /// transcode/convert at 100%, but the app is still waiting for the prepared Part/MediaSource to
    /// become downloadable/indexed before the real file transfer starts. This must not reuse the local
    /// transfer-finalization helper above because no bytes have been downloaded yet.
    public static func isServerPrepFinalizing(state: String?, progress: Double?) -> Bool {
        if state?.caseInsensitiveCompare("finalizing") == .orderedSame { return true }
        guard let progress, progress.isFinite else { return false }
        return progress >= 1.0
    }

    /// Derive the unified fraction.
    ///
    /// - Parameters:
    ///   - progress: the server-reported `Content-Length` fraction (`DownloadRecord.progress`).
    ///     `> 0` means a real size was reported → exact path.
    ///   - bytes: bytes transferred so far (`DownloadRecord.bytes`).
    ///   - estimatedTotalBytes: the duration×bitrate estimate for a transcoder-streamed row, or
    ///     `nil` when no estimate is available (e.g. an original/static row, or missing duration).
    /// - Returns: the exact fraction when `progress > 0`; otherwise the clamped estimated fraction
    ///   when bytes are flowing and an estimate exists; otherwise `nil` (caller keeps the spinner).
    public static func fraction(progress: Double,
                                bytes: Int,
                                estimatedTotalBytes: Int?) -> Fraction? {
        if progress > 0 {
            // Exact path: Plex original/optimized, JF/Emby `.original`. Guard a server over-report.
            return Fraction(value: min(progress, 1.0), isEstimated: false)
        }
        guard bytes > 0,
              let estimatedTotalBytes, estimatedTotalBytes > 0 else { return nil }
        let raw = Double(bytes) / Double(estimatedTotalBytes)
        return Fraction(value: min(raw, estimatedCeiling), isEstimated: true)
    }
}
