import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser device profile facts")
struct MediaBrowserDeviceProfileFactsTests {
    @Test func streamingProfilesPreserveBackendGoldensAcrossBitratesDVAndSubtitles() throws {
        for bitrate in [1, 8_000_000, 200_000_000] {
            for advertiseDV in [false, true] {
                for subtitlesInManifest in [false, true] {
                    let jellyfin = JellyfinPlayback.streamingDeviceProfile(
                        maxStreamingBitrate: bitrate,
                        advertiseDolbyVision: advertiseDV,
                        subtitlesInManifest: subtitlesInManifest)
                    try #expect(canonical(jellyfin) == canonical(legacyJellyfinStreaming(
                        bitrate: bitrate,
                        advertiseDV: advertiseDV,
                        subtitlesInManifest: subtitlesInManifest)))
                }

                let emby = EmbyPlayback.streamingDeviceProfile(
                    maxStreamingBitrate: bitrate,
                    advertiseDolbyVision: advertiseDV)
                try #expect(canonical(emby) == canonical(legacyEmbyStreaming(
                    bitrate: bitrate, advertiseDV: advertiseDV)))
            }
        }
    }

    @Test func subtitlePoliciesRemainExplicitlyDifferent() throws {
        let jellyfinOn = JellyfinPlayback.streamingDeviceProfile(
            maxStreamingBitrate: 8_000_000, subtitlesInManifest: true)
        let jellyfinOff = JellyfinPlayback.streamingDeviceProfile(
            maxStreamingBitrate: 8_000_000, subtitlesInManifest: false)
        let emby = EmbyPlayback.streamingDeviceProfile(maxStreamingBitrate: 8_000_000)

        let jfOnTranscode = try firstProfile(jellyfinOn, key: "TranscodingProfiles")
        let jfOffTranscode = try firstProfile(jellyfinOff, key: "TranscodingProfiles")
        #expect(jfOnTranscode["EnableSubtitlesInManifest"] as? Bool == true)
        #expect(jfOffTranscode["EnableSubtitlesInManifest"] as? Bool == false)
        #expect(jellyfinOn["SubtitleProfiles"] == nil)

        let embyTranscode = try firstProfile(emby, key: "TranscodingProfiles")
        #expect(embyTranscode["EnableSubtitlesInManifest"] == nil)
        let subtitleProfiles = try #require(emby["SubtitleProfiles"] as? [[String: Any]])
        #expect(subtitleProfiles.map { $0["Format"] as? String } == subtitleFormats)
        #expect(subtitleProfiles.allSatisfy { $0["Method"] as? String == "Encode" })
    }

    @Test func compatibleRemuxProfilesShareExactStaticFactsAtMultipleBitrates() throws {
        for bitrate in [1, 40_000_000, 200_000_000] {
            let expected = legacyCompatibleRemux(bitrate: bitrate)
            try #expect(canonical(JellyfinPlayback.compatibleRemuxDownloadDeviceProfile(
                maxStaticBitrate: bitrate)) == canonical(expected))
            try #expect(canonical(EmbyPlayback.compatibleRemuxDownloadDeviceProfile(
                maxStaticBitrate: bitrate)) == canonical(expected))
        }
    }

    @Test func embyStrictStaticDownloadProfileRemainsSeparate() throws {
        let strict = EmbyPlayback.downloadDeviceProfile(maxStaticBitrate: 200_000_000)
        let remux = EmbyPlayback.compatibleRemuxDownloadDeviceProfile(
            maxStaticBitrate: 200_000_000)
        #expect(strict["Name"] as? String == "Labstream-Download")
        #expect(remux["Name"] as? String == "Labstream-Compatible-Download")
        #expect(try firstProfile(strict, key: "DirectPlayProfiles")["VideoCodec"] as? String == "h264")
        #expect(try firstProfile(strict, key: "TranscodingProfiles")["VideoCodec"] as? String == "h264")
        #expect(try canonical(strict) != canonical(remux))
    }

    private var directPlay: [[String: Any]] { [
        ["Type": "Video", "Container": "mp4,m4v,mov", "VideoCodec": "h264,hevc",
         "AudioCodec": "aac,ac3,eac3"],
        ["Type": "Video", "Container": "mpegts", "VideoCodec": "h264",
         "AudioCodec": "aac,ac3,eac3"],
    ] }

    private var subtitleFormats: [String] {
        ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "sub", "idx",
         "pgssub", "dvdsub", "dvbsub"]
    }

    private func legacyJellyfinStreaming(bitrate: Int,
                                         advertiseDV: Bool,
                                         subtitlesInManifest: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "Name": "Labstream",
            "MaxStreamingBitrate": bitrate,
            "DirectPlayProfiles": directPlay,
            "TranscodingProfiles": [streamingTranscode(
                enableSubtitlesInManifest: subtitlesInManifest)],
        ]
        if advertiseDV { result["CodecProfiles"] = dolbyVisionProfiles }
        return result
    }

    private func legacyEmbyStreaming(bitrate: Int, advertiseDV: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "Name": "Labstream",
            "MaxStreamingBitrate": bitrate,
            "DirectPlayProfiles": directPlay,
            "TranscodingProfiles": [streamingTranscode(enableSubtitlesInManifest: nil)],
            "SubtitleProfiles": subtitleFormats.map { ["Format": $0, "Method": "Encode"] },
        ]
        if advertiseDV { result["CodecProfiles"] = dolbyVisionProfiles }
        return result
    }

    private func streamingTranscode(enableSubtitlesInManifest: Bool?) -> [String: Any] {
        var result: [String: Any] = [
            "Type": "Video", "Container": "ts", "Protocol": "hls",
            "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3",
            "Context": "Streaming", "MinSegments": 2, "BreakOnNonKeyFrames": false,
        ]
        if let enableSubtitlesInManifest {
            result["EnableSubtitlesInManifest"] = enableSubtitlesInManifest
        }
        return result
    }

    private var dolbyVisionProfiles: [[String: Any]] { [
        [
            "Type": "Video", "Codec": "hevc",
            "Conditions": [[
                "Condition": "EqualsAny", "Property": "VideoRangeType",
                "Value": "SDR|HDR10|HLG|HDR10Plus|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR|DOVIWithHDR10Plus",
                "IsRequired": false,
            ]],
        ],
    ] }

    private func legacyCompatibleRemux(bitrate: Int) -> [String: Any] { [
        "Name": "Labstream-Compatible-Download",
        "MaxStaticBitrate": bitrate,
        "MaxStreamingBitrate": bitrate,
        "DirectPlayProfiles": [[
            "Type": "Video", "Container": "mp4,m4v,mov", "VideoCodec": "h264,hevc",
            "AudioCodec": "aac,ac3,eac3",
        ]],
        "TranscodingProfiles": [[
            "Type": "Video", "Container": "mp4", "Protocol": "http",
            "VideoCodec": "h264,hevc", "AudioCodec": "aac", "Context": "Static",
            "BreakOnNonKeyFrames": false,
        ]],
    ] }

    private func firstProfile(_ object: [String: Any], key: String) throws -> [String: Any] {
        try #require((object[key] as? [[String: Any]])?.first)
    }

    private func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
