import Foundation

/// Emby uses `m4s` for fragmented MP4 HLS, unlike Jellyfin's `mp4` dialect.
/// Keep the same fail-closed video-copy and alternate-rendition validation contract.
public enum EmbyVideoCopyPolicy {
    public static func usesTransportStreamRecovery(videoCodec: String?, prefersStaticRecovery: Bool) -> Bool {
        prefersStaticRecovery && videoCodec?.lowercased() == "h264"
    }

    public static func canAttemptCopy(videoCodec: String?, transcodeReasons: [String],
                                      requiresVideoTransform: Bool) -> Bool {
        JellyfinVideoCopyPolicy.canAttemptCopy(videoCodec: videoCodec,
            transcodeReasons: transcodeReasons, requiresVideoTransform: requiresVideoTransform)
    }

    public static func copyURL(_ url: URL, forceAAC: Bool = false, useMPEGTS: Bool = false) -> URL? {
        guard let copy = JellyfinVideoCopyPolicy.copyURL(url),
              var components = URLComponents(url: copy, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = components.queryItems?.map {
            $0.name.caseInsensitiveCompare("SegmentContainer") == .orderedSame
                ? URLQueryItem(name: "SegmentContainer", value: useMPEGTS ? "ts" : "m4s") : $0
        }
        if forceAAC {
            components.queryItems?.removeAll {
                ["audiocodec", "allowaudiostreamcopy"].contains($0.name.lowercased())
            }
            components.queryItems?.append(contentsOf: [
                URLQueryItem(name: "AudioCodec", value: "aac"),
                URLQueryItem(name: "AllowAudioStreamCopy", value: "false")
            ])
        }
        return components.url
    }

    /// An on-demand VOD recovery child owns the full timeline. Preserve session and
    /// track authority but remove server priming before AVPlayer performs its own seek.
    public static func fullTimelineURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems?.removeAll { $0.name.caseInsensitiveCompare("StartTimeTicks") == .orderedSame }
        return components.url
    }

    public static func copyChild(in master: String, baseURL: URL, forceAAC: Bool = false, useMPEGTS: Bool = false) -> URL? {
        guard let child = JellyfinVideoCopyPolicy.copyChild(in: master, baseURL: baseURL) else { return nil }
        return copyURL(child, forceAAC: forceAAC, useMPEGTS: useMPEGTS)
    }
}
