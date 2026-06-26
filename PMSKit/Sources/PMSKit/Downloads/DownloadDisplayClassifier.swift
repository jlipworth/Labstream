import Foundation

/// Pure display classification for an in-flight download row (GH #135 Stage 1c, extracted verbatim
/// from `DownloadManager`).
///
/// Whether a row's byte cadence reflects a live server-side transcoder (so the speed/ETA estimator
/// must treat it as encode-gated, not wire-bound) is a function of the row's lane + backend +
/// whether the server has reported a size yet. Keeping it here makes the rule testable and lets the
/// app, retry logic, and probes share one definition.
public enum DownloadDisplayClassifier {

    /// True when the transfer's byte rate is paced by a live encoder rather than the network, so the
    /// rate estimator should not present it as genuine wire speed.
    ///
    /// - `.original` (incl. existing-version): static, range-resumable → genuine wire speed → false.
    /// - `.optimize`: Plex phase-2 downloads a rendered static Part (network-bound once it exists),
    ///   so it's transcoder-gated only before the Part appears (`progress <= 0`); Jellyfin/Emby
    ///   optimize is a live encoder stream for the whole transfer → true.
    /// - `.compatibleRemux`: a live remux stream with no Content-Length is transcoder-gated → true,
    ///   but once the server reports a size (`progress > 0`) it's effectively static → false.
    public static func isLiveTranscoderSourced(_ record: DownloadRecord) -> Bool {
        let lane = record.metadata?.resolvedDownloadLane() ?? .original
        let backend = record.metadata?.resolvedBackendKind(ratingKey: record.ratingKey)
            ?? DownloadBackendKind(ratingKeyPrefix: record.ratingKey)
        switch lane {
        case .original:
            return false
        case .optimize:
            return backend == .plex ? record.progress <= 0 : true
        case .compatibleRemux:
            return record.progress <= 0
        }
    }
}
