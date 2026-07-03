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
        let media = item.media?.indices.contains(mediaIndex) == true
            ? item.media?[mediaIndex]
            : item.media?.first
        let hdr = media?.part.first?.videoStreams.first?.hdrMetadata
        return DolbyVisionPlaybackPolicy.verdict(
            for: hdr,
            experimentalDVSignallingEnabled: experimentalSignallingEnabled)
    }
}
