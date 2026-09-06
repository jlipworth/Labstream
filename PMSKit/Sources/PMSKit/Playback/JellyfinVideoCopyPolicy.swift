import Foundation

/// Original-quality Jellyfin HLS must never expose an encoder variant to AVPlayer.
/// `AllowVideoStreamCopy` is permission, not a decision. Explicit `VideoCodec=copy`
/// keeps the server's audio conversion while forbidding video encoding.
public enum JellyfinVideoCopyPolicy {
    public static func canAttemptCopy(videoCodec: String?, transcodeReasons: [String],
                                      requiresVideoTransform: Bool) -> Bool {
        guard !requiresVideoTransform,
              ["h264", "hevc"].contains(videoCodec?.lowercased() ?? "") else { return false }
        let copySafeReasons: Set<String> = [
            "ContainerNotSupported", "AudioCodecNotSupported", "AudioProfileNotSupported",
            "AudioChannelsNotSupported", "AudioBitrateNotSupported", "AudioSampleRateNotSupported",
            "AudioBitDepthNotSupported", "ContainerBitrateExceedsLimit"
        ]
        return transcodeReasons.allSatisfy { copySafeReasons.contains($0) }
    }

    public static func copyURL(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.host != nil, c.user == nil, c.password == nil,
              url.pathExtension.lowercased() == "m3u8" else { return nil }
        let replacements = ["VideoCodec": "copy", "AllowVideoStreamCopy": "true",
                            "SegmentContainer": "mp4", "EnableAdaptiveBitrateStreaming": "false"]
        var items = c.queryItems ?? []
        items.removeAll { item in replacements.keys.contains { $0.caseInsensitiveCompare(item.name) == .orderedSame } }
        items += replacements.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        c.queryItems = items
        return c.url
    }

    /// Jellyfin adds SDR encode alternatives to HDR-copy masters. Select only the primary
    /// copy child, never an alternate that explicitly disables copy. Do not drop external
    /// audio/subtitle renditions: those require a separately validated delivery path.
    public static func copyChild(in master: String, baseURL: URL) -> URL? {
        let lines = master.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U",
              !lines.contains(where: { $0.hasPrefix("#EXT-X-MEDIA:") }),
              let index = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }),
              index + 1 < lines.count, !lines[index + 1].hasPrefix("#"),
              let child = URL(string: lines[index + 1], relativeTo: baseURL)?.absoluteURL,
              child.scheme == baseURL.scheme, child.host == baseURL.host, child.port == baseURL.port,
              let query = URLComponents(url: child, resolvingAgainstBaseURL: false)?.queryItems,
              query.filter({ $0.name.lowercased() == "videocodec" }).map(\.value) == ["copy"],
              !query.contains(where: { $0.name.lowercased() == "allowvideostreamcopy" && $0.value?.lowercased() != "true" })
        else { return nil }
        return copyURL(child)
    }
}
