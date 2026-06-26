import Foundation

/// Pure storage-preflight size estimate for a live-transcoded download whose stream has no
/// Content-Length (GH #135 Stage 1b, extracted from `DownloadManager`).
///
/// A Jellyfin/Emby live transcode does not advertise a total size, so the download UI's
/// expected-bytes (for the progress fraction and the storage preflight) is estimated from the
/// target video bitrate × duration plus a modest audio/container allowance. The app resolves the
/// target profile (target name → bitrate) and feeds the bitrate in.
public enum TranscodeSizeEstimator {

    /// Audio/container allowance (bps) added to the selected video bitrate so the preflight is
    /// conservative without a server-reported size.
    public static let audioContainerAllowanceBps = 256_000

    /// Estimated total bytes for a `durationMs`-long transcode at `videoBitrateBps`. Returns nil
    /// when the duration is unknown/non-positive (the caller then has no estimate to show).
    public static func bytes(durationMs: Int?, videoBitrateBps: Int) -> Int? {
        guard let durationMs, durationMs > 0 else { return nil }
        let totalBitrate = videoBitrateBps + audioContainerAllowanceBps
        return Int((Double(durationMs) / 1000.0) * Double(totalBitrate) / 8.0)
    }
}
