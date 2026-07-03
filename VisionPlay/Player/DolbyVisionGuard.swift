import Foundation
import PMSKit

/// App-side wrapper around `DolbyVisionPlaybackPolicy` (GH #196): resolves the item's
/// decoded HDR facts and the experimental-signalling preference into a copy-lane verdict.
enum DolbyVisionGuard {
    /// First-frame deadline for a guard-forced transcode. Jellyfin's P5 tone-map stalled
    /// server-side in live testing (segments never arrived), so the guard pairs the forced
    /// transcode with a deadline + specific error instead of an endless spinner.
    static let firstFrameTimeoutSeconds: TimeInterval = 20

    static let failureMessage =
        "This title uses Dolby Vision Profile 5, which this server could not convert."

    static var experimentalSignallingEnabled: Bool {
        UserDefaults.standard.bool(forKey: PlaybackPreferences.Keys.experimentalDVSignalling)
    }

    /// Verdict for a canonical item (any backend — Jellyfin/Emby items are bridged into
    /// canonical `Stream`s with DV facts since #195). `mediaIndex` selects the version being
    /// played; out-of-range falls back to the first media.
    static func verdict(for item: MediaItem, mediaIndex: Int = 0) -> DolbyVisionPlaybackVerdict {
        DolbyVisionPlaybackPolicy.verdict(
            for: hdrMetadata(for: item, mediaIndex: mediaIndex),
            experimentalDVSignallingEnabled: experimentalSignallingEnabled)
    }

    /// GH #196 spike (b): the HLS DV injection for this item's stream, or nil when the
    /// experimental setting is off or the stream has no valid SUPPLEMENTAL-CODECS form
    /// (only DV P8 with a known compatible base layer qualifies).
    static func playlistInjection(for item: MediaItem,
                                  mediaIndex: Int = 0) -> MediaSessionDolbyVisionInjection? {
        guard experimentalSignallingEnabled,
              let dv = hdrMetadata(for: item, mediaIndex: mediaIndex)?.dolbyVision else { return nil }
        return MediaSessionDolbyVisionInjection.forDolbyVision(dv)
    }

    private static func hdrMetadata(for item: MediaItem, mediaIndex: Int) -> VideoHDRMetadata? {
        let media = item.media?.indices.contains(mediaIndex) == true
            ? item.media?[mediaIndex]
            : item.media?.first
        return media?.part.first?.videoStreams.first?.hdrMetadata
    }
}
