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
        guard let d = dimensions(forVideoResolution: raw) else { return nil }
        return label(width: d.width, height: d.height)
    }

    /// Parse a `"WIDTHxHEIGHT"` video-resolution string (case-insensitive) into pixel dimensions.
    /// Shared so the optimized-version matcher and the label logic use one parser (GH #135 Stage 1a
    /// — was an inline copy in `DownloadManager` that did not lowercase).
    public static func dimensions(forVideoResolution raw: String) -> (width: Int, height: Int)? {
        let parts = raw.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (width: parts[0], height: parts[1])
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
