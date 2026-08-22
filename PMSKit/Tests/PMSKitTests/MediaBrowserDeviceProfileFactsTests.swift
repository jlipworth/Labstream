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
                    let actual = try canonical(jellyfin)
                    let expected = try canonical(legacyJellyfinStreaming(
                        bitrate: bitrate,
                        advertiseDV: advertiseDV,
                        subtitlesInManifest: subtitlesInManifest))
                    #expect(actual == expected)
                }

                let emby = EmbyPlayback.streamingDeviceProfile(
                    maxStreamingBitrate: bitrate,
                    advertiseDolbyVision: advertiseDV)
                let actual = try canonical(emby)
                let expected = try canonical(legacyEmbyStreaming(
                    bitrate: bitrate, advertiseDV: advertiseDV))
                #expect(actual == expected)
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
            let expectedCanonical = try canonical(expected)
            let jellyfinCanonical = try canonical(
                JellyfinPlayback.compatibleRemuxDownloadDeviceProfile(
                    maxStaticBitrate: bitrate))
            let embyCanonical = try canonical(
                EmbyPlayback.compatibleRemuxDownloadDeviceProfile(
                    maxStaticBitrate: bitrate))
            #expect(jellyfinCanonical == expectedCanonical)
            #expect(embyCanonical == expectedCanonical)
        }
    }

    @Test func embyStrictStaticDownloadProfileRemainsSeparate() throws {
        let strict = EmbyPlayback.downloadDeviceProfile(maxStaticBitrate: 200_000_000)
        let remux = EmbyPlayback.compatibleRemuxDownloadDeviceProfile(
            maxStaticBitrate: 200_000_000)
        let strictDirectPlay = try firstProfile(strict, key: "DirectPlayProfiles")
        let strictTranscode = try firstProfile(strict, key: "TranscodingProfiles")
        let strictCanonical = try canonical(strict)
        let remuxCanonical = try canonical(remux)
        #expect(strict["Name"] as? String == "Labstream-Download")
        #expect(remux["Name"] as? String == "Labstream-Compatible-Download")
        #expect(strictDirectPlay["VideoCodec"] as? String == "h264")
        #expect(strictTranscode["VideoCodec"] as? String == "h264")
        #expect(strictCanonical != remuxCanonical)
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
