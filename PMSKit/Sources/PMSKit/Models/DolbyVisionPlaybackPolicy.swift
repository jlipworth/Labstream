import Foundation

/// Verdict for whether a video stream may travel a copy/remux lane (Direct Play /
/// Direct Stream / video stream-copy) or must be forced to a server-side tone-map
/// transcode (GH #196).
public enum DolbyVisionPlaybackVerdict: Sendable, Equatable {
    case allowCopyLanes
    case forceToneMapTranscode(reason: String)
}

/// The DV Profile 5 safety guard (GH #196).
///
/// Live-verified failure matrix (2026-07): a DV P5 (IPTPQc2, BL-compat 0) stream on a
/// copy lane — where the remux strips DV signalling — fails on every backend, each
/// differently: Plex → decoder-not-found (VT -12906), Jellyfin → samples rejected then
/// the fallback transcode stalls, Emby → silent black screen. P5 has no
/// backwards-compatible base layer, so nothing recoverable reaches the display.
///
/// P7/P8 streams with an HDR10/SDR/HLG-compatible base layer are proven correct on copy
/// lanes (they render the fallback layer) and must stay there.
public enum DolbyVisionPlaybackPolicy {
    /// - Parameter experimentalDVSignallingEnabled: when the user opted into the
    ///   experimental DV signalling lane, the guard defers — that lane's whole point is
    ///   delivering P5 with its DV signalling intact, so forcing a transcode here would
    ///   contradict it.
    public static func verdict(for hdr: VideoHDRMetadata?,
                               experimentalDVSignallingEnabled: Bool) -> DolbyVisionPlaybackVerdict {
        guard !experimentalDVSignallingEnabled,
              let dv = hdr?.dolbyVision else { return .allowCopyLanes }
        if dv.blCompatibilityID == 0 {
            return .forceToneMapTranscode(reason: "DV P5 guard (no fallback layer)")
        }
        if dv.profile == 5, dv.blCompatibilityID == nil {
            return .forceToneMapTranscode(reason: "DV P5 guard (no fallback layer)")
        }
        return .allowCopyLanes
    }
}
