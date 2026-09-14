import Foundation

/// #304: avoid offset-primed HLS/proxy startup for the verified 10-bit SDR copy lane.
/// This does not choose a codec or relax a bitrate ceiling; it preserves negotiation.
public enum EmbyHEVCSDRTimelinePolicy {
    public static func shouldUseNativeTimeline(url: URL,
                                              playMethod: MediaBrowserPlayMethod?,
                                              source: MediaBrowserPlaybackSourceMetadata?,
                                              videoCopyEnforced: Bool,
                                              bitrateCeilingKbps: Int,
                                              requiresVideoTransform: Bool) -> Bool {
        guard playMethod == .transcode, !requiresVideoTransform,
              source?.videoCodec?.lowercased() == "hevc",
              source?.hdr?.format == .sdr, source?.hdr?.bitDepth == 10,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.pathExtension.lowercased() == "m3u8" else { return false }
        if videoCopyEnforced { return true }
        // For a capped negotiation, require positive copy-compatible evidence and
        // a known source bitrate within the ceiling. Unknown/video-transform reasons,
        // Maximum, and sources requiring a bitrate reduction retain the existing path.
        guard bitrateCeilingKbps > 0, let bitrate = source?.bitrate,
              bitrate > 0, bitrate <= bitrateCeilingKbps,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let values = query.filter { $0.name.lowercased() == "transcodereasons" }
        guard values.count == 1, let value = values[0].value, !value.isEmpty else { return false }
        let reasons = value.components(separatedBy: ",")
        return EmbyVideoCopyPolicy.canAttemptCopy(videoCodec: source?.videoCodec,
            transcodeReasons: reasons, requiresVideoTransform: false)
    }
}
