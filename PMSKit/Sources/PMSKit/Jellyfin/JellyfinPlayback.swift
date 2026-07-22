import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct JellyfinPlaybackInfoResponse: Decodable, Sendable, Equatable {
    public let playSessionId: String?
    public let mediaSources: [JellyfinMediaSourceInfo]

    enum CodingKeys: String, CodingKey {
        case playSessionId = "PlaySessionId"
        case mediaSources = "MediaSources"
    }

    public static func decode(from data: Data) throws -> JellyfinPlaybackInfoResponse {
        try JSONDecoder().decode(JellyfinPlaybackInfoResponse.self, from: data)
    }
}

public struct JellyfinMediaSourceInfo: Decodable, Sendable, Equatable {
    public let id: String?
    public let name: String?
    public let container: String?
    public let eTag: String?
    public let supportsDirectPlay: Bool
    public let supportsDirectStream: Bool
    public let supportsTranscoding: Bool
    public let transcodingURL: String?
    public let transcodingSubProtocol: String?
    public let transcodingContainer: String?
    public let requiredHTTPHeaders: [String: String]?
    public let size: Int?
    public let bitrate: Int?
    public let width: Int?
    public let height: Int?
    public let videoCodec: String?
    public let audioCodec: String?
    public let mediaStreams: [JellyfinItemMediaStreamDto]
    public let transcodeReasons: [String]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case eTag = "ETag"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingURL = "TranscodingUrl"
        case transcodingSubProtocol = "TranscodingSubProtocol"
        case transcodingContainer = "TranscodingContainer"
        case requiredHTTPHeaders = "RequiredHttpHeaders"
        case size = "Size"
        case bitrate = "Bitrate"
        case width = "Width"
        case height = "Height"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case mediaStreams = "MediaStreams"
        case transcodeReasons = "TranscodeReasons"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        container = try c.decodeIfPresent(String.self, forKey: .container)
        eTag = try c.decodeIfPresent(String.self, forKey: .eTag)
        supportsDirectPlay = try c.decodeIfPresent(Bool.self, forKey: .supportsDirectPlay) ?? false
        supportsDirectStream = try c.decodeIfPresent(Bool.self, forKey: .supportsDirectStream) ?? false
        supportsTranscoding = try c.decodeIfPresent(Bool.self, forKey: .supportsTranscoding) ?? false
        transcodingURL = try c.decodeIfPresent(String.self, forKey: .transcodingURL)
        transcodingSubProtocol = try c.decodeIfPresent(String.self, forKey: .transcodingSubProtocol)
        transcodingContainer = try c.decodeIfPresent(String.self, forKey: .transcodingContainer)
        requiredHTTPHeaders = try c.decodeIfPresent([String: String].self, forKey: .requiredHTTPHeaders)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec)
        mediaStreams = try c.decodeIfPresent([JellyfinItemMediaStreamDto].self, forKey: .mediaStreams) ?? []
        transcodeReasons = try c.decodeIfPresent([String].self, forKey: .transcodeReasons) ?? []
    }

    func playbackSourceMetadata(audioStreamIndex: Int? = nil) -> MediaBrowserPlaybackSourceMetadata {
        let video = mediaStreams.first { $0.type == "Video" }
        let audio = audioStreamIndex.flatMap { index in
            mediaStreams.first { $0.type == "Audio" && $0.index == index }
        } ?? mediaStreams.first { $0.type == "Audio" }
        return MediaBrowserPlaybackSourceMetadata(
            container: container?.split(separator: ",").first.map(String.init),
            width: width ?? video?.width,
            height: height ?? video?.height,
            bitrate: bitrate.map { $0 / 1_000 },
            videoCodec: videoCodec ?? video?.codec,
            audioCodec: audioStreamIndex == nil ? (audioCodec ?? audio?.codec) : (audio?.codec ?? audioCodec),
            hdr: video?.hdrMetadata,
            audioProfile: audio?.profile)
    }

    var playbackSourceMetadata: MediaBrowserPlaybackSourceMetadata {
        playbackSourceMetadata()
    }

    /// Shared steering logic lives on `[MediaBrowserItemMediaStreamDto]`
    /// (`preferredCompatibleAudioStreamIndexForCappedTranscode`) — one implementation for
    /// Jellyfin and Emby.
}

public struct JellyfinDownloadPlaybackDecision: Sendable, Equatable {
    public let playSessionId: String
    public let mediaSourceId: String
    public let supportsDirectPlay: Bool
    /// #83: negotiated remux signal — true iff the server says this source can DirectStream
    /// (container remux with stream-copy where possible) under the download/remux device profile.
    public let supportsDirectStream: Bool
    public let transcodingURL: String?
    public let size: Int?
    public let container: String?
    public let bitrate: Int?
    /// Source video/audio codec tokens (first video/audio stream), for compatible-remux eligibility.
    public let videoCodec: String?
    public let audioCodec: String?
    public let transcodeReasons: [String]
}

public enum JellyfinPlaybackError: Error, Sendable, Equatable {
    case noMediaSources
    case preferredMediaSourceUnavailable(String)
    case missingPlaySessionId
    case missingMediaSourceId
    case unsupportedMediaSource
    case invalidURL
}

public enum JellyfinPlayback {
    public static func playbackInfoRequest(server: URL,
                                           token: String,
                                           identity: JellyfinClientIdentity,
                                           itemId: String,
                                           userId: String,
                                           mediaSourceId: String? = nil,
                                           startTimeTicks: Int? = nil,
                                           maxStreamingBitrate: Int,
                                           audioStreamIndex: Int? = nil,
                                           subtitleStreamIndex: Int? = nil,
                                           forcePlaybackTranscode: Bool = false,
                                           advertiseDolbyVision: Bool = false) throws -> URLRequest {
        let url = try jellyfinURL(server: server, path: "/Items/\(itemId)/PlaybackInfo")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(JellyfinAuth.authorizationHeader(identity: identity, token: token),
                     forHTTPHeaderField: "Authorization")

        // forcePlaybackTranscode (GH #196 DV P5 guard): close every lane that would copy
        // the video bitstream so the server must mint a tone-mapped video transcode.
        // Audio copy stays permitted — only the video samples are the hazard.
        var body: [String: Any] = [
            "UserId": userId,
            "MaxStreamingBitrate": maxStreamingBitrate,
            "EnableDirectPlay": !forcePlaybackTranscode,
            "EnableDirectStream": !forcePlaybackTranscode,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": !forcePlaybackTranscode,
            "AllowAudioStreamCopy": true,
            "AutoOpenLiveStream": true,
            "DeviceProfile": streamingDeviceProfile(maxStreamingBitrate: maxStreamingBitrate,
                                                   advertiseDolbyVision: advertiseDolbyVision,
                                                   subtitlesInManifest: subtitleStreamIndex != -1),
        ]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        if let startTimeTicks { body["StartTimeTicks"] = startTimeTicks }
        if let audioStreamIndex { body["AudioStreamIndex"] = audioStreamIndex }
        if let subtitleStreamIndex { body["SubtitleStreamIndex"] = subtitleStreamIndex }

        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// `POST /Items/{Id}/PlaybackInfo` for the #83 "Original quality (compatible)" offline lane.
    ///
    /// This is intentionally separate from `playbackInfoRequest` (which asks for HLS playback) and
    /// from Jellyfin's hand-built bitrate transcode URL. The profile advertises a **Static/http MP4**
    /// target that permits h264/hevc video stream-copy, so `SupportsDirectStream` answers the exact
    /// question the download sheet/retry path needs: can this item be remuxed while preserving the
    /// source video stream?
    public static func downloadPlaybackInfoRequest(server: URL,
                                                   token: String,
                                                   identity: JellyfinClientIdentity,
                                                   itemId: String,
                                                   userId: String,
                                                   mediaSourceId: String? = nil,
                                                   maxStaticBitrate: Int,
                                                   audioStreamIndex: Int? = nil) throws -> URLRequest {
        let url = try jellyfinURL(server: server, path: "/Items/\(itemId)/PlaybackInfo")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(JellyfinAuth.authorizationHeader(identity: identity, token: token),
                     forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "UserId": userId,
            "MaxStaticBitrate": maxStaticBitrate,
            "MaxStreamingBitrate": maxStaticBitrate,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": true,
            "AllowAudioStreamCopy": true,
            "AutoOpenLiveStream": true,
            "DeviceProfile": compatibleRemuxDownloadDeviceProfile(maxStaticBitrate: maxStaticBitrate),
        ]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        if let audioStreamIndex { body["AudioStreamIndex"] = audioStreamIndex }

        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// Distill a download/remux PlaybackInfo response into the typed verdict used by the offline
    /// compatible-remux lane. Throws when the response cannot identify a playable media source.
    public static func downloadDecision(response: JellyfinPlaybackInfoResponse,
                                        preferredMediaSourceId: String? = nil) throws -> JellyfinDownloadPlaybackDecision {
        guard let playSessionId = response.playSessionId, !playSessionId.isEmpty else {
            throw JellyfinPlaybackError.missingPlaySessionId
        }
        guard let source = chooseDownloadSource(response.mediaSources, preferredMediaSourceId: preferredMediaSourceId) else {
            throw JellyfinPlaybackError.noMediaSources
        }
        guard let mediaSourceId = source.id, !mediaSourceId.isEmpty else {
            throw JellyfinPlaybackError.missingMediaSourceId
        }
        let videoStream = source.mediaStreams.first { $0.type == "Video" }
        let audioStream = source.mediaStreams.first { $0.type == "Audio" }
        return JellyfinDownloadPlaybackDecision(
            playSessionId: playSessionId,
            mediaSourceId: mediaSourceId,
            supportsDirectPlay: source.supportsDirectPlay,
            supportsDirectStream: source.supportsDirectStream,
            transcodingURL: source.transcodingURL.flatMap { $0.isEmpty ? nil : $0 },
            size: source.size,
            container: source.container?.split(separator: ",").first.map(String.init),
            bitrate: source.bitrate,
            videoCodec: source.videoCodec ?? videoStream?.codec,
            audioCodec: source.audioCodec ?? audioStream?.codec,
            transcodeReasons: source.transcodeReasons)
    }

    public static func resolveMediaBrowserStream(response: JellyfinPlaybackInfoResponse,
                                     server: URL,
                                     identity: JellyfinClientIdentity,
                                     token: String,
                                     itemId: String,
                                     preferredMediaSourceId: String? = nil,
                                     startTimeTicks: Int? = nil,
                                     maxVideoBitrate: Int? = nil,
                                     maxWidth: Int? = nil,
                                     maxHeight: Int? = nil,
                                     audioBitrate: Int? = nil,
                                     audioStreamIndex: Int? = nil,
                                     subtitleStreamIndex: Int? = nil) throws -> MediaBrowserPlaybackOpenResult {
        guard let playSessionId = response.playSessionId, !playSessionId.isEmpty else {
            throw JellyfinPlaybackError.missingPlaySessionId
        }
        if let preferredMediaSourceId,
           !preferredMediaSourceId.isEmpty,
           !response.mediaSources.contains(where: { $0.id == preferredMediaSourceId }) {
            throw JellyfinPlaybackError.preferredMediaSourceUnavailable(preferredMediaSourceId)
        }
        guard let source = chooseSource(response.mediaSources, preferredMediaSourceId: preferredMediaSourceId) else {
            throw JellyfinPlaybackError.noMediaSources
        }
        guard let mediaSourceId = source.id, !mediaSourceId.isEmpty else {
            throw JellyfinPlaybackError.missingMediaSourceId
        }

        if let transcodingURL = source.transcodingURL, !transcodingURL.isEmpty {
            let resolvedAudioStreamIndex = audioStreamIndex ??
                (audioBitrate == nil ? nil : source.mediaStreams.preferredCompatibleAudioStreamIndexForCappedTranscode())
            // Keep Jellyfin's generated HLS session URL intact. AVFoundation does not reliably
            // propagate custom HTTP headers from the master playlist request to child playlists
            // and segments; when the ApiKey is stripped, the master can load via headers but the
            // child playlist is generated without token-bearing segment URLs, which fails in
            // CoreMedia. Static/direct streams still use header auth below.
            let rawURL = try jellyfinURL(server: server, pathOrURLString: transcodingURL)
            let url = try appendTranscodeOverrides(to: rawURL,
                                                   startTimeTicks: startTimeTicks,
                                                   maxVideoBitrate: maxVideoBitrate,
                                                   maxWidth: maxWidth,
                                                   maxHeight: maxHeight,
                                                   audioBitrate: audioBitrate,
                                                   audioStreamIndex: resolvedAudioStreamIndex,
                                                   subtitleStreamIndex: subtitleStreamIndex)
            return MediaBrowserPlaybackOpenResult(
                url: url,
                playSessionId: playSessionId,
                mediaSourceId: mediaSourceId,
                // The selected URL is the source of truth here. Some Jellyfin responses report
                // `SupportsDirectStream=true` for a media source while also handing back an HLS
                // `TranscodingUrl`; that stream is still server-transcoded and must use the
                // remote-transcode playback/buffering path.
                playMethod: .transcode,
                requiredHTTPHeaders: streamHeaders(for: source, token: token, identity: identity),
                sourceMetadata: source.playbackSourceMetadata(audioStreamIndex: resolvedAudioStreamIndex),
                usesServerEncoding: true,
                transcodeReasons: source.transcodeReasons)
        }

        guard source.supportsDirectPlay || source.supportsDirectStream else {
            throw JellyfinPlaybackError.unsupportedMediaSource
        }
        let container = (source.container?.split(separator: ",").first).map(String.init) ?? "mp4"
        let url = try jellyfinURL(server: server, path: "/Videos/\(itemId)/stream.\(container)")
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw JellyfinPlaybackError.invalidURL
        }
        comps.queryItems = [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "PlaySessionId", value: playSessionId),
        ]
        if let tag = source.eTag, !tag.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "Tag", value: tag))
        }
        guard let built = comps.url else { throw JellyfinPlaybackError.invalidURL }
        return MediaBrowserPlaybackOpenResult(
            url: built,
            playSessionId: playSessionId,
            mediaSourceId: mediaSourceId,
            playMethod: source.supportsDirectPlay ? .directPlay : .directStream,
            requiredHTTPHeaders: streamHeaders(for: source, token: token, identity: identity),
            sourceMetadata: source.playbackSourceMetadata(audioStreamIndex: audioStreamIndex),
            usesServerEncoding: false,
            transcodeReasons: source.transcodeReasons)
    }

    // MARK: - Progress reporting

    /// `POST /Sessions/Playing`
    public static func playingRequest(server: URL,
                                      token: String,
                                      identity: JellyfinClientIdentity,
                                      userId: String,
                                      itemId: String,
                                      mediaSourceId: String,
                                      playSessionId: String,
                                      playMethod: MediaBrowserPlayMethod,
                                      positionTicks: Int = 0) throws -> URLRequest {
        try progressBody(server: server, token: token, identity: identity, userId: userId,
                         event: .playing,
                         itemId: itemId, mediaSourceId: mediaSourceId,
                         playSessionId: playSessionId, playMethod: playMethod,
                         positionTicks: positionTicks)
    }

    /// `POST /Sessions/Playing/Progress`
    public static func progressRequest(server: URL,
                                       token: String,
                                       identity: JellyfinClientIdentity,
                                       userId: String,
                                       itemId: String,
                                       mediaSourceId: String,
                                       playSessionId: String,
                                       playMethod: MediaBrowserPlayMethod,
                                       positionTicks: Int,
                                       isPaused: Bool) throws -> URLRequest {
        try progressBody(server: server, token: token, identity: identity, userId: userId,
                         event: isPaused ? .paused : .progress,
                         itemId: itemId, mediaSourceId: mediaSourceId,
                         playSessionId: playSessionId, playMethod: playMethod,
                         positionTicks: positionTicks)
    }

    /// `POST /Sessions/Playing/Stopped`
    public static func stoppedRequest(server: URL,
                                      token: String,
                                      identity: JellyfinClientIdentity,
                                      userId: String,
                                      itemId: String,
                                      mediaSourceId: String,
                                      playSessionId: String,
                                      playMethod: MediaBrowserPlayMethod,
                                      positionTicks: Int) throws -> URLRequest {
        try progressBody(server: server, token: token, identity: identity, userId: userId,
                         event: .stopped,
                         itemId: itemId, mediaSourceId: mediaSourceId,
                         playSessionId: playSessionId, playMethod: playMethod,
                         positionTicks: positionTicks)
    }

    /// `POST /Sessions/Playing/Ping?PlaySessionId=..`
    public static func pingRequest(server: URL,
                                   token: String,
                                   identity: JellyfinClientIdentity,
                                   playSessionId: String) throws -> URLRequest {
        let base = try jellyfinURL(server: server, path: "/Sessions/Playing/Ping")
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw JellyfinPlaybackError.invalidURL
        }
        comps.queryItems = [URLQueryItem(name: "PlaySessionId", value: playSessionId)]
        guard let url = comps.url else { throw JellyfinPlaybackError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(JellyfinAuth.authorizationHeader(identity: identity, token: token),
                     forHTTPHeaderField: "Authorization")
        return req
    }

    private static func progressBody(server: URL,
                                     token: String,
                                     identity: JellyfinClientIdentity,
                                     userId: String,
                                     event: MediaBrowserPlaybackProgressRequestEvent,
                                     itemId: String,
                                     mediaSourceId: String,
                                     playSessionId: String,
                                     playMethod: MediaBrowserPlayMethod,
                                     positionTicks: Int) throws -> URLRequest {
        let url = try jellyfinURL(server: server, path: event.endpoint.rawValue)
        return try MediaBrowserPlaybackProgressRequestPlan(
            url: url,
            authDialect: .jellyfin(identity),
            event: event,
            payload: MediaBrowserPlaybackProgressPayload(
                userId: userId,
                itemId: itemId,
                mediaSourceId: mediaSourceId,
                playSessionId: playSessionId,
                playMethod: playMethod,
                positionTicks: positionTicks
            )
        ).request(token: token)
    }

    private static func streamHeaders(for source: JellyfinMediaSourceInfo,
                                      token: String,
                                      identity: JellyfinClientIdentity) -> [String: String] {
        var headers = source.requiredHTTPHeaders ?? [:]
        headers["Authorization"] = JellyfinAuth.authorizationHeader(identity: identity, token: token)
        return headers
    }


    private static func appendTranscodeOverrides(to url: URL,
                                                 startTimeTicks: Int?,
                                                 maxVideoBitrate: Int?,
                                                 maxWidth: Int?,
                                                 maxHeight: Int?,
                                                 audioBitrate: Int?,
                                                 audioStreamIndex: Int?,
                                                 subtitleStreamIndex: Int?) throws -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw JellyfinPlaybackError.invalidURL
        }
        var items = comps.queryItems ?? []
        func replace(_ name: String, value: String) {
            items.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            items.append(URLQueryItem(name: name, value: value))
        }
        // Jellyfin's PlaybackInfo body can ignore or partially carry over caps/deep-start/audio
        // choices for generated HLS URLs. The master.m3u8 query is what child playlists and
        // segments inherit, so enforce the app's selected shape there too. Prefer MPEG-TS
        // segments for Jellyfin live HLS because fMP4 deep-seek/reopen paths can produce
        // transient unavailable segments in AVFoundation/Jellyfin, while TS is Jellyfin's
        // more conservative HLS path. Keep caps/audio selections stable across seeks.
        replace("SegmentContainer", value: "ts")
        replace("BreakOnNonKeyFrames", value: "false")
        // Do not mirror StartTimeTicks onto the HLS master URL. Jellyfin copies master
        // query parameters into dynamic segment requests, and DynamicHlsController rejects
        // StartTimeTicks on segment URLs ("StartTimeTicks is not allowed"), which AVPlayer
        // surfaces as NSURLErrorDomain -1008 after a deep seek. The start offset belongs in
        // the PlaybackInfo body above; keep the playable URL itself segment-safe.
        _ = startTimeTicks
        if let maxVideoBitrate, maxVideoBitrate > 0, maxVideoBitrate < 200_000_000 {
            replace("VideoBitrate", value: String(maxVideoBitrate))
        }
        if let maxWidth, let maxHeight, maxWidth > 0, maxHeight > 0 {
            replace("MaxWidth", value: String(maxWidth))
            replace("MaxHeight", value: String(maxHeight))
        }
        if let audioBitrate, audioBitrate > 0 {
            replace("AudioCodec", value: "aac")
            replace("AudioBitrate", value: String(audioBitrate))
            replace("TranscodingMaxAudioChannels", value: "6")
            replace("AllowAudioStreamCopy", value: "false")
        }
        if let audioStreamIndex, audioStreamIndex >= 0 {
            replace("AudioStreamIndex", value: String(audioStreamIndex))
        }
        if let subtitleStreamIndex {
            replace("SubtitleStreamIndex", value: String(subtitleStreamIndex))
        }
        comps.queryItems = items
        guard let capped = comps.url else { throw JellyfinPlaybackError.invalidURL }
        return capped
    }

    static func chooseSource(_ sources: [JellyfinMediaSourceInfo],
                             preferredMediaSourceId: String?) -> JellyfinMediaSourceInfo? {
        if let preferredMediaSourceId,
           let source = sources.first(where: { $0.id == preferredMediaSourceId }) {
            return source
        }
        return sources.first(where: { $0.transcodingURL != nil }) ??
            sources.first(where: { $0.supportsDirectPlay }) ??
            sources.first(where: { $0.supportsDirectStream }) ??
            sources.first
    }

    static func chooseDownloadSource(_ sources: [JellyfinMediaSourceInfo],
                                     preferredMediaSourceId: String?) -> JellyfinMediaSourceInfo? {
        if let preferredMediaSourceId,
           let source = sources.first(where: { $0.id == preferredMediaSourceId }) {
            return source
        }
        return sources.first(where: { $0.supportsDirectStream }) ??
            sources.first(where: { $0.supportsDirectPlay }) ??
            sources.first(where: { $0.transcodingURL != nil }) ??
            sources.first
    }

    static func streamingDeviceProfile(maxStreamingBitrate: Int,
                                       advertiseDolbyVision: Bool = false,
                                       subtitlesInManifest: Bool = true) -> [String: Any] {
        // subtitlesInManifest: when the user explicitly chose subtitles OFF (the -1 sentinel),
        // drop the in-manifest WebVTT renditions entirely. AVFoundation displays FORCED/default
        // legible renditions matching the audio language even after `select(nil, in: group)`,
        // so a transcode manifest carrying a forced/default subtitle rendition re-shows
        // subtitles the user turned off (seen live on a forced+default track, GH #196 retest).
        var profile: [String: Any] = [
            "Name": "Labstream",
            "MaxStreamingBitrate": maxStreamingBitrate,
            "DirectPlayProfiles": MediaBrowserDeviceProfileFacts.directPlayProfiles,
            "TranscodingProfiles": MediaBrowserDeviceProfileFacts.streamingHLSTranscodingProfiles(
                subtitlePolicy: .jellyfinManifest(enabled: subtitlesInManifest)),
        ]
        if advertiseDolbyVision {
            profile["CodecProfiles"] = MediaBrowserDeviceProfileFacts.dolbyVisionCodecProfiles
        }
        return profile
    }

    static func compatibleRemuxDownloadDeviceProfile(maxStaticBitrate: Int) -> [String: Any] {
        MediaBrowserDeviceProfileFacts.compatibleRemuxDownloadProfile(
            maxStaticBitrate: maxStaticBitrate)
    }

    static func jellyfinURL(server: URL, path: String) throws -> URL {
        try jellyfinURL(server: server, pathOrURLString: path)
    }

    static func jellyfinURL(server: URL, pathOrURLString: String) throws -> URL {
        guard let url = MediaBrowserURL.joinTrustedServerURL(server: server, pathOrURLString: pathOrURLString) else {
            throw JellyfinPlaybackError.invalidURL
        }
        return url
    }
}
