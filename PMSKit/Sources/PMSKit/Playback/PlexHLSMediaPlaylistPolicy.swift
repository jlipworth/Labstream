import Foundation

/// A single-rendition Plex HDR master can be rejected on an SDR display before decoding.
/// Opening its media playlist preserves all encoded color metadata; never relabel HDR as SDR.
/// Only same-origin HTTP(S) children of an unambiguous single variant are eligible.
public enum PlexHLSMediaPlaylistPolicy {
    public static func mediaPlaylist(in master: String, baseURL: URL,
                                     hdrDisplayEligible: Bool) -> URL? {
        guard !hdrDisplayEligible,
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else { return nil }
        let lines = master.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lines.first == "#EXTM3U",
              !lines.contains(where: { $0.hasPrefix("#EXT-X-MEDIA:") }),
              lines.filter({ $0.hasPrefix("#EXT-X-STREAM-INF:") }).count == 1,
              let variantIndex = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }),
              lines.filter({ !$0.hasPrefix("#") }).count == 1,
              lines[variantIndex].dropFirst("#EXT-X-STREAM-INF:".count).split(separator: ",").contains(where: {
                  $0 == "VIDEO-RANGE=PQ" || $0 == "VIDEO-RANGE=HLG"
              }),
              variantIndex + 1 < lines.count else { return nil }
        let child = lines[variantIndex + 1]
        guard !child.isEmpty, !child.hasPrefix("#"),
              let url = URL(string: child, relativeTo: baseURL)?.absoluteURL,
              url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port,
              url.user == nil, url.password == nil,
              url.pathExtension.lowercased() == "m3u8" else { return nil }
        return url
    }
}
