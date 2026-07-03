import Foundation

/// Verdict for whether a video stream may travel a copy/remux lane (Direct Play /
/// Direct Stream / video stream-copy) or must be forced to a server-side tone-map
/// transcode (GH #196).
public enum DolbyVisionPlaybackVerdict: Sendable, Equatable {
    case allowCopyLanes
    case forceToneMapTranscode(reason: String)
    /// The server cannot tone-map an untagged P5 stream at all, so a forced transcode
    /// would "succeed" with IPTPQc2-as-YCbCr garbage colors. Refuse to open playback.
    case blockPlayback(reason: String)
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
    /// - Parameter serverToneMapsUntaggedDV: whether this backend's transcoder detects and
    ///   tone-maps a P5 input that carries no container color tags (P5's normal shape).
    ///   Jellyfin does (explicit `setparams` + `tonemap_cuda`); Emby does not — it encodes
    ///   the IPTPQc2 signal as plain YCbCr, baking green/purple tint into the output
    ///   (kubectl-verified 2026-07). When false, the P5 guard blocks instead of forcing.
    public static func verdict(for hdr: VideoHDRMetadata?,
                               experimentalDVSignallingEnabled: Bool,
                               serverToneMapsUntaggedDV: Bool = true) -> DolbyVisionPlaybackVerdict {
        guard !experimentalDVSignallingEnabled,
              let dv = hdr?.dolbyVision else { return .allowCopyLanes }
        let noFallbackLayer = dv.blCompatibilityID == 0 ||
            (dv.profile == 5 && dv.blCompatibilityID == nil)
        guard noFallbackLayer else { return .allowCopyLanes }
        return serverToneMapsUntaggedDV
            ? .forceToneMapTranscode(reason: "DV P5 guard (no fallback layer)")
            : .blockPlayback(reason: "DV P5 guard (server cannot tone-map P5)")
    }
}
