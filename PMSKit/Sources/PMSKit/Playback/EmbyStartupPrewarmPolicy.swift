import Foundation

/// Emby's cold AV1 decode/encode can outlive AVFoundation's first-media deadline.
/// A bounded warm-up keeps the initial request alive before AVPlayer attaches.
public enum EmbyStartupPrewarmPolicy {
    public static let budgetSeconds: Double = 20

    public static func shouldPrewarm(isTranscode: Bool, videoCodec: String?, resumeMilliseconds: Int?) -> Bool {
        isTranscode && videoCodec?.lowercased() == "av1"
            && (resumeMilliseconds == nil || resumeMilliseconds == 0)
    }
}
