/// Resolves the durable resolution label after Emby's authoritative PlaybackInfo negotiation.
///
/// A server-prepared/existing version can have different dimensions from the item's primary media.
/// Its negotiated dimensions therefore replace the queue-time label. Genuine originals retain the
/// source-derived label, and incomplete negotiated facts preserve the existing safe fallback.
public enum EmbyDownloadResolutionPolicy {
    public static func persistedLabel(
        choice: DownloadIntentChoice,
        currentLabel: String?,
        negotiatedWidth: Int?,
        negotiatedHeight: Int?
    ) -> String? {
        guard DownloadChoicePolicy.isServerPreparedVersion(for: choice),
              let negotiatedLabel = DownloadResolutionLabel.label(
                width: negotiatedWidth,
                height: negotiatedHeight
              ) else {
            return currentLabel
        }
        return negotiatedLabel
    }
}
