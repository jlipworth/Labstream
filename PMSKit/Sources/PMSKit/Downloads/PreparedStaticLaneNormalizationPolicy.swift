import Foundation

/// Repairs the legacy Plex rendered-Part handoff shape written before the handoff atomically moved
/// from the encoder lane to the static artifact lane. The three facts together are deliberately
/// narrow: Jellyfin live transcodes and Plex rows still in server preparation must never normalize.
public enum PreparedStaticLaneNormalizationPolicy {
    public static func shouldNormalize(metadata: OfflineMetadata?, ratingKey: String) -> Bool {
        guard let metadata else { return false }
        let backend = metadata.resolvedBackendKind(ratingKey: ratingKey)
        return backend == .plex
            && metadata.resolvedDownloadLane() == .optimize
            && metadata.resolvedResumeMode(ratingKey: ratingKey) == .staticByteRange
            && metadata.isServerPreparedVersion
    }

    @discardableResult
    public static func normalize(metadata: inout OfflineMetadata?, ratingKey: String) -> Bool {
        guard shouldNormalize(metadata: metadata, ratingKey: ratingKey), var repaired = metadata else {
            return false
        }
        repaired.downloadLane = .original
        metadata = repaired
        return true
    }
}
