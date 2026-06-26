import Foundation
import Testing
@testable import PMSKit

/// Offline-download lane for the Emby backend. These lock the wire shape of the download
/// PlaybackInfo negotiation (the crux of the detection rule) and the request builders against
/// anonymized fixtures captured from a real Emby 4.9 server (fake ids/titles only — no secrets).
@Suite("Emby downloads")
struct EmbyDownloadTests {
    private let server = URL(string: "https://emby.example.test/emby")!
    private let identity = EmbyClientIdentity(client: "VisionPlay", device: "Apple Vision Pro", deviceId: "device-123", version: "0.1.0")

    // MARK: - Static original download request

    @Test func downloadOriginalRequestIsStaticGetWithHeaderAuth() throws {
        let request = try EmbyLibrary.downloadOriginalRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            userId: "user-9",
            itemId: "item-1",
            mediaSourceId: "mediasource_1",
            container: "mp4")

        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect((request.httpMethod ?? "GET") == "GET")
        #expect(comps.path == "/emby/Videos/item-1/stream.mp4")
        #expect(q["static"] == "true")
        #expect(q["MediaSourceId"] == "mediasource_1")
        #expect(q["DeviceId"] == "device-123")
        // Auth rides in the header — token NEVER baked into the stored URL query.
        #expect(q["api_key"] == nil)
        #expect(url.absoluteString.contains("token-abc") == false)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-abc")
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
    }

    @Test func downloadOriginalRequestTakesFirstContainerTokenAndDefaultsToMp4() throws {
        // Emby Container is a comma-list; the first token is the real container.
        let multi = try EmbyLibrary.downloadOriginalRequest(
            server: server, token: "t", identity: identity, userId: "u",
            itemId: "i", mediaSourceId: nil, container: "mov,mp4,m4v")
        #expect(multi.url?.path == "/emby/Videos/i/stream.mov")

        let none = try EmbyLibrary.downloadOriginalRequest(
            server: server, token: "t", identity: identity, userId: "u",
            itemId: "i", mediaSourceId: nil, container: nil)
        #expect(none.url?.path == "/emby/Videos/i/stream.mp4")
    }

    // MARK: - Transcoded download request (from server-minted TranscodingUrl)

    @Test func transcodedDownloadRequestBuildsExplicitStaticMp4WithForcedCodecs() throws {
        let request = try EmbyLibrary.transcodedDownloadRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            userId: "user-9",
            itemId: "item-1",
            mediaSourceId: "mediasource_1",
            playSessionId: "sess-1",
            videoBitrate: 8_000_000,
            audioBitrate: 192_000)

        let url = try #require(request.url)
        // EXPLICIT static stream.mp4 (NOT the codecless server-minted /stream remux that 500s).
        // Server base path (/emby) is preserved.
        #expect(url.path == "/emby/videos/item-1/stream.mp4")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        // Forced re-encode params — without explicit codecs Emby stream-copies and ffmpeg fails.
        #expect(q["Static"] == "false")
        #expect(q["Container"] == "mp4")
        #expect(q["VideoCodec"] == "h264")
        #expect(q["AudioCodec"] == "aac")
        #expect(q["VideoBitrate"] == "8000000")
        #expect(q["AudioBitrate"] == "192000")
        // The minted PlaySessionId is what makes this hand-built URL valid (else Emby 400s).
        #expect(q["PlaySessionId"] == "sess-1")
        #expect(q["MediaSourceId"] == "mediasource_1")
        #expect(q["api_key"] == "token-abc")
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
    }

    // MARK: - Download device profile

    @Test func downloadDeviceProfileAdvertisesStaticMp4NotHls() throws {
        let profile = EmbyPlayback.visionOSDownloadDeviceProfile(maxStaticBitrate: 200_000_000)
        #expect(profile["Name"] as? String == "VisionPlay-Download")
        #expect(profile["MaxStaticBitrate"] as? Int == 200_000_000)
        // `try #require` (not `try?`): a missing/renamed TranscodingProfiles is a real structural
        // regression and must fail here, not silently nil out and surface as a confusing
        // downstream assertion.
        let transcoding = try #require(profile["TranscodingProfiles"] as? [[String: Any]])
        let first = try #require(transcoding.first)
        #expect(first["Container"] as? String == "mp4")
        // CRUX: http/Static, NOT hls — otherwise the TranscodingUrl is a non-downloadable playlist.
        #expect(first["Protocol"] as? String == "http")
        #expect(first["Context"] as? String == "Static")
        // Direct-play profile only advertises locally playable containers.
        let direct = try #require(profile["DirectPlayProfiles"] as? [[String: Any]])
        #expect(direct.contains { ($0["Container"] as? String) == "mp4,m4v,mov" } == true)
    }

    @Test func downloadPlaybackInfoRequestPostsDownloadProfile() throws {
        let request = try EmbyPlayback.downloadPlaybackInfoRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            userId: "user-9",
            itemId: "item-1",
            mediaSourceId: "mediasource_1",
            maxStaticBitrate: 200_000_000)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/emby/Items/item-1/PlaybackInfo")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["MaxStreamingBitrate"] as? Int == 200_000_000)
        #expect(object["MediaSourceId"] as? String == "mediasource_1")
        let profile = try #require(object["DeviceProfile"] as? [String: Any])
        #expect(profile["Name"] as? String == "VisionPlay-Download")
        let transcoding = try #require(profile["TranscodingProfiles"] as? [[String: Any]])
        #expect(transcoding.first?["Protocol"] as? String == "http")
    }

    @Test func compatibleRemuxPlaybackInfoRequestAdvertisesHEVCStaticMp4() throws {
        let request = try EmbyPlayback.compatibleRemuxDownloadPlaybackInfoRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            userId: "user-9",
            itemId: "item-1",
            mediaSourceId: "mediasource_1",
            maxStaticBitrate: 200_000_000)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/emby/Items/item-1/PlaybackInfo")
        let comps = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["UserId"] == "user-9")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-abc")
        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasPrefix("Emby "))
        #expect(auth.contains("UserId=\"user-9\""))
        #expect(auth.contains("Token=\"token-abc\""))
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["UserId"] as? String == "user-9")
        #expect(object["MediaSourceId"] as? String == "mediasource_1")
        #expect(object["MaxStaticBitrate"] as? Int == 200_000_000)
        #expect(object["MaxStreamingBitrate"] as? Int == 200_000_000)
        #expect(object["AllowVideoStreamCopy"] as? Bool == true)
        #expect(object["AutoOpenLiveStream"] as? Bool == false)
        let profile = try #require(object["DeviceProfile"] as? [String: Any])
        #expect(profile["Name"] as? String == "VisionPlay-Compatible-Download")
        let transcoding = try #require(profile["TranscodingProfiles"] as? [[String: Any]])
        let first = try #require(transcoding.first)
        #expect(first["Container"] as? String == "mp4")
        #expect(first["Protocol"] as? String == "http")
        #expect(first["Context"] as? String == "Static")
        #expect(first["VideoCodec"] as? String == "h264,hevc")
    }

    // MARK: - Negotiated verdict decoding (the crux)

    /// Anonymized capture of the MKV worst case from a real Emby 4.9 download PlaybackInfo:
    /// negotiated DirectPlay=false, Size populated, TranscodeReasons=ContainerNotSupported,
    /// single-file (http) TranscodingUrl.
    private static let mkvDownloadFixture = Data(#"""
    {
      "PlaySessionId": "sess-mkv-1",
      "MediaSources": [{
        "Id": "mediasource_mkv",
        "Container": "mkv",
        "Size": 23073926242,
        "Bitrate": 22930134,
        "SupportsDirectPlay": false,
        "SupportsDirectStream": false,
        "SupportsTranscoding": true,
        "TranscodingUrl": "/videos/item-mkv/stream?DeviceId=device-123&MediaSourceId=mediasource_mkv&PlaySessionId=sess-mkv-1&api_key=REDACTED&AudioStreamIndex=1&TranscodeReasons=ContainerNotSupported",
        "TranscodeReasons": ["ContainerNotSupported"],
        "MediaStreams": [
          {"Index": 0, "Type": "Video", "Codec": "hevc"},
          {"Index": 1, "Type": "Audio", "Codec": "dts"}
        ]
      }]
    }
    """#.utf8)

    /// Anonymized capture of an already-compatible mp4: negotiated DirectPlay=true, no transcode.
    private static let mp4DownloadFixture = Data(#"""
    {
      "PlaySessionId": "sess-mp4-1",
      "MediaSources": [{
        "Id": "mediasource_mp4",
        "Container": "mp4",
        "Size": 4500000000,
        "Bitrate": 8000000,
        "SupportsDirectPlay": true,
        "SupportsDirectStream": true,
        "SupportsTranscoding": true,
        "DirectStreamUrl": "/Videos/item-mp4/stream.mp4?Static=true&api_key=REDACTED",
        "TranscodeReasons": [],
        "MediaStreams": [
          {"Index": 0, "Type": "Video", "Codec": "h264"},
          {"Index": 1, "Type": "Audio", "Codec": "aac"}
        ]
      }]
    }
    """#.utf8)

    @Test func mkvCaseNegotiatesTranscodeWithContainerNotSupported() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Self.mkvDownloadFixture)
        let decision = try EmbyPlayback.downloadDecision(response: response)

        #expect(decision.playSessionId == "sess-mkv-1")
        #expect(decision.mediaSourceId == "mediasource_mkv")
        // The authoritative negotiated verdict — NOT the optimistic naked-item value.
        #expect(decision.supportsDirectPlay == false)
        #expect(decision.transcodeReasons.contains("ContainerNotSupported"))
        // Size comes from MediaSource.Size (Part.size is nil on Emby).
        #expect(decision.size == 23073926242)
        #expect(decision.container == "mkv")
        #expect(decision.transcodingURL != nil)
    }

    @Test func mkvCaseIsNotOriginalEligible() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Self.mkvDownloadFixture)
        let decision = try EmbyPlayback.downloadDecision(response: response)
        // Backend-agnostic container gate: mkv is never a locally playable original.
        let part = Part(id: 1, key: "emby://x", container: decision.container)
        let containerGate = OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
        #expect(containerGate == false)
        // Original eligible ⇔ negotiated DirectPlay && container gate. Here both fail.
        #expect((decision.supportsDirectPlay && containerGate) == false)
    }

    @Test func compatibleMp4CaseIsOriginalEligible() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Self.mp4DownloadFixture)
        let decision = try EmbyPlayback.downloadDecision(response: response)

        #expect(decision.supportsDirectPlay == true)
        #expect(decision.transcodeReasons.isEmpty)
        #expect(decision.size == 4500000000)
        let part = Part(id: 1, key: "emby://x", container: decision.container)
        let containerGate = OfflineDownloadDecision.isLocallyPlayableOriginal(part: part)
        #expect(containerGate == true)
        // Original eligible ⇔ negotiated DirectPlay && container gate.
        #expect((decision.supportsDirectPlay && containerGate) == true)
    }

    @Test func downloadDecisionThrowsWhenPlaySessionMissing() throws {
        let data = Data(#"{ "MediaSources": [{ "Id": "x", "SupportsDirectPlay": true }] }"#.utf8)
        let response = try EmbyPlaybackInfoResponse.decode(from: data)
        #expect(throws: EmbyPlaybackError.missingPlaySessionId) {
            _ = try EmbyPlayback.downloadDecision(response: response)
        }
    }
}
