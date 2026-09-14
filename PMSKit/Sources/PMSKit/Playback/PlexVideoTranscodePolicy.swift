/// Forces video encoding for explicit Maximum intent, an approved fallback, or the DV guard.
/// The caller retains the Original consent gate; an unapproved Original request stays copy-capable.
public enum PlexVideoTranscodePolicy {
    public static func shouldForceVideoTranscode(selectedQualityKbps: Int,
                                                 directPlayProductionFallback: Bool,
                                                 dolbyVisionGuardActive: Bool) -> Bool {
        dolbyVisionGuardActive
            || directPlayProductionFallback
            || selectedQualityKbps == StreamingQuality.maxTranscodedKbps
    }
}
