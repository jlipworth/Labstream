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
    /// played; out-of-range falls back to the first media. Pass
    /// `serverToneMapsUntaggedDV: false` for backends (Emby) whose transcoder cannot
    /// tone-map untagged P5 — the guard then blocks with `failureMessage` instead of
    /// forcing a transcode that bakes in garbage colors.
    static func verdict(for item: MediaItem,
                        mediaIndex: Int = 0,
                        serverToneMapsUntaggedDV: Bool = true) -> DolbyVisionPlaybackVerdict {
        DolbyVisionPlaybackPolicy.verdict(
            for: hdrMetadata(for: item, mediaIndex: mediaIndex),
            experimentalDVSignallingEnabled: experimentalSignallingEnabled,
            serverToneMapsUntaggedDV: serverToneMapsUntaggedDV)
    }

    /// GH #196 retest: only advertise DV capability to a server when this exact item is a
    /// signalling-eligible P8 (the injection lane). Advertising on every play while the
    /// toggle is on broke unrelated titles live: a DV P7 MKV that direct-played fine had
    /// its PMS start.m3u8 400 with the DV direct-play directive present, derailing it into
    /// a CPU transcode.
    static func shouldAdvertiseDolbyVision(for item: MediaItem, mediaIndex: Int = 0) -> Bool {
        playlistInjection(for: item, mediaIndex: mediaIndex) != nil
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
