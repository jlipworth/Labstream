import Foundation

/// Live probes must not silently play a fuzzy search result or an ambiguous title.
public enum PlaybackProbeSelection {
    /// Backend identities are opaque and case-sensitive, unlike human-readable titles.
    public static func matchesExpectedIdentity(_ expected: String?, actual: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return false }
        return actual == expected
    }

    public static func uniqueExactIndex(titles: [String], query: String) -> Int? {
        let matches = titles.indices.filter {
            titles[$0].localizedCaseInsensitiveCompare(query) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
