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
    /// Bind a previously verified private corpus manifest to fresh full Plex metadata.
    /// IDs, not array positions, identify the source. Multipart playback is not covered.
    public static func plexMediaIndex(item: MediaItem, query: String, ratingKey: String,
                                      mediaID: Int, partID: Int) -> Int? {
        guard !ratingKey.isEmpty, item.ratingKey == ratingKey,
              item.title.localizedCaseInsensitiveCompare(query) == .orderedSame,
              item.type == "movie" || item.type == "episode",
              let media = item.media else { return nil }
        let matches = media.indices.filter { media[$0].id == mediaID }
        guard matches.count == 1, let index = matches.first,
              media[index].part.count == 1,
              media[index].part[0].id == partID else { return nil }
        return index
    }
}
