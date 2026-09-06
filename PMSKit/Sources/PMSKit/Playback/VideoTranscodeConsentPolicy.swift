/// Video-copy remux and audio conversion do not require video-encoding consent.
/// Unknown decisions must not silently authorize video encoding for Original quality.
public enum VideoTranscodeConsentPolicy {
    public static func requiresConsent(selectedQualityKbps: Int,
                                       approvedForCurrentItem: Bool,
                                       videoDecision: String?,
                                       forcesVideoEncoding: Bool) -> Bool {
        guard selectedQualityKbps <= 0, !approvedForCurrentItem else { return false }
        if forcesVideoEncoding { return true }
        switch videoDecision?.lowercased() {
        case "copy", "directplay": return false
        default: return true
        }
    }
}
