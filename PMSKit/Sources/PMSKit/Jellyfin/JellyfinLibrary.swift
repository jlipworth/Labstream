import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum JellyfinLibrary {
    private static let requestFactory = MediaBrowserLibraryRequestFactory(dialect: .jellyfin)

    public static func userViewsRequest(server: URL,
                                        token: String,
                                        identity: JellyfinClientIdentity,
                                        userId: String) throws -> URLRequest {
        let shape = requestFactory.userViews(userId: userId)
        let url = try url(server: server, shape: shape)
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
        let shape = requestFactory.items(
            userId: userId,
            parentId: parentId,
            recursive: recursive,
            startIndex: startIndex,
            limit: limit,
            searchTerm: searchTerm,
            nameStartsWith: nameStartsWith,
            sortBy: sortBy,
            sortOrder: sortOrder,
            includeItemTypes: includeItemTypes,
            fields: fields,
            albumArtistIds: albumArtistIds,
            artistIds: artistIds,
            filters: filters
        )
        let url = try url(server: server, shape: shape)
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
        let shape = requestFactory.albumArtists(
            userId: userId,
            parentId: parentId,
            startIndex: startIndex,
            limit: limit,
            nameStartsWith: nameStartsWith,
            sortBy: sortBy,
            sortOrder: sortOrder,
            fields: fields
        )
        let url = try url(server: server, shape: shape)
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
        let shape = requestFactory.playlistItems(
            userId: userId,
            playlistId: playlistId,
            startIndex: startIndex,
            limit: limit,
            fields: fields
        )
        let url = try url(server: server, shape: shape)
        return get(url: url, token: token, identity: identity)
    }

    public static func resumeItemsRequest(server: URL,
                                          token: String,
                                          identity: JellyfinClientIdentity,
                                          userId: String,
                                          parentId: String? = nil,
                                          startIndex: Int? = nil,
                                          limit: Int = 20) throws -> URLRequest {
        let shape = requestFactory.resumeItems(
            userId: userId,
            parentId: parentId,
            startIndex: startIndex,
            limit: limit,
            fields: itemFields
        )
        let url = try url(server: server, shape: shape)
        return get(url: url, token: token, identity: identity)
    }

    public static func nextUpRequest(server: URL,
                                     token: String,
                                     identity: JellyfinClientIdentity,
                                     userId: String,
                                     parentId: String? = nil,
                                     startIndex: Int? = nil,
                                     limit: Int = 20) throws -> URLRequest {
        let shape = requestFactory.nextUp(
            userId: userId,
            parentId: parentId,
            startIndex: startIndex,
            limit: limit,
            fields: itemFields
        )
        let url = try url(server: server, shape: shape)
        return get(url: url, token: token, identity: identity)
    }

    public static func latestItemsRequest(server: URL,
                                          token: String,
                                          identity: JellyfinClientIdentity,
                                          userId: String,
                                          parentId: String? = nil,
                                          includeItemTypes: String = "Movie,Episode,Video",
                                          limit: Int = 20) throws -> URLRequest {
        let shape = requestFactory.latestItems(
            userId: userId,
            parentId: parentId,
            includeItemTypes: includeItemTypes,
            limit: limit,
            fields: itemFields
        )
        let url = try url(server: server, shape: shape)
        return get(url: url, token: token, identity: identity)
    }

    public static func itemRequest(server: URL,
                                   token: String,
                                   identity: JellyfinClientIdentity,
                                   userId: String,
                                   itemId: String) throws -> URLRequest {
        let shape = requestFactory.item(userId: userId, itemId: itemId, fields: fullItemFields)
        let url = try url(server: server, shape: shape)
        return get(url: url, token: token, identity: identity)
    }

    public static func markPlayedRequest(server: URL,
                                         token: String,
                                         identity: JellyfinClientIdentity,
                                         userId: String,
                                         itemId: String,
                                         played: Bool) throws -> URLRequest {
        let shape = requestFactory.markPlayed(userId: userId, itemId: itemId, played: played)
        let url = try url(server: server, shape: shape)
        var req = authenticatedRequest(url: url, token: token, identity: identity)
        req.httpMethod = shape.httpMethod
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
        let shape = requestFactory.textSubtitle(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            streamIndex: streamIndex,
            format: format
        )
        let url = try url(server: server, shape: shape)
        var req = authenticatedRequest(url: url, token: token, identity: identity)
        req.setValue(shape.accept, forHTTPHeaderField: "Accept")
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
        let shape = requestFactory.audioStream(
            userId: userId,
            deviceId: identity.deviceId,
            itemId: itemId,
            maxStreamingBitrate: maxStreamingBitrate,
            containers: MediaBrowserAudioStreamFacts.directPlayContainers
        )
        return try url(server: server, shape: shape)
    }

    public static func imageURL(server: URL,
                                itemId: String,
                                imageType: JellyfinImageType,
                                tag: String?,
                                width: Int? = nil,
                                height: Int? = nil) throws -> URL {
        let shape = requestFactory.image(
            itemId: itemId,
            imageType: imageType.rawValue,
            tag: tag,
            width: width,
            height: height
        )
        return try url(server: server, shape: shape)
    }

    public static func chapterImageURL(server: URL,
                                       itemId: String,
                                       chapterIndex: Int,
                                       tag: String?,
                                       width: Int? = nil,
                                       height: Int? = nil) throws -> URL {
        let shape = requestFactory.chapterImage(
            itemId: itemId,
            chapterIndex: chapterIndex,
            tag: tag,
            width: width,
            height: height
        )
        return try url(server: server, shape: shape)
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
        let shape = requestFactory.activeEncodingStop(
            deviceId: deviceId,
            playSessionId: playSessionId
        )
        let url = try url(server: server, shape: shape)
        var req = authenticatedRequest(url: url, token: token, identity: identity)
        req.httpMethod = shape.httpMethod
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

    public static let gridItemFields = MediaBrowserLibraryFields.gridItem
    public static let fullItemFields = MediaBrowserLibraryFields.fullItem
    private static let itemFields = fullItemFields

    private static func url(server: URL, shape: MediaBrowserLibraryRequestShape) throws -> URL {
        try url(server: server, path: shape.path, queryItems: shape.queryItems)
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
