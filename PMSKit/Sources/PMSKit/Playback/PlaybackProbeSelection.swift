import Foundation

/// Live probes must not silently play a fuzzy search result or an ambiguous title.
public enum PlaybackProbeSelection {
    public static func uniqueExactIndex(titles: [String], query: String) -> Int? {
        let matches = titles.indices.filter {
            titles[$0].localizedCaseInsensitiveCompare(query) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
