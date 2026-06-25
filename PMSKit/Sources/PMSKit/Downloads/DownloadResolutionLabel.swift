import Foundation

/// Shared display bucketing for downloaded/existing media versions.
///
/// The label is intentionally a consumer-facing tier (4K/1080p/720p/480p), not
/// an exact pixel dump, because the download UI compares rendered versions against
/// preset tiers. Scope/wide-aspect encodes preserve width while reducing height
/// (for example 1920x800 for a 2.40:1 1080p-class movie), so bucket by either
/// height OR near-rung width.
public enum DownloadResolutionLabel {
    public static func label(width: Int?, height: Int?) -> String? {
        switch (width, height) {
        case let (w?, _) where w >= 3_800: return "4K"
        case let (_, h?) where h >= 2_160: return "4K"
        case let (w?, _) where w >= 1_900: return "1080p"
        case let (_, h?) where h >= 1_080: return "1080p"
        case let (w?, _) where w >= 1_260: return "720p"
        case let (_, h?) where h >= 720:   return "720p"
        case let (_, h?) where h >= 480:   return "480p"
        case let (w?, h?):                 return "\(w)×\(h)"
        default:                           return nil
        }
    }

    public static func label(forVideoResolution raw: String) -> String? {
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return label(width: w, height: h)
    }

    public static func label(forHeight height: Int?) -> String? {
        guard let h = height else { return nil }
        switch h {
        case let h where h >= 2160: return "4K"
        case let h where h >= 1080: return "1080p"
        case let h where h >= 720:  return "720p"
        case let h where h >= 480:  return "480p"
        default:                    return "\(h)p"
        }
    }
}
