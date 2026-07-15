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
    /// - `.optimize`: a `serverPrepThenStatic` row (Plex optimize, Emby persistent Convert) downloads
    ///   a rendered static file (network-bound once it exists), so it's transcoder-gated only before
    ///   that file appears (`progress <= 0`). Jellyfin optimize — and legacy Emby rows without a
    ///   Convert job — resolve `liveForwardOnly`: a live encoder stream for the whole transfer → true.
    /// - `.compatibleRemux`: a live remux stream with no Content-Length is transcoder-gated → true,
    ///   but once the server reports a size (`progress > 0`) it's effectively static → false.
    public static func isLiveTranscoderSourced(_ record: DownloadRecord) -> Bool {
        let lane = record.metadata?.resolvedDownloadLane() ?? .original
        switch lane {
        case .original:
            return false
        case .optimize:
            let resumeMode = record.metadata?.resolvedResumeMode(ratingKey: record.ratingKey)
            switch resumeMode {
            case .liveForwardOnly:
                return true
            case .staticByteRange:
                // The server has already rendered a concrete file and the row has handed off to
                // ordinary Range transfer. Persisted progress can legitimately remain zero until
                // the first large segment is committed, but that does not make the transfer
                // encoder-paced.
                return false
            case .serverPrepThenStatic, nil:
                return record.progress <= 0
            }
        case .compatibleRemux:
            return record.progress <= 0
        }
    }
}
