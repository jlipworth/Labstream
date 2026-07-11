import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct JellyfinAuthenticationResult: Decodable, Sendable, Equatable {
    public let user: JellyfinAuthenticatedUser?
    public let accessToken: String?
    public let serverId: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

public struct JellyfinAuthenticatedUser: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

public enum JellyfinLibrary {
    private static let dialect = MediaBrowserLibraryQueryDialect.jellyfin

    public static func userViewsRequest(server: URL,
                                        token: String,
                                        identity: JellyfinClientIdentity,
                                        userId: String) throws -> URLRequest {
        let url = try url(server: server, path: dialect.path(.userViews(userId: userId)), queryItems: [
            dialect.queryItem(.userId, value: userId),
            dialect.queryItem(.includeExternalContent, value: "false"),
        ])
        return get(url: url, token: token, identity: identity)
    }

    public static func itemsRequest(server: URL,
                                    token: String,
                                    identity: JellyfinClientIdentity,
                                    userId: String,
                                    parentId: String? = nil,
                                    recursive: Bool = false,
                                    startIndex: Int? = nil,
                                    limit: Int? = nil,
                                    searchTerm: String? = nil,
                                    nameStartsWith: String? = nil,
                                    sortBy: String = "SortName",
                                    sortOrder: String = "Ascending",
                                    includeItemTypes: String = "Movie,Series,Season,Episode,Video",
                                    fields: String = fullItemFields,
                                    albumArtistIds: String? = nil,
                                    artistIds: String? = nil,
                                    filters: [String] = []) throws -> URLRequest {
        var query = baseItemsQuery(userId: userId, fields: fields)
        if let parentId { query.append(dialect.queryItem(.parentId, value: parentId)) }
        query.append(dialect.queryItem(.recursive, value: recursive ? "true" : "false"))
        if let startIndex { query.append(dialect.queryItem(.startIndex, value: String(startIndex))) }
        if let limit { query.append(dialect.queryItem(.limit, value: String(limit))) }
        if let searchTerm, !searchTerm.isEmpty {
            query.append(dialect.queryItem(.searchTerm, value: searchTerm))
        }
        if let nameStartsWith, !nameStartsWith.isEmpty {
            query.append(dialect.queryItem(.nameStartsWith, value: nameStartsWith))
        }
        // An album-artist entity is a tag aggregate, not a folder, so its albums/tracks are
        // reached by these filters rather than `parentId` (#111).
        if let albumArtistIds, !albumArtistIds.isEmpty {
            query.append(dialect.queryItem(.albumArtistIds, value: albumArtistIds))
        }
        if let artistIds, !artistIds.isEmpty {
            query.append(dialect.queryItem(.artistIds, value: artistIds))
        }
        replaceQueryItem(named: dialect.queryName(.includeItemTypes), with: includeItemTypes, in: &query)
        if !filters.isEmpty { query.append(dialect.queryItem(.filters, value: filters.joined(separator: ","))) }
        replaceQueryItem(named: dialect.queryName(.sortBy), with: sortBy, in: &query)
        replaceQueryItem(named: dialect.queryName(.sortOrder), with: sortOrder, in: &query)
        let url = try url(server: server, path: dialect.path(.items(userId: userId)), queryItems: query)
        return get(url: url, token: token, identity: identity)
    }

    /// Album artists for a music library (#111). A plain `/Items?IncludeItemTypes=MusicArtist`
    /// browse returns only the folder-derived artist stubs Jellyfin synthesizes for loose
    /// release folders (their names are whole release-folder strings, and they carry no art);
    /// the dedicated `/Artists/AlbumArtists` endpoint returns the real, tag-aggregated
    /// album-artist entities every official client lists. Same `{Items,TotalRecordCount}`
    /// envelope, so it decodes as a normal items page.
    public static func albumArtistsRequest(server: URL,
                                           token: String,
                                           identity: JellyfinClientIdentity,
                                           userId: String,
                                           parentId: String?,
                                           startIndex: Int? = nil,
                                           limit: Int? = nil,
                                           nameStartsWith: String? = nil,
                                           sortBy: String = "SortName",
                                           sortOrder: String = "Ascending",
                                           fields: String = gridItemFields) throws -> URLRequest {
        var query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableImages", value: "true"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortOrder", value: sortOrder),
        ]
        if let parentId { query.append(URLQueryItem(name: "parentId", value: parentId)) }
        if let startIndex { query.append(URLQueryItem(name: "startIndex", value: String(startIndex))) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        // The A–Z rail probes each letter's album-artist count with a `NameStartsWith=X`,
        // `Limit=1` request and reads the envelope's `TotalRecordCount` (#111).
        if let nameStartsWith, !nameStartsWith.isEmpty {
            query.append(URLQueryItem(name: "nameStartsWith", value: nameStartsWith))
        }
        let url = try url(server: server, path: "/Artists/AlbumArtists", queryItems: query)
        return get(url: url, token: token, identity: identity)
    }

    /// Ordered tracks of an audio playlist (#111), via `/Playlists/{playlistId}/Items`.
    /// Unlike a `ParentId` items browse (which sorts by the requested key), this endpoint
    /// returns the playlist's items in the user's own PLAYLIST ORDER — the order matters,
    /// so callers must not re-sort. Same `{Items,TotalRecordCount}` envelope as `/Items`,
    /// so it decodes as a normal items page.
    public static func playlistItemsRequest(server: URL,
                                            token: String,
                                            identity: JellyfinClientIdentity,
                                            userId: String,
                                            playlistId: String,
                                            startIndex: Int? = nil,
                                            limit: Int? = nil,
                                            fields: String = fullItemFields) throws -> URLRequest {
        var query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableImages", value: "true"),
        ]
        if let startIndex { query.append(URLQueryItem(name: "startIndex", value: String(startIndex))) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let url = try url(server: server, path: "/Playlists/\(playlistId)/Items", queryItems: query)
        return get(url: url, token: token, identity: identity)
    }

    public static func resumeItemsRequest(server: URL,
                                          token: String,
                                          identity: JellyfinClientIdentity,
                                          userId: String,
                                          parentId: String? = nil,
                                          startIndex: Int? = nil,
                                          limit: Int = 20) throws -> URLRequest {
        var query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Episode,Video"),
            URLQueryItem(name: "fields", value: itemFields),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableImages", value: "true"),
            URLQueryItem(name: "excludeActiveSessions", value: "false"),
        ]
        if let parentId { query.append(URLQueryItem(name: "parentId", value: parentId)) }
        if let startIndex { query.append(URLQueryItem(name: "startIndex", value: String(startIndex))) }
        let url = try url(server: server, path: "/UserItems/Resume", queryItems: query)
        return get(url: url, token: token, identity: identity)
    }

    public static func nextUpRequest(server: URL,
                                     token: String,
                                     identity: JellyfinClientIdentity,
                                     userId: String,
                                     parentId: String? = nil,
                                     startIndex: Int? = nil,
                                     limit: Int = 20) throws -> URLRequest {
        var query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: itemFields),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableImages", value: "true"),
            URLQueryItem(name: "enableResumable", value: "true"),
        ]
        if let parentId { query.append(URLQueryItem(name: "parentId", value: parentId)) }
        if let startIndex { query.append(URLQueryItem(name: "startIndex", value: String(startIndex))) }
        let url = try url(server: server, path: "/Shows/NextUp", queryItems: query)
        return get(url: url, token: token, identity: identity)
    }

    public static func latestItemsRequest(server: URL,
                                          token: String,
                                          identity: JellyfinClientIdentity,
                                          userId: String,
                                          parentId: String? = nil,
                                          includeItemTypes: String = "Movie,Episode,Video",
                                          limit: Int = 20) throws -> URLRequest {
        var query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "includeItemTypes", value: includeItemTypes),
            URLQueryItem(name: "fields", value: itemFields),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableImages", value: "true"),
            URLQueryItem(name: "groupItems", value: "false"),
        ]
        if let parentId { query.append(URLQueryItem(name: "parentId", value: parentId)) }
        let url = try url(server: server, path: "/Items/Latest", queryItems: query)
        return get(url: url, token: token, identity: identity)
    }

    public static func itemRequest(server: URL,
                                   token: String,
                                   identity: JellyfinClientIdentity,
                                   userId: String,
                                   itemId: String) throws -> URLRequest {
        let url = try url(server: server, path: "/Users/\(userId)/Items/\(itemId)", queryItems: [
            URLQueryItem(name: "fields", value: fullItemFields),
        ])
        return get(url: url, token: token, identity: identity)
    }

    public static func markPlayedRequest(server: URL,
                                         token: String,
                                         identity: JellyfinClientIdentity,
                                         userId: String,
                                         itemId: String,
                                         played: Bool) throws -> URLRequest {
        let url = try url(server: server,
                          path: "/Users/\(userId)/PlayedItems/\(itemId)",
                          queryItems: [])
        var req = authenticatedRequest(url: url, token: token, identity: identity)
        req.httpMethod = played ? "POST" : "DELETE"
        return req
    }

    public static func downloadRequest(server: URL,
                                       token: String,
                                       identity: JellyfinClientIdentity,
                                       itemId: String,
                                       mediaSourceId: String?,
                                       container: String?) throws -> URLRequest {
        let cleanContainer = (container ?? "mp4")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let ext = cleanContainer.isEmpty ? "mp4" : cleanContainer
        let url = try JellyfinPlayback.jellyfinURL(server: server,
                                                  path: "/Videos/\(itemId)/stream.\(ext)")
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw JellyfinPlaybackError.invalidURL
        }
        var query = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "deviceId", value: identity.deviceId),
        ]
        if let mediaSourceId, !mediaSourceId.isEmpty {
            query.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceId))
        }
        comps.queryItems = query
        guard let built = comps.url else { throw JellyfinPlaybackError.invalidURL }
        var req = authenticatedRequest(url: built, token: token, identity: identity)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        return req
    }

    public static func textSubtitleRequest(server: URL,
                                           token: String,
                                           identity: JellyfinClientIdentity,
                                           itemId: String,
                                           mediaSourceId: String,
                                           streamIndex: Int,
                                           format: String) throws -> URLRequest {
        let cleanFormat = format.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let ext = ["srt", "vtt"].contains(cleanFormat) ? cleanFormat : "vtt"
        let url = try JellyfinPlayback.jellyfinURL(
            server: server,
            path: "/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/Stream.\(ext)"
        )
        var req = authenticatedRequest(url: url, token: token, identity: identity)
        req.setValue(ext == "srt" ? "application/x-subrip,text/plain,*/*" : "text/vtt,text/plain,*/*",
                     forHTTPHeaderField: "Accept")
        return req
    }

    public static func transcodedDownloadRequest(server: URL,
                                                 token: String,
                                                 identity: JellyfinClientIdentity,
                                                 itemId: String,
                                                 mediaSourceId: String?,
                                                 playSessionId: String? = nil,
                                                 maxVideoBitrate: Int,
                                                 maxWidth: Int?,
                                                 maxHeight: Int?,
                                                 audioStreamIndex: Int? = nil) throws -> URLRequest {
        let url = try JellyfinPlayback.jellyfinURL(server: server, path: "/Videos/\(itemId)/stream.mp4")
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw JellyfinPlaybackError.invalidURL
        }
        var query = [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "container", value: "mp4"),
            URLQueryItem(name: "videoCodec", value: "h264"),
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "videoBitRate", value: String(maxVideoBitrate)),
            URLQueryItem(name: "audioBitRate", value: "192000"),
            URLQueryItem(name: "maxAudioChannels", value: "6"),
            URLQueryItem(name: "allowVideoStreamCopy", value: "false"),
            URLQueryItem(name: "allowAudioStreamCopy", value: "false"),
            URLQueryItem(name: "enableAutoStreamCopy", value: "false"),
            URLQueryItem(name: "breakOnNonKeyFrames", value: "false"),
            URLQueryItem(name: "deviceId", value: identity.deviceId),
        ]
        if let playSessionId, !playSessionId.isEmpty {
            query.append(URLQueryItem(name: "playSessionId", value: playSessionId))
        }
        if let mediaSourceId, !mediaSourceId.isEmpty {
            query.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceId))
        }
        if let audioStreamIndex, audioStreamIndex >= 0 {
            query.append(URLQueryItem(name: "AudioStreamIndex", value: String(audioStreamIndex)))
        }
        if let maxWidth {
            query.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        if let maxHeight {
            query.append(URLQueryItem(name: "maxHeight", value: String(maxHeight)))
        }
        comps.queryItems = query
        guard let built = comps.url else { throw JellyfinPlaybackError.invalidURL }
        var req = authenticatedRequest(url: built, token: token, identity: identity)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        return req
    }

    /// #83 "Original quality (compatible)" remux download request.
    ///
    /// Asks Jellyfin to stream-COPY the video into an MP4 container (preserving original video
    /// quality) and copy or transcode-to-AAC the audio. The crux is `videoCodec` listing the
    /// SOURCE's real video codec alongside `allowVideoStreamCopy=true` + `enableAutoStreamCopy=true`
    /// — that combination is what makes the server emit `-c:v copy` instead of a re-encode (gated
    /// server-side by `EncodingHelper.CanStreamCopyVideo`; the server still falls back to a real
    /// transcode if copy is refused for interlaced/anamorphic/HDR/level reasons).
    ///
    /// NOT range-resumable (a remux stream reports `Accept-Ranges: none`, no Content-Length), so the
    /// caller treats it as forward-only and restarts on failure. For HEVC sources the COMPLETED file
    /// needs a `hev1`→`hvc1` MP4 tag fixup before AVFoundation will decode it (Jellyfin's
    /// progressive mp4 path does not force `hvc1`).
    public static func compatibleRemuxDownloadRequest(server: URL,
                                                      token: String,
                                                      identity: JellyfinClientIdentity,
                                                      itemId: String,
                                                      mediaSourceId: String?,
                                                      videoCodec: String,
                                                      audioCodec: String? = nil,
                                                      copyAudio: Bool,
                                                      playSessionId: String? = nil,
                                                      audioStreamIndex: Int? = nil) throws -> URLRequest {
        let url = try JellyfinPlayback.jellyfinURL(server: server, path: "/Videos/\(itemId)/stream.mp4")
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw JellyfinPlaybackError.invalidURL
        }
        // List the source's real video codec so the server is allowed to copy it; keep h264 in the
        // list as the fallback re-encode target if copy is refused.
        let videoCodecList = videoCodec == "h264" ? "h264" : "\(videoCodec),h264"
        // Same for audio: stream-copy only engages when the SOURCE codec is in the requested
        // list (aac alone silently re-encoded ac3/eac3 sources to AAC 192k while the UI
        // promised a copy). aac stays in the list as the re-encode target if copy is refused.
        // No maxAudioChannels cap here — capping to 6 forced a transcode (and 5.1 downmix) of
        // copy-eligible 7.1 tracks, contradicting the lane's "original quality" promise.
        let audioCodecList = DownloadAudioCodecList.forRemux(sourceAudioCodec: audioCodec,
                                                             copyAudio: copyAudio)
        var query = [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "container", value: "mp4"),
            URLQueryItem(name: "videoCodec", value: videoCodecList),
            URLQueryItem(name: "audioCodec", value: audioCodecList),
            URLQueryItem(name: "audioBitRate", value: "192000"),
            URLQueryItem(name: "allowVideoStreamCopy", value: "true"),
            URLQueryItem(name: "allowAudioStreamCopy", value: copyAudio ? "true" : "false"),
            URLQueryItem(name: "enableAutoStreamCopy", value: "true"),
            URLQueryItem(name: "breakOnNonKeyFrames", value: "false"),
            URLQueryItem(name: "deviceId", value: identity.deviceId),
        ]
        if let playSessionId, !playSessionId.isEmpty {
            query.append(URLQueryItem(name: "playSessionId", value: playSessionId))
        }
        if let mediaSourceId, !mediaSourceId.isEmpty {
            query.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceId))
        }
        if let audioStreamIndex, audioStreamIndex >= 0 {
            query.append(URLQueryItem(name: "AudioStreamIndex", value: String(audioStreamIndex)))
        }
        comps.queryItems = query
        guard let built = comps.url else { throw JellyfinPlaybackError.invalidURL }
        var req = authenticatedRequest(url: built, token: token, identity: identity)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        return req
    }

    /// Direct-play audio stream URL for music playback (#111), built against the
    /// `/Audio/{itemId}/universal` endpoint the official clients use. `universal`
    /// negotiates per-source: it streams the original bytes when the container is in
    /// the `Container` allowlist and within `MaxStreamingBitrate`, otherwise transcodes
    /// to an HLS/AAC stream — AVPlayer plays either form. A generous default bitrate keeps
    /// lossless sources direct-playing; callers can clamp it to honor a quality cap.
    ///
    /// The token is deliberately NOT baked into the URL: music playback (like the video
    /// path) carries auth in the `AVURLAssetHTTPHeaderFieldsKey` header via
    /// ``authenticatedRequest(url:token:identity:)``, so no secret lingers in the
    /// app-visible stream URL.
    public static func audioStreamURL(server: URL,
                                      identity: JellyfinClientIdentity,
                                      userId: String,
                                      itemId: String,
                                      maxStreamingBitrate: Int = 140_000_000) throws -> URL {
        try url(server: server, path: "/Audio/\(itemId)/universal", queryItems: [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "DeviceId", value: identity.deviceId),
            URLQueryItem(name: "MaxStreamingBitrate", value: String(maxStreamingBitrate)),
            URLQueryItem(name: "Container", value: musicDirectPlayContainers),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
        ])
    }

    /// Containers AVPlayer decodes natively — passed to the `universal` endpoint so a
    /// matching source direct-plays and only the exotic ones transcode. Shared with Emby.
    static let musicDirectPlayContainers = "mp3,aac,m4a,m4b,flac,alac,wav,ogg,oga,opus,webma"

    public static func imageURL(server: URL,
                                itemId: String,
                                imageType: JellyfinImageType,
                                tag: String?,
                                width: Int? = nil,
                                height: Int? = nil) throws -> URL {
        var query: [URLQueryItem] = []
        if let tag, !tag.isEmpty { query.append(URLQueryItem(name: "tag", value: tag)) }
        if let width { query.append(URLQueryItem(name: "width", value: String(width))) }
        if let height { query.append(URLQueryItem(name: "height", value: String(height))) }
        return try url(server: server, path: "/Items/\(itemId)/Images/\(imageType.rawValue)", queryItems: query)
    }

    public static func chapterImageURL(server: URL,
                                       itemId: String,
                                       chapterIndex: Int,
                                       tag: String?,
                                       width: Int? = nil,
                                       height: Int? = nil) throws -> URL {
        var query: [URLQueryItem] = []
        if let tag, !tag.isEmpty { query.append(URLQueryItem(name: "tag", value: tag)) }
        if let width { query.append(URLQueryItem(name: "fillWidth", value: String(width))) }
        if let height { query.append(URLQueryItem(name: "fillHeight", value: String(height))) }
        return try url(server: server, path: "/Items/\(itemId)/Images/Chapter/\(chapterIndex)", queryItems: query)
    }


    public static func trickPlayPlaylistRequest(server: URL,
                                                token: String,
                                                identity: JellyfinClientIdentity,
                                                itemId: String,
                                                mediaSourceId: String,
                                                width: Int = 320) throws -> URLRequest {
        let url = try url(server: server,
                          path: "/Videos/\(itemId)/Trickplay/\(width)/tiles.m3u8",
                          queryItems: [URLQueryItem(name: "MediaSourceId", value: mediaSourceId)])
        var req = authenticatedRequest(url: url, token: token, identity: identity)
        req.setValue("application/x-mpegURL,application/vnd.apple.mpegurl,*/*", forHTTPHeaderField: "Accept")
        return req
    }

    public static func trickPlayTileRequest(server: URL,
                                            token: String,
                                            identity: JellyfinClientIdentity,
                                            itemId: String,
                                            mediaSourceId: String,
                                            width: Int = 320,
                                            tileURI: String) throws -> URLRequest {
        let basePath = "/Videos/\(itemId)/Trickplay/\(width)/"
        let rawURLString: String
        if let absolute = URL(string: tileURI), absolute.scheme != nil {
            rawURLString = absolute.absoluteString
        } else {
            rawURLString = basePath + tileURI
        }
        guard let rawURL = MediaBrowserURL.joinTrustedServerURL(server: server, pathOrURLString: rawURLString) else {
            throw JellyfinPlaybackError.invalidURL
        }
        guard var comps = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) else {
            throw JellyfinPlaybackError.invalidURL
        }
        // Jellyfin playlists often include ApiKey in tile URIs. Drop it and use the normal
        // MediaBrowser auth header instead so secrets do not linger in app-visible URLs.
        var query = comps.queryItems ?? []
        query.removeAll { $0.name.caseInsensitiveCompare("ApiKey") == .orderedSame }
        if !query.contains(where: { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame }) {
            query.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw JellyfinPlaybackError.invalidURL }
        var req = authenticatedRequest(url: url, token: token, identity: identity)
        req.setValue("image/jpeg,*/*", forHTTPHeaderField: "Accept")
        return req
    }

    public static func activeEncodingStopRequest(server: URL,
                                                 token: String,
                                                 identity: JellyfinClientIdentity,
                                                 deviceId: String,
                                                 playSessionId: String) throws -> URLRequest {
        let url = try url(server: server, path: "/Videos/ActiveEncodings", queryItems: [
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "playSessionId", value: playSessionId),
        ])
        var req = authenticatedRequest(url: url, token: token, identity: identity)
        req.httpMethod = "DELETE"
        return req
    }

    public static func authenticatedRequest(url: URL, token: String, identity: JellyfinClientIdentity) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(JellyfinAuth.authorizationHeader(identity: identity, token: token), forHTTPHeaderField: "Authorization")
        return req
    }

    private static func get(url: URL, token: String, identity: JellyfinClientIdentity) -> URLRequest {
        var req = authenticatedRequest(url: url, token: token, identity: identity)
        req.httpMethod = "GET"
        return req
    }

    private static func baseItemsQuery(userId: String, fields: String = fullItemFields) -> [URLQueryItem] {
        [
            dialect.queryItem(.userId, value: userId),
            dialect.queryItem(.includeItemTypes, value: "Movie,Series,Season,Episode,Video"),
            dialect.queryItem(.fields, value: fields),
            dialect.queryItem(.enableUserData, value: "true"),
            dialect.queryItem(.sortBy, value: "SortName"),
            dialect.queryItem(.sortOrder, value: "Ascending"),
        ]
    }

    public static let gridItemFields = MediaBrowserLibraryFields.gridItem
    public static let fullItemFields = MediaBrowserLibraryFields.fullItem
    private static let itemFields = fullItemFields

    private static func replaceQueryItem(named name: String, with value: String, in query: inout [URLQueryItem]) {
        query.removeAll { $0.name == name }
        query.append(URLQueryItem(name: name, value: value))
    }

    private static func url(server: URL, path: String, queryItems: [URLQueryItem]) throws -> URL {
        let base = try JellyfinPlayback.jellyfinURL(server: server, path: path)
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw JellyfinPlaybackError.invalidURL
        }
        comps.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = comps.url else { throw JellyfinPlaybackError.invalidURL }
        return url
    }
}
