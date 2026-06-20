import Foundation

public enum EmbyPlayMethod: String, Sendable, Equatable {
    case directPlay
    case directStream
    case transcode
}

public struct EmbyPlaybackSourceMetadata: Sendable, Equatable {
    public static let empty = EmbyPlaybackSourceMetadata()

    public let container: String?
    public let width: Int?
    public let height: Int?
    /// Kbps, matching Plex `Media.bitrate` units used by the diagnostics UI.
    public let bitrate: Int?
    public let videoCodec: String?
    public let audioCodec: String?

    public init(container: String? = nil,
                width: Int? = nil,
                height: Int? = nil,
                bitrate: Int? = nil,
                videoCodec: String? = nil,
                audioCodec: String? = nil) {
        self.container = container
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
    }
}

public struct EmbyPlaybackOpenResult: Sendable, Equatable {
    public let url: URL
    public let playSessionId: String
    public let mediaSourceId: String
    public let playMethod: EmbyPlayMethod
    public let requiredHTTPHeaders: [String: String]
    public let sourceMetadata: EmbyPlaybackSourceMetadata
    /// True when the chosen source uses server-side encoding (transcode/HLS) — the caller
    /// must `DELETE /Videos/ActiveEncodings` on stop (cleanup invariant).
    public let usesServerEncoding: Bool

    public init(url: URL,
                playSessionId: String,
                mediaSourceId: String,
                playMethod: EmbyPlayMethod,
                requiredHTTPHeaders: [String: String] = [:],
                sourceMetadata: EmbyPlaybackSourceMetadata = .empty,
                usesServerEncoding: Bool = false) {
        self.url = url
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.playMethod = playMethod
        self.requiredHTTPHeaders = requiredHTTPHeaders
        self.sourceMetadata = sourceMetadata
        self.usesServerEncoding = usesServerEncoding
    }
}

public struct EmbyPlaybackInfoResponse: Decodable, Sendable, Equatable {
    public let playSessionId: String?
    public let mediaSources: [EmbyMediaSourceInfo]

    enum CodingKeys: String, CodingKey {
        case playSessionId = "PlaySessionId"
        case mediaSources = "MediaSources"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playSessionId = try c.decodeIfPresent(String.self, forKey: .playSessionId)
        mediaSources = try c.decodeIfPresent([EmbyMediaSourceInfo].self, forKey: .mediaSources) ?? []
    }

    public static func decode(from data: Data) throws -> EmbyPlaybackInfoResponse {
        try JSONDecoder().decode(EmbyPlaybackInfoResponse.self, from: data)
    }
}

public struct EmbyMediaSourceInfo: Decodable, Sendable, Equatable {
    public let id: String?
    public let name: String?
    public let container: String?
    public let eTag: String?
    public let supportsDirectPlay: Bool
    public let supportsDirectStream: Bool
    public let supportsTranscoding: Bool
    public let directStreamURL: String?
    public let transcodingURL: String?
    public let transcodingSubProtocol: String?
    public let transcodingContainer: String?
    public let requiredHTTPHeaders: [String: String]?
    public let addApiKeyToDirectStreamURL: Bool?
    public let requiresOpening: Bool?
    public let requiresClosing: Bool?
    public let liveStreamID: String?
    public let bitrate: Int?
    public let width: Int?
    public let height: Int?
    public let videoCodec: String?
    public let audioCodec: String?
    public let mediaStreams: [EmbyItemMediaStreamDto]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case eTag = "ETag"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case directStreamURL = "DirectStreamUrl"
        case transcodingURL = "TranscodingUrl"
        case transcodingSubProtocol = "TranscodingSubProtocol"
        case transcodingContainer = "TranscodingContainer"
        case requiredHTTPHeaders = "RequiredHttpHeaders"
        case addApiKeyToDirectStreamURL = "AddApiKeyToDirectStreamUrl"
        case requiresOpening = "RequiresOpening"
        case requiresClosing = "RequiresClosing"
        case liveStreamID = "LiveStreamId"
        case bitrate = "Bitrate"
        case width = "Width"
        case height = "Height"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case mediaStreams = "MediaStreams"
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
        directStreamURL = try c.decodeIfPresent(String.self, forKey: .directStreamURL)
        transcodingURL = try c.decodeIfPresent(String.self, forKey: .transcodingURL)
        transcodingSubProtocol = try c.decodeIfPresent(String.self, forKey: .transcodingSubProtocol)
        transcodingContainer = try c.decodeIfPresent(String.self, forKey: .transcodingContainer)
        requiredHTTPHeaders = try c.decodeIfPresent([String: String].self, forKey: .requiredHTTPHeaders)
        addApiKeyToDirectStreamURL = try c.decodeIfPresent(Bool.self, forKey: .addApiKeyToDirectStreamURL)
        requiresOpening = try c.decodeIfPresent(Bool.self, forKey: .requiresOpening)
        requiresClosing = try c.decodeIfPresent(Bool.self, forKey: .requiresClosing)
        liveStreamID = try c.decodeIfPresent(String.self, forKey: .liveStreamID)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec)
        mediaStreams = try c.decodeIfPresent([EmbyItemMediaStreamDto].self, forKey: .mediaStreams) ?? []
    }

    func playbackSourceMetadata(audioStreamIndex: Int? = nil) -> EmbyPlaybackSourceMetadata {
        let video = mediaStreams.first { $0.type == "Video" }
        let audio = audioStreamIndex.flatMap { index in
            mediaStreams.first { $0.type == "Audio" && $0.index == index }
        } ?? mediaStreams.first { $0.type == "Audio" }
        return EmbyPlaybackSourceMetadata(
            container: container?.split(separator: ",").first.map(String.init),
            width: width ?? video?.width,
            height: height ?? video?.height,
            bitrate: bitrate.map { $0 / 1_000 },
            videoCodec: videoCodec ?? video?.codec,
            audioCodec: audioStreamIndex == nil ? (audioCodec ?? audio?.codec) : (audio?.codec ?? audioCodec))
    }

    var playbackSourceMetadata: EmbyPlaybackSourceMetadata {
        playbackSourceMetadata()
    }

    func preferredCompatibleAudioStreamIndexForCappedTranscode() -> Int? {
        let audioStreams = mediaStreams.filter { $0.type == "Audio" }
        guard !audioStreams.isEmpty else { return nil }

        let current = audioStreams.first { $0.isDefault == true } ?? audioStreams.first
        if let current, current.isLowRiskEmbyTranscodeAudio {
            return nil
        }

        let compatible = audioStreams.filter(\.isLowRiskEmbyTranscodeAudio)
        guard !compatible.isEmpty else { return nil }

        let currentLanguage = current?.language?.lowercased()
        let sameLanguage = compatible.filter { stream in
            guard let currentLanguage, !currentLanguage.isEmpty else { return false }
            return stream.language?.lowercased() == currentLanguage
        }

        return (sameLanguage.first { !$0.looksLikeCommentaryOrDescriptiveAudio } ??
                sameLanguage.first ??
                compatible.first { !$0.looksLikeCommentaryOrDescriptiveAudio } ??
                compatible.first)?.index
    }
}

public enum EmbyPlaybackError: Error, Sendable, Equatable {
    case noMediaSources
    case missingPlaySessionId
    case missingMediaSourceId
    case unsupportedMediaSource
    case invalidURL
}

public enum EmbyPlayback {
    /// `POST /Items/{Id}/PlaybackInfo?UserId={UserId}`.
    ///
    /// DIVERGENCE FROM JELLYFIN: `UserId` rides in BOTH the query AND the body; the body
    /// carries the full constraint set plus `AutoOpenLiveStream:false` (Jellyfin used
    /// `true`). POST is required so the `DeviceProfile` + constraints are sent.
    public static func playbackInfoRequest(server: URL,
                                           token: String,
                                           identity: EmbyClientIdentity,
                                           userId: String,
                                           itemId: String,
                                           mediaSourceId: String? = nil,
                                           startTimeTicks: Int? = nil,
                                           maxStreamingBitrate: Int,
                                           audioStreamIndex: Int? = nil,
                                           subtitleStreamIndex: Int? = nil) throws -> URLRequest {
        let url = try embyURL(server: server,
                              path: "/Items/\(itemId)/PlaybackInfo",
                              queryItems: [URLQueryItem(name: "UserId", value: userId)])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: userId, token: token)

        var body: [String: Any] = [
            "UserId": userId,
            "MaxStreamingBitrate": maxStreamingBitrate,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": true,
            "AllowAudioStreamCopy": true,
            "AutoOpenLiveStream": false,
            "DeviceProfile": visionOSDeviceProfile(maxStreamingBitrate: maxStreamingBitrate),
        ]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        if let startTimeTicks { body["StartTimeTicks"] = startTimeTicks }
        if let audioStreamIndex { body["AudioStreamIndex"] = audioStreamIndex }
        if let subtitleStreamIndex { body["SubtitleStreamIndex"] = subtitleStreamIndex }

        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// Resolve a playable URL from a PlaybackInfo response.
    ///
    /// Preference order: server-generated `TranscodingUrl`, then `DirectStreamUrl`, then a
    /// synthesized direct-play `stream.{container}` URL.
    ///
    /// DIVERGENCE FROM JELLYFIN: the server-generated stream URLs carry the token in the
    /// query (`api_key=`), so AVPlayer's HLS child playlists/segments inherit auth — no
    /// per-child `Authorization` header is injected. Stream URLs are RELATIVE
    /// (`/videos/{id}/master.m3u8`, lowercase) and prepended onto the server base URL,
    /// preserving any base path. REDACT `api_key` in logs.
    public static func resolveStream(response: EmbyPlaybackInfoResponse,
                                     server: URL,
                                     identity: EmbyClientIdentity,
                                     token: String,
                                     userId: String,
                                     itemId: String,
                                     preferredMediaSourceId: String? = nil,
                                     startTimeTicks: Int? = nil,
                                     maxVideoBitrate: Int? = nil,
                                     maxWidth: Int? = nil,
                                     maxHeight: Int? = nil,
                                     audioBitrate: Int? = nil,
                                     audioStreamIndex: Int? = nil,
                                     subtitleStreamIndex: Int? = nil) throws -> EmbyPlaybackOpenResult {
        guard let playSessionId = response.playSessionId, !playSessionId.isEmpty else {
            throw EmbyPlaybackError.missingPlaySessionId
        }
        guard let source = chooseSource(response.mediaSources, preferredMediaSourceId: preferredMediaSourceId) else {
            throw EmbyPlaybackError.noMediaSources
        }
        guard let mediaSourceId = source.id, !mediaSourceId.isEmpty else {
            throw EmbyPlaybackError.missingMediaSourceId
        }

        // Prefer the server-generated transcode URL (HLS). Token rides in api_key query.
        if let transcodingURL = source.transcodingURL, !transcodingURL.isEmpty {
            let resolvedAudioStreamIndex = audioStreamIndex ??
                (audioBitrate == nil ? nil : source.preferredCompatibleAudioStreamIndexForCappedTranscode())
            let url = try embyURL(server: server, pathOrURLString: transcodingURL)
            let method: EmbyPlayMethod = source.supportsDirectStream && !source.supportsDirectPlay ? .directStream : .transcode
            return EmbyPlaybackOpenResult(
                url: url,
                playSessionId: playSessionId,
                mediaSourceId: mediaSourceId,
                playMethod: method,
                // HLS children inherit api_key from the query — do NOT inject Authorization.
                requiredHTTPHeaders: source.requiredHTTPHeaders ?? [:],
                sourceMetadata: source.playbackSourceMetadata(audioStreamIndex: resolvedAudioStreamIndex),
                usesServerEncoding: true)
        }

        // Next prefer the server-generated direct-stream URL.
        if let directStreamURL = source.directStreamURL, !directStreamURL.isEmpty {
            var url = try embyURL(server: server, pathOrURLString: directStreamURL)
            if source.addApiKeyToDirectStreamURL == true {
                url = try ensureApiKey(on: url, token: token)
            }
            // When api_key is NOT added to the URL, attach via the X-Emby-Token header.
            let headers: [String: String]
            if source.addApiKeyToDirectStreamURL == true {
                headers = source.requiredHTTPHeaders ?? [:]
            } else {
                var h = source.requiredHTTPHeaders ?? [:]
                h["X-Emby-Token"] = token
                headers = h
            }
            return EmbyPlaybackOpenResult(
                url: url,
                playSessionId: playSessionId,
                mediaSourceId: mediaSourceId,
                playMethod: .directStream,
                requiredHTTPHeaders: headers,
                sourceMetadata: source.playbackSourceMetadata(audioStreamIndex: audioStreamIndex),
                usesServerEncoding: false)
        }

        // Last resort: synthesize a direct-play stream URL.
        guard source.supportsDirectPlay || source.supportsDirectStream else {
            throw EmbyPlaybackError.unsupportedMediaSource
        }
        let container = (source.container?.split(separator: ",").first).map(String.init) ?? "mp4"
        let base = try embyURL(server: server, path: "/videos/\(itemId)/stream.\(container)")
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw EmbyPlaybackError.invalidURL
        }
        var query = [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "PlaySessionId", value: playSessionId),
            URLQueryItem(name: "DeviceId", value: identity.deviceId),
            URLQueryItem(name: "api_key", value: token),
        ]
        if let tag = source.eTag, !tag.isEmpty {
            query.append(URLQueryItem(name: "Tag", value: tag))
        }
        comps.queryItems = query
        guard let built = comps.url else { throw EmbyPlaybackError.invalidURL }
        return EmbyPlaybackOpenResult(
            url: built,
            playSessionId: playSessionId,
            mediaSourceId: mediaSourceId,
            playMethod: source.supportsDirectPlay ? .directPlay : .directStream,
            requiredHTTPHeaders: source.requiredHTTPHeaders ?? [:],
            sourceMetadata: source.playbackSourceMetadata(audioStreamIndex: audioStreamIndex),
            usesServerEncoding: false)
    }

    static func chooseSource(_ sources: [EmbyMediaSourceInfo],
                             preferredMediaSourceId: String?) -> EmbyMediaSourceInfo? {
        if let preferredMediaSourceId,
           let source = sources.first(where: { $0.id == preferredMediaSourceId }) {
            return source
        }
        return sources.first(where: { $0.transcodingURL != nil }) ??
            sources.first(where: { $0.supportsDirectPlay }) ??
            sources.first(where: { $0.supportsDirectStream }) ??
            sources.first
    }

    private static func ensureApiKey(on url: URL, token: String) throws -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw EmbyPlaybackError.invalidURL
        }
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame }) {
            items.append(URLQueryItem(name: "api_key", value: token))
        }
        comps.queryItems = items
        guard let built = comps.url else { throw EmbyPlaybackError.invalidURL }
        return built
    }

    // MARK: - Progress reporting

    /// `POST /Sessions/Playing`
    public static func playingRequest(server: URL,
                                      token: String,
                                      identity: EmbyClientIdentity,
                                      userId: String,
                                      itemId: String,
                                      mediaSourceId: String,
                                      playSessionId: String,
                                      playMethod: EmbyPlayMethod,
                                      positionTicks: Int = 0) throws -> URLRequest {
        try progressBody(server: server, token: token, identity: identity, userId: userId,
                         path: "/Sessions/Playing",
                         itemId: itemId, mediaSourceId: mediaSourceId,
                         playSessionId: playSessionId, playMethod: playMethod,
                         positionTicks: positionTicks, isPaused: false)
    }

    /// `POST /Sessions/Playing/Progress`
    public static func progressRequest(server: URL,
                                       token: String,
                                       identity: EmbyClientIdentity,
                                       userId: String,
                                       itemId: String,
                                       mediaSourceId: String,
                                       playSessionId: String,
                                       playMethod: EmbyPlayMethod,
                                       positionTicks: Int,
                                       isPaused: Bool) throws -> URLRequest {
        try progressBody(server: server, token: token, identity: identity, userId: userId,
                         path: "/Sessions/Playing/Progress",
                         itemId: itemId, mediaSourceId: mediaSourceId,
                         playSessionId: playSessionId, playMethod: playMethod,
                         positionTicks: positionTicks, isPaused: isPaused)
    }

    /// `POST /Sessions/Playing/Stopped`
    public static func stoppedRequest(server: URL,
                                      token: String,
                                      identity: EmbyClientIdentity,
                                      userId: String,
                                      itemId: String,
                                      mediaSourceId: String,
                                      playSessionId: String,
                                      playMethod: EmbyPlayMethod,
                                      positionTicks: Int) throws -> URLRequest {
        try progressBody(server: server, token: token, identity: identity, userId: userId,
                         path: "/Sessions/Playing/Stopped",
                         itemId: itemId, mediaSourceId: mediaSourceId,
                         playSessionId: playSessionId, playMethod: playMethod,
                         positionTicks: positionTicks, isPaused: false)
    }

    /// `POST /Sessions/Playing/Ping?PlaySessionId=..`
    public static func pingRequest(server: URL,
                                   token: String,
                                   identity: EmbyClientIdentity,
                                   userId: String,
                                   playSessionId: String) throws -> URLRequest {
        let url = try embyURL(server: server,
                              path: "/Sessions/Playing/Ping",
                              queryItems: [URLQueryItem(name: "PlaySessionId", value: playSessionId)])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: userId, token: token)
        return req
    }

    private static func progressBody(server: URL,
                                     token: String,
                                     identity: EmbyClientIdentity,
                                     userId: String,
                                     path: String,
                                     itemId: String,
                                     mediaSourceId: String,
                                     playSessionId: String,
                                     playMethod: EmbyPlayMethod,
                                     positionTicks: Int,
                                     isPaused: Bool) throws -> URLRequest {
        let url = try embyURL(server: server, path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: userId, token: token)
        let body: [String: Any] = [
            "ItemId": itemId,
            "MediaSourceId": mediaSourceId,
            "PlaySessionId": playSessionId,
            "PositionTicks": positionTicks,
            "IsPaused": isPaused,
            "PlayMethod": embyPlayMethodWireValue(playMethod),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    private static func embyPlayMethodWireValue(_ method: EmbyPlayMethod) -> String {
        switch method {
        case .directPlay: return "DirectPlay"
        case .directStream: return "DirectStream"
        case .transcode: return "Transcode"
        }
    }

    static func visionOSDeviceProfile(maxStreamingBitrate: Int) -> [String: Any] {
        [
            "Name": "VisionPlay",
            "MaxStreamingBitrate": maxStreamingBitrate,
            "DirectPlayProfiles": [
                ["Type": "Video", "Container": "mp4,m4v,mov", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3"],
                ["Type": "Video", "Container": "mpegts", "VideoCodec": "h264", "AudioCodec": "aac,ac3,eac3"],
            ],
            "TranscodingProfiles": [
                [
                    "Type": "Video",
                    "Container": "ts",
                    "Protocol": "hls",
                    "VideoCodec": "h264",
                    "AudioCodec": "aac,ac3",
                    "Context": "Streaming",
                    "MinSegments": 2,
                    "BreakOnNonKeyFrames": false,
                ],
            ],
            // We do not render external sidecars or in-manifest WebVTT (Emby 4.9.3 does not embed
            // subtitle renditions in its HLS manifest), so every subtitle we ask for must be
            // burned into the video by the server. Declaring all common text and image subtitle
            // formats with Method "Encode" makes Emby resolve a selected `SubtitleStreamIndex` to
            // a burn-in transcode deterministically, for both text (SRT/ASS) and image (PGS/VOBSUB)
            // subtitles. Only consulted when a subtitle is actually selected.
            "SubtitleProfiles": [
                ["Format": "srt", "Method": "Encode"],
                ["Format": "subrip", "Method": "Encode"],
                ["Format": "ass", "Method": "Encode"],
                ["Format": "ssa", "Method": "Encode"],
                ["Format": "vtt", "Method": "Encode"],
                ["Format": "webvtt", "Method": "Encode"],
                ["Format": "sub", "Method": "Encode"],
                ["Format": "idx", "Method": "Encode"],
                ["Format": "pgssub", "Method": "Encode"],
                ["Format": "dvdsub", "Method": "Encode"],
                ["Format": "dvbsub", "Method": "Encode"],
            ],
        ]
    }

    // MARK: - URL joining (base-path preserving)

    static func embyURL(server: URL, path: String) throws -> URL {
        try embyURL(server: server, pathOrURLString: path)
    }

    static func embyURL(server: URL, path: String, queryItems: [URLQueryItem]) throws -> URL {
        let base = try embyURL(server: server, pathOrURLString: path)
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw EmbyPlaybackError.invalidURL
        }
        comps.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = comps.url else { throw EmbyPlaybackError.invalidURL }
        return url
    }

    /// Join a server-relative path (or pass through an absolute URL) onto the server base
    /// URL, PRESERVING the server's base path (for example `/emby`). Mirrors Jellyfin's
    /// join helper.
    static func embyURL(server: URL, pathOrURLString: String) throws -> URL {
        if let absolute = URL(string: pathOrURLString), absolute.scheme != nil {
            return absolute
        }
        guard var comps = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            throw EmbyPlaybackError.invalidURL
        }
        let basePath = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath: String
        let query: String?
        if let qIndex = pathOrURLString.firstIndex(of: "?") {
            relativePath = String(pathOrURLString[..<qIndex])
            query = String(pathOrURLString[pathOrURLString.index(after: qIndex)...])
        } else {
            relativePath = pathOrURLString
            query = nil
        }
        let cleanRelative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comps.percentEncodedPath = "/" + [basePath, cleanRelative].filter { !$0.isEmpty }.joined(separator: "/")
        comps.percentEncodedQuery = query
        guard let url = comps.url else { throw EmbyPlaybackError.invalidURL }
        return url
    }
}
