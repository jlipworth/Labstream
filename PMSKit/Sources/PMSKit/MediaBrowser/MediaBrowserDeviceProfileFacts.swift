import Foundation

/// The only streaming-profile difference shared composition needs to know about subtitles.
/// Jellyfin can expose WebVTT renditions in HLS; Emby must burn every selected subtitle format.
enum MediaBrowserStreamingSubtitlePolicy: Sendable, Equatable {
    case jellyfinManifest(enabled: Bool)
    case embyEncodeSelected
}

/// Wire-shape facts genuinely shared by Jellyfin and Emby. Backend request builders still own
/// their outer PlaybackInfo bodies and select an explicit subtitle policy; Emby's stricter
/// general-purpose static download profile deliberately does not use this helper.
enum MediaBrowserDeviceProfileFacts {
    static var directPlayProfiles: [[String: Any]] { [
        ["Type": "Video", "Container": "mp4,m4v,mov", "VideoCodec": "h264,hevc",
         "AudioCodec": "aac,ac3,eac3"],
        ["Type": "Video", "Container": "mpegts", "VideoCodec": "h264",
         "AudioCodec": "aac,ac3,eac3"],
    ] }

    static var compatibleRemuxDirectPlayProfiles: [[String: Any]] { [
        ["Type": "Video", "Container": "mp4,m4v,mov", "VideoCodec": "h264,hevc",
         "AudioCodec": "aac,ac3,eac3"],
    ] }

    static var compatibleRemuxStaticTranscodingProfiles: [[String: Any]] { [
        [
            "Type": "Video",
            "Container": "mp4",
            "Protocol": "http",
            "VideoCodec": "h264,hevc",
            "AudioCodec": "aac",
            "Context": "Static",
            "BreakOnNonKeyFrames": false,
        ],
    ] }

    /// Declaring every supported VideoRangeType, including DOVI variants, preserves dvcC/RPU
    /// metadata on compatible remux. This remains opt-in at each backend playback builder.
    static var dolbyVisionCodecProfiles: [[String: Any]] { [
        [
            "Type": "Video",
            "Codec": "hevc",
            "Conditions": [
                [
                    "Condition": "EqualsAny",
                    "Property": "VideoRangeType",
                    "Value": "SDR|HDR10|HLG|HDR10Plus|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR|DOVIWithHDR10Plus",
                    "IsRequired": false,
                ],
            ],
        ],
    ] }

    static func streamingHLSTranscodingProfiles(
        subtitlePolicy: MediaBrowserStreamingSubtitlePolicy
    ) -> [[String: Any]] {
        var profile: [String: Any] = [
            "Type": "Video",
            "Container": "ts",
            "Protocol": "hls",
            // h264 remains the encode target; hevc permits video-copy remux of HEVC sources.
            "VideoCodec": "h264,hevc",
            "AudioCodec": "aac,ac3",
            "Context": "Streaming",
            "MinSegments": 2,
            "BreakOnNonKeyFrames": false,
        ]
        if case .jellyfinManifest(let enabled) = subtitlePolicy {
            profile["EnableSubtitlesInManifest"] = enabled
        }
        return [profile]
    }

    static func subtitleProfiles(
        policy: MediaBrowserStreamingSubtitlePolicy
    ) -> [[String: Any]]? {
        guard policy == .embyEncodeSelected else { return nil }
        return ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "sub", "idx",
                "pgssub", "dvdsub", "dvbsub"].map {
            ["Format": $0, "Method": "Encode"]
        }
    }

    static func compatibleRemuxDownloadProfile(maxStaticBitrate: Int) -> [String: Any] {
        [
            "Name": "Labstream-Compatible-Download",
            "MaxStaticBitrate": maxStaticBitrate,
            "MaxStreamingBitrate": maxStaticBitrate,
            "DirectPlayProfiles": compatibleRemuxDirectPlayProfiles,
            "TranscodingProfiles": compatibleRemuxStaticTranscodingProfiles,
        ]
    }
}
