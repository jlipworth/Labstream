import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    /// `Protocol` of the source — `File` for an on-disk media file (the original AND any
    /// server-side converted copy), vs `Http`/remote for a live/remote source. #126 enumerates
    /// only `File` sources as downloadable existing versions (a remote/live source can't be a
    /// byte-for-byte static download). Absent on older servers → treated as a local file.
    public let mediaProtocol: String?
    /// Total byte size of the original source file. `Part.size` is always nil on Emby
    /// (see `EmbyItemMediaSourceDto`), so this is the only storage-preflight / expected-bytes
    /// signal for a downloadable original. Absent on some sources.
    public let size: Int?
    /// Why the server chose to transcode (e.g. `ContainerNotSupported`). Decoded as raw
    /// strings so the download decision can surface a privacy-safe reason; never gates the
    /// download by itself (the negotiated booleans do).
    public let transcodeReasons: [String]
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
        case mediaProtocol = "Protocol"
        case size = "Size"
        case transcodeReasons = "TranscodeReasons"
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
        mediaProtocol = try c.decodeIfPresent(String.self, forKey: .mediaProtocol)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        transcodeReasons = try c.decodeIfPresent([String].self, forKey: .transcodeReasons) ?? []
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
        if let current, current.isLowRiskTranscodeAudio {
            return nil
        }

        let compatible = audioStreams.filter(\.isLowRiskTranscodeAudio)
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

    /// `POST /Items/{Id}/PlaybackInfo` for an OFFLINE DOWNLOAD.
    ///
    /// Identical wire shape to `playbackInfoRequest` except it posts the DOWNLOAD device
    /// profile (Static-context mp4 transcode, NOT HLS) so the negotiated `TranscodingUrl` is a
    /// single downloadable file. POST is required so Emby mints the `PlaySessionId` that the
    /// transcoded-download URL needs (a hand-built `stream.mp4?static=false` returns HTTP 400
    /// "Parameter 'key'") — and that same session must later be torn down via
    /// `EmbyLibrary.activeEncodingStopRequest`.
    public static func downloadPlaybackInfoRequest(server: URL,
                                                   token: String,
                                                   identity: EmbyClientIdentity,
                                                   userId: String,
                                                   itemId: String,
                                                   mediaSourceId: String? = nil,
                                                   maxStaticBitrate: Int) throws -> URLRequest {
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
            "MaxStreamingBitrate": maxStaticBitrate,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": true,
            "AllowAudioStreamCopy": true,
            "AutoOpenLiveStream": false,
            "DeviceProfile": visionOSDownloadDeviceProfile(maxStaticBitrate: maxStaticBitrate),
        ]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// `POST /Items/{Id}/PlaybackInfo` for the #83 "Original quality (compatible)" offline lane.
    /// Separate from `downloadPlaybackInfoRequest`: the normal download profile intentionally keeps
    /// HEVC out of the static MP4 transcode verdict so the forced-transcode lane stays conservative,
    /// while this profile explicitly permits h264/hevc video stream-copy to test remux eligibility.
    public static func compatibleRemuxDownloadPlaybackInfoRequest(server: URL,
                                                                  token: String,
                                                                  identity: EmbyClientIdentity,
                                                                  userId: String,
                                                                  itemId: String,
                                                                  mediaSourceId: String? = nil,
                                                                  maxStaticBitrate: Int) throws -> URLRequest {
        let url = try embyURL(server: server,
                              path: "/Items/\(itemId)/PlaybackInfo",
                              queryItems: [URLQueryItem(name: "UserId", value: userId)])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(EmbyAuth.authorizationHeader(identity: identity, userId: userId, token: token),
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
            "DeviceProfile": visionOSCompatibleRemuxDownloadDeviceProfile(maxStaticBitrate: maxStaticBitrate),
        ]
        if let mediaSourceId { body["MediaSourceId"] = mediaSourceId }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// Typed negotiated verdict for an offline download, distilled from a download PlaybackInfo
    /// response. The crux of the detection rule:
    /// - `supportsDirectPlay` is the AUTHORITATIVE negotiated value (NOT the optimistic naked-item
    ///   value, NOT URL presence) — true ⇔ the whole source file is byte-for-byte downloadable.
    /// - `transcodingURL` is the server-minted single-file transcode URL to download when the
    ///   original is not direct-play-eligible.
    /// - `size` is the original's byte size for storage preflight (`Part.size` is nil on Emby).
    public struct EmbyDownloadPlaybackDecision: Sendable, Equatable {
        public let playSessionId: String
        public let mediaSourceId: String
        public let supportsDirectPlay: Bool
        /// #83: negotiated remux signal — true ⇔ the server can DirectStream (container remux,
        /// codecs copied). Used to gate the "Original quality (compatible)" lane.
        public let supportsDirectStream: Bool
        public let transcodingURL: String?
        public let size: Int?
        public let container: String?
        public let bitrate: Int?
        /// #83: source video/audio codec tokens (first video/audio stream), for the compatible-remux
        /// eligibility decision (`OfflineDownloadDecision.compatibleRemuxEligibility`).
        public let videoCodec: String?
        public let audioCodec: String?
        public let transcodeReasons: [String]
    }

    /// Distill a download PlaybackInfo response into the typed verdict above. Throws when the
    /// response lacks a `PlaySessionId` / media source / source id (all required to either
    /// download the transcode or tear down the encoder afterwards).
    public static func downloadDecision(response: EmbyPlaybackInfoResponse,
                                        preferredMediaSourceId: String? = nil) throws -> EmbyDownloadPlaybackDecision {
        guard let playSessionId = response.playSessionId, !playSessionId.isEmpty else {
            throw EmbyPlaybackError.missingPlaySessionId
        }
        guard let source = chooseSource(response.mediaSources, preferredMediaSourceId: preferredMediaSourceId) else {
            throw EmbyPlaybackError.noMediaSources
        }
        guard let mediaSourceId = source.id, !mediaSourceId.isEmpty else {
            throw EmbyPlaybackError.missingMediaSourceId
        }
        let videoStream = source.mediaStreams.first { $0.type == "Video" }
        let audioStream = source.mediaStreams.first { $0.type == "Audio" }
        return EmbyDownloadPlaybackDecision(
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

    /// #126: an alternate, already-on-disk Emby MediaSource offered as a byte-for-byte download —
    /// the parity of Plex's "existing server version" lane (#112). Produced by Emby's "Convert
    /// Media" (a Sync job to the "next to original files" target), which adds the converted copy as
    /// a second `File` MediaSource on the SAME item with its own distinct `Id`. Downloaded statically
    /// via `EmbyLibrary.downloadOriginalRequest(mediaSourceId:)` — NO new conversion is triggered and
    /// the server's copy is left in place.
    public struct EmbyExistingVersion: Sendable, Equatable, Identifiable {
        public let mediaSourceId: String
        public let name: String?
        public let container: String?
        public let videoCodec: String?
        public let audioCodec: String?
        public let size: Int?
        public let width: Int?
        public let height: Int?
        public let bitrate: Int?
        public let supportsDirectPlay: Bool
        public var id: String { mediaSourceId }

        public init(mediaSourceId: String, name: String?, container: String?, videoCodec: String?,
                    audioCodec: String?, size: Int?, width: Int?, height: Int?, bitrate: Int?,
                    supportsDirectPlay: Bool) {
            self.mediaSourceId = mediaSourceId
            self.name = name
            self.container = container
            self.videoCodec = videoCodec
            self.audioCodec = audioCodec
            self.size = size
            self.width = width
            self.height = height
            self.bitrate = bitrate
            self.supportsDirectPlay = supportsDirectPlay
        }
    }

    /// #126: enumerate the downloadable EXISTING versions of an item from a PlaybackInfo response —
    /// every on-disk (`Protocol == File`) MediaSource OTHER than the primary one the caller already
    /// offers through its normal Original/Remux/Optimize options (`primaryMediaSourceId`). The
    /// offline-playability gate (`OfflineDownloadDecision.existingVersionPlayableOffline`) is applied
    /// by the caller (UI), mirroring the Plex lane: incompatible alternates are shown DISABLED, not
    /// hidden, so the user understands why they can't pick them. Order is preserved from the response.
    public static func existingDownloadableVersions(
        response: EmbyPlaybackInfoResponse,
        primaryMediaSourceId: String?) -> [EmbyExistingVersion] {
        response.mediaSources.compactMap { source in
            guard let id = source.id, !id.isEmpty else { return nil }
            // The primary source is already offered above as Original/Remux/Optimize — never as a
            // duplicate "existing version".
            guard id != primaryMediaSourceId else { return nil }
            // Only on-disk files are byte-for-byte downloadable. Treat an ABSENT Protocol as File
            // (older servers omit it for local sources); exclude only an explicit non-File protocol
            // (a remote/live source can't be a static download).
            if let proto = source.mediaProtocol, proto.caseInsensitiveCompare("File") != .orderedSame {
                return nil
            }
            let video = source.mediaStreams.first { $0.type == "Video" }
            let audio = source.mediaStreams.first { $0.type == "Audio" }
            return EmbyExistingVersion(
                mediaSourceId: id,
                name: source.name,
                container: source.container?.split(separator: ",").first.map(String.init) ?? source.container,
                videoCodec: source.videoCodec ?? video?.codec,
                audioCodec: source.audioCodec ?? audio?.codec,
                size: source.size,
                width: source.width ?? video?.width,
                height: source.height ?? video?.height,
                bitrate: source.bitrate,
                supportsDirectPlay: source.supportsDirectPlay)
        }
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

    /// DOWNLOAD-ONLY device profile.
    ///
    /// DIVERGENCE FROM PLAYBACK: the playback profile (`visionOSDeviceProfile`) advertises an
    /// HLS (`Protocol: hls`) TranscodingProfile, so PlaybackInfo returns a `master.m3u8`
    /// TranscodingUrl — a segment playlist, NOT a single downloadable file. For offline
    /// downloads we instead advertise a **Static-context, http mp4** TranscodingProfile, which
    /// makes the server hand back a single-file `/videos/{id}/stream?...` TranscodingUrl that a
    /// background `URLSession` download task can pull as one body. Confirmed live against the
    /// MKV worst case: `subProtocol=nil`, `Size` populated.
    ///
    /// `MaxStaticBitrate` is advertised generously (≈200 Mbps default) so a high-bitrate but
    /// already-compatible mp4/m4v/mov file still qualifies for a direct-play (original) download —
    /// a bitrate cap must NEVER force a transcode verdict for a download.
    static func visionOSDownloadDeviceProfile(maxStaticBitrate: Int) -> [String: Any] {
        // CRITICAL (caught by the on-device download probe — see DebugEmbyDownloadProbe): the
        // DirectPlayProfile must NOT advertise `hevc`/`ac3`/`eac3` for downloads. If it does, an
        // MKV/HEVC/DTS source negotiates to a stream-COPY remux (`ffmpeg -c:v copy -c:a copy`) into
        // the static mp4 container, which fails ("Error starting ffmpeg", HTTP 500) because DTS
        // (and copied HEVC) can't be muxed into mp4 that way. Restricting DirectPlay to the codecs
        // that are both AVPlayer-locally-playable AND mp4-copy-safe (h264 + aac/ac3) forces every
        // other source to a REAL re-encode via the TranscodingProfile, producing a guaranteed
        // single-file h264/aac mp4. A clean h264 mp4 still downloads as a byte-exact original
        // (the two-gate `original` path), so this only changes which sources transcode.
        [
            "Name": "VisionPlay-Download",
            "MaxStaticBitrate": maxStaticBitrate,
            "MaxStreamingBitrate": maxStaticBitrate,
            "DirectPlayProfiles": [
                ["Type": "Video", "Container": "mp4,m4v,mov", "VideoCodec": "h264", "AudioCodec": "aac,ac3"],
            ],
            "TranscodingProfiles": [
                [
                    "Type": "Video",
                    "Container": "mp4",
                    "Protocol": "http",
                    "VideoCodec": "h264",
                    "AudioCodec": "aac",
                    "Context": "Static",
                    "BreakOnNonKeyFrames": false,
                ],
            ],
        ]
    }

    static func visionOSCompatibleRemuxDownloadDeviceProfile(maxStaticBitrate: Int) -> [String: Any] {
        [
            "Name": "VisionPlay-Compatible-Download",
            "MaxStaticBitrate": maxStaticBitrate,
            "MaxStreamingBitrate": maxStaticBitrate,
            "DirectPlayProfiles": [
                ["Type": "Video", "Container": "mp4,m4v,mov", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3"],
            ],
            "TranscodingProfiles": [
                [
                    "Type": "Video",
                    "Container": "mp4",
                    "Protocol": "http",
                    "VideoCodec": "h264,hevc",
                    "AudioCodec": "aac",
                    "Context": "Static",
                    "BreakOnNonKeyFrames": false,
                ],
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
        guard let url = MediaBrowserURL.join(server: server, pathOrURLString: pathOrURLString) else {
            throw EmbyPlaybackError.invalidURL
        }
        return url
    }
}
