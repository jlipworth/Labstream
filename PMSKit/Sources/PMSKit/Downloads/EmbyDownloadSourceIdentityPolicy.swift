/// Identity gate for an explicitly selected Emby MediaSource.
///
/// PlaybackInfo may fall back to a different source when the requested converted/existing version
/// disappeared. That fallback is acceptable for ordinary item negotiation, but not when the caller
/// supplied a persisted `mediaSourceIDOverride`: silently downloading another source changes the
/// rendition behind the user's existing-version/retry intent.
public enum EmbyDownloadSourceIdentityPolicy {
    public static func accepts(explicitOverride: String?, decidedMediaSourceID: String) -> Bool {
        guard let explicitOverride, !explicitOverride.isEmpty else { return true }
        return decidedMediaSourceID == explicitOverride
    }
}
