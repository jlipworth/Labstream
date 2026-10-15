import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser playback source pinning")
struct MediaBrowserPlaybackSourcePinningTests {
    private let server = URL(string: "https://media.example.test")!

    @Test("Jellyfin resolves only the requested non-first source")
    func jellyfinExactSource() throws {
        let response = try JellyfinPlaybackInfoResponse.decode(from: responseData)
        let result = try JellyfinPlayback.resolveMediaBrowserStream(
            response: response, server: server,
            identity: JellyfinClientIdentity(client: "Labstream", device: "Test",
                                              deviceId: "device", version: "1"),
            token: "token", itemId: "item", preferredMediaSourceId: "selected",
            audioStreamIndex: 12, subtitleStreamIndex: 19)
        #expect(result.mediaSourceId == "selected")
        #expect(result.sourceMetadata.audioCodec == "aac")
    }

    @Test("Emby resolves only the requested non-first source")
    func embyExactSource() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: responseData)
        let result = try EmbyPlayback.resolveMediaBrowserStream(
            response: response, server: server,
            identity: EmbyClientIdentity(client: "Labstream", device: "Test",
                                          deviceId: "device", version: "1"),
            token: "token", userId: "user", itemId: "item",
            preferredMediaSourceId: "selected", audioStreamIndex: 12,
            subtitleStreamIndex: 19)
        #expect(result.mediaSourceId == "selected")
        #expect(result.sourceMetadata.audioCodec == "aac")
    }

    @Test("An explicit source never falls back when PlaybackInfo omits it")
    func missingExactSourceFails() throws {
        let jellyfin = try JellyfinPlaybackInfoResponse.decode(from: responseData)
        #expect(throws: JellyfinPlaybackError.preferredMediaSourceUnavailable("missing")) {
            _ = try JellyfinPlayback.resolveMediaBrowserStream(
                response: jellyfin, server: server,
                identity: JellyfinClientIdentity(client: "Labstream", device: "Test",
                                                  deviceId: "device", version: "1"),
                token: "token", itemId: "item", preferredMediaSourceId: "missing")
        }

        let emby = try EmbyPlaybackInfoResponse.decode(from: responseData)
        #expect(throws: EmbyPlaybackError.preferredMediaSourceUnavailable("missing")) {
            _ = try EmbyPlayback.resolveMediaBrowserStream(
                response: emby, server: server,
                identity: EmbyClientIdentity(client: "Labstream", device: "Test",
                                              deviceId: "device", version: "1"),
                token: "token", userId: "user", itemId: "item",
                preferredMediaSourceId: "missing")
        }
    }

    /// The first source is intentionally the server-favored transcode. Exact selection must still
    /// choose the second source, whose stream indices and codecs belong to a different version.
    private var responseData: Data {
        Data(#"""
        {
          "PlaySessionId": "play-1",
          "MediaSources": [
            {
              "Id": "alternate",
              "Container": "mkv",
              "AudioCodec": "ac3",
              "SupportsTranscoding": true,
              "TranscodingUrl": "/Videos/item/master.m3u8?MediaSourceId=alternate",
              "MediaStreams": [
                { "Index": 2, "Type": "Audio", "Codec": "ac3" },
                { "Index": 3, "Type": "Subtitle", "Codec": "vtt" }
              ]
            },
            {
              "Id": "selected",
              "Container": "mp4",
              "AudioCodec": "aac",
              "SupportsDirectPlay": true,
              "MediaStreams": [
                { "Index": 12, "Type": "Audio", "Codec": "aac" },
                { "Index": 19, "Type": "Subtitle", "Codec": "srt" }
              ]
            }
          ]
        }
        """#.utf8)
    }
}
