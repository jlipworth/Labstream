/// Decides when Plex's universal HLS request must disable Direct Stream and re-encode video.
///
/// A high bitrate ceiling alone does not force a transcode: with `directStream=1`, PMS is free
/// to copy the source video into fMP4. That is desirable for the initial Direct Play / Maximum
/// probe, but it defeats both the explicit Maximum (HLS) transcode choice and every production
/// fallback after Direct Play probing or playback rejected the copy lane.
public enum PlexVideoTranscodePolicy {
    public static func shouldForceVideoTranscode(selectedQualityKbps: Int,
                                                 directPlayProductionFallback: Bool,
                                                 dolbyVisionGuardActive: Bool) -> Bool {
        dolbyVisionGuardActive
            || directPlayProductionFallback
            || selectedQualityKbps == StreamingQuality.maxTranscodedKbps
    }
}
