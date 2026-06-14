import Foundation

public enum JellyfinPlayMethod: String, Sendable, Equatable {
    case directPlay
    case directStream
    case transcode
}

public struct JellyfinPlaybackOpenResult: Sendable, Equatable {
    public let url: URL
    public let playSessionId: String
    public let mediaSourceId: String
    public let playMethod: JellyfinPlayMethod
    public let requiredHTTPHeaders: [String: String]

    public init(url: URL,
                playSessionId: String,
                mediaSourceId: String,
                playMethod: JellyfinPlayMethod,
                requiredHTTPHeaders: [String: String] = [:]) {
        self.url = url
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.playMethod = playMethod
        self.requiredHTTPHeaders = requiredHTTPHeaders
    }
}

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
    }
}

public enum JellyfinPlaybackError: Error, Sendable, Equatable {
    case noMediaSources
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
                                           subtitleStreamIndex: Int? = nil) throws -> URLRequest {
        let url = try jellyfinURL(server: server, path: "/Items/\(itemId)/PlaybackInfo")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(JellyfinAuth.authorizationHeader(identity: identity, token: token),
                     forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "UserId": userId,
            "MaxStreamingBitrate": maxStreamingBitrate,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": true,
            "AllowAudioStreamCopy": true,
            "AutoOpenLiveStream": true,
            "DeviceProfile": visionOSDeviceProfile(maxStreamingBitrate: maxStreamingBitrate),
        ]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        if let startTimeTicks { body["StartTimeTicks"] = startTimeTicks }
        if let audioStreamIndex { body["AudioStreamIndex"] = audioStreamIndex }
        if let subtitleStreamIndex { body["SubtitleStreamIndex"] = subtitleStreamIndex }

        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    public static func resolveStream(response: JellyfinPlaybackInfoResponse,
                                     server: URL,
                                     token: String,
                                     itemId: String,
                                     preferredMediaSourceId: String? = nil) throws -> JellyfinPlaybackOpenResult {
        guard let playSessionId = response.playSessionId, !playSessionId.isEmpty else {
            throw JellyfinPlaybackError.missingPlaySessionId
        }
        guard let source = chooseSource(response.mediaSources, preferredMediaSourceId: preferredMediaSourceId) else {
            throw JellyfinPlaybackError.noMediaSources
        }
        guard let mediaSourceId = source.id, !mediaSourceId.isEmpty else {
            throw JellyfinPlaybackError.missingMediaSourceId
        }

        if let transcodingURL = source.transcodingURL, !transcodingURL.isEmpty {
            let url = try jellyfinURL(server: server, pathOrURLString: transcodingURL)
            let method: JellyfinPlayMethod = source.supportsDirectStream && !source.supportsDirectPlay ? .directStream : .transcode
            return JellyfinPlaybackOpenResult(
                url: url,
                playSessionId: playSessionId,
                mediaSourceId: mediaSourceId,
                playMethod: method,
                requiredHTTPHeaders: source.requiredHTTPHeaders ?? [:])
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
            URLQueryItem(name: "api_key", value: token),
        ]
        if let tag = source.eTag, !tag.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "Tag", value: tag))
        }
        guard let built = comps.url else { throw JellyfinPlaybackError.invalidURL }
        return JellyfinPlaybackOpenResult(
            url: built,
            playSessionId: playSessionId,
            mediaSourceId: mediaSourceId,
            playMethod: source.supportsDirectPlay ? .directPlay : .directStream,
            requiredHTTPHeaders: source.requiredHTTPHeaders ?? [:])
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

    static func visionOSDeviceProfile(maxStreamingBitrate: Int) -> [String: Any] {
        [
            "Name": "VisionPlex",
            "MaxStreamingBitrate": maxStreamingBitrate,
            "DirectPlayProfiles": [
                ["Type": "Video", "Container": "mp4,m4v,mov", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3"],
                ["Type": "Video", "Container": "mpegts", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3"],
            ],
            "TranscodingProfiles": [
                [
                    "Type": "Video",
                    "Container": "ts",
                    "Protocol": "hls",
                    "VideoCodec": "h264",
                    "AudioCodec": "aac,ac3,eac3",
                    "Context": "Streaming",
                    "MinSegments": 2,
                    "BreakOnNonKeyFrames": true,
                    "EnableSubtitlesInManifest": true,
                ],
            ],
        ]
    }

    static func jellyfinURL(server: URL, path: String) throws -> URL {
        try jellyfinURL(server: server, pathOrURLString: path)
    }

    static func jellyfinURL(server: URL, pathOrURLString: String) throws -> URL {
        if let absolute = URL(string: pathOrURLString), absolute.scheme != nil {
            return absolute
        }
        guard var comps = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            throw JellyfinPlaybackError.invalidURL
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
        guard let url = comps.url else { throw JellyfinPlaybackError.invalidURL }
        return url
    }
}
