import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum EmbyLibrary {
    private static let requestFactory = MediaBrowserLibraryRequestFactory(dialect: .emby)

    /// `GET /Users/{UserId}/Views` — the user's libraries/views.
    public static func userViewsRequest(server: URL,
                                        token: String,
                                        identity: EmbyClientIdentity,
                                        userId: String) throws -> URLRequest {
        let shape = requestFactory.userViews(userId: userId)
        let url = try url(server: server, shape: shape)
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `GET /Users/{UserId}/Items` — the canonical Emby browse endpoint.
    public static func itemsRequest(server: URL,
                                    token: String,
                                    identity: EmbyClientIdentity,
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
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// Album artists for a music library (#111) — see the Jellyfin twin for why this uses
    /// `/Artists/AlbumArtists` rather than a `MusicArtist` items browse.
    public static func albumArtistsRequest(server: URL,
                                           token: String,
                                           identity: EmbyClientIdentity,
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
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// Ordered tracks of an audio playlist (#111) — see the Jellyfin twin for why this
    /// uses `/Playlists/{playlistId}/Items` (preserves the user's playlist order) rather
    /// than a `ParentId` items browse. `UserId` rides the query for per-user item data.
    public static func playlistItemsRequest(server: URL,
                                            token: String,
                                            identity: EmbyClientIdentity,
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
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `GET /Users/{UserId}/Items/Resume` — continue-watching rail.
    public static func resumeItemsRequest(server: URL,
                                          token: String,
                                          identity: EmbyClientIdentity,
                                          userId: String,
                                          parentId: String? = nil,
                                          startIndex: Int? = nil,
                                          limit: Int = 20) throws -> URLRequest {
        let shape = requestFactory.resumeItems(
            userId: userId,
            parentId: parentId,
            startIndex: startIndex,
            limit: limit,
            fields: fullItemFields
        )
        let url = try url(server: server, shape: shape)
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `GET /Shows/NextUp?UserId=..`
    public static func nextUpRequest(server: URL,
                                     token: String,
                                     identity: EmbyClientIdentity,
                                     userId: String,
                                     parentId: String? = nil,
                                     startIndex: Int? = nil,
                                     limit: Int = 20) throws -> URLRequest {
        let shape = requestFactory.nextUp(
            userId: userId,
            parentId: parentId,
            startIndex: startIndex,
            limit: limit,
            fields: fullItemFields
        )
        let url = try url(server: server, shape: shape)
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `GET /Users/{UserId}/Items/Latest`
    public static func latestItemsRequest(server: URL,
                                          token: String,
                                          identity: EmbyClientIdentity,
                                          userId: String,
                                          parentId: String? = nil,
                                          includeItemTypes: String = "Movie,Episode,Video",
                                          limit: Int = 20) throws -> URLRequest {
        let shape = requestFactory.latestItems(
            userId: userId,
            parentId: parentId,
            includeItemTypes: includeItemTypes,
            limit: limit,
            fields: fullItemFields
        )
        let url = try url(server: server, shape: shape)
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `GET /Users/{UserId}/Items/{itemId}`
    public static func itemRequest(server: URL,
                                   token: String,
                                   identity: EmbyClientIdentity,
                                   userId: String,
                                   itemId: String) throws -> URLRequest {
        let shape = requestFactory.item(userId: userId, itemId: itemId, fields: fullItemFields)
        let url = try url(server: server, shape: shape)
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `POST`/`DELETE /Users/{UserId}/PlayedItems/{itemId}`
    public static func markPlayedRequest(server: URL,
                                         token: String,
                                         identity: EmbyClientIdentity,
                                         userId: String,
                                         itemId: String,
                                         played: Bool) throws -> URLRequest {
        let shape = requestFactory.markPlayed(userId: userId, itemId: itemId, played: played)
        let url = try url(server: server, shape: shape)
        var req = authenticatedRequest(url: url, token: token, identity: identity, userId: userId)
        req.httpMethod = shape.httpMethod
        return req
    }

    /// `GET /Videos/{itemId}/stream.{container}?static=true&MediaSourceId=..&DeviceId=..`
    ///
    /// The static ORIGINAL download — byte-for-byte source file, no server encoding. Validated
    /// live: HTTP 206, range-RESUMABLE, with a real Content-Length. Only offer this when the
    /// negotiated download PlaybackInfo says `SupportsDirectPlay == true` AND the container is
    /// locally playable (mp4/m4v/mov) — otherwise the file won't open as an offline local asset.
    /// Auth rides in the header (token is NOT baked into the stored URL).
    public static func downloadOriginalRequest(server: URL,
                                               token: String,
                                               identity: EmbyClientIdentity,
                                               userId: String,
                                               itemId: String,
                                               mediaSourceId: String?,
                                               container: String?) throws -> URLRequest {
        let cleanContainer = (container ?? "mp4")
            .split(separator: ",").first.map(String.init) ?? "mp4"
        let ext = cleanContainer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let safeExt = ext.isEmpty ? "mp4" : ext
        var query = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "DeviceId", value: identity.deviceId),
        ]
        if let mediaSourceId, !mediaSourceId.isEmpty {
            query.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        let url = try url(server: server, path: "/Videos/\(itemId)/stream.\(safeExt)", queryItems: query)
        var req = authenticatedRequest(url: url, token: token, identity: identity, userId: userId)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        return req
    }

    /// `GET /Videos/{itemId}/{mediaSourceId}/Subtitles/{streamIndex}/Stream.{srt|vtt}`.
    ///
    /// Offline downloads cache external text subtitles as sidecars. Emby online playback burns
    /// selected subtitles into a reopened stream, but an optimized/converted offline MP4 should not
    /// rely on the server having embedded those subtitles into the converted file. Auth rides in
    /// headers; no token-bearing URL is persisted.
    public static func textSubtitleRequest(server: URL,
                                           token: String,
                                           identity: EmbyClientIdentity,
                                           userId: String,
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
        var req = authenticatedRequest(url: url, token: token, identity: identity, userId: userId)
        req.setValue(shape.accept, forHTTPHeaderField: "Accept")
        return req
    }

    /// Build the transcoded-download request from the server-minted `TranscodingUrl` returned by
    /// `EmbyPlayback.downloadPlaybackInfoRequest`.
    ///
    /// CRITICAL: you CANNOT hand-build this URL the way Jellyfin does. A hand-built
    /// `stream.mp4?static=false&videoCodec=h264…` returns HTTP 400 ("Value cannot be null.
    /// Parameter 'key'") because Emby requires a `PlaySessionId` minted by PlaybackInfo. So we
    /// take the server's `TranscodingUrl` verbatim (it already carries `api_key`, `PlaySessionId`,
    /// `MediaSourceId`, `DeviceId`) and only join it onto the server base URL. The token already
    /// rides in the `api_key` query, so no extra header is required. REDACT `api_key` in logs.
    /// NOT range-resumable (Emby transcoded streams report `accept-ranges: none`); restart on
    /// failure, and ALWAYS tear the encoder down with `activeEncodingStopRequest`.
    /// Build the single-file transcoded-download request as an EXPLICIT static `stream.mp4` URL
    /// with forced h264/aac, carrying the `PlaySessionId` minted by the download PlaybackInfo.
    ///
    /// WHY NOT the server-minted `TranscodingUrl`: for a transcode-required source Emby mints a
    /// codecless `/videos/{id}/stream` URL that ffmpeg treats as a stream-COPY remux — which fails
    /// ("Error starting ffmpeg", HTTP 500) when the source codecs (HEVC/DTS) can't be copied into
    /// mp4. Caught on-device by `DebugEmbyDownloadProbe`; the headless `LiveEmbyDownloadProbe`
    /// transcode-GET step now asserts this returns 200. Specifying `stream.mp4` + explicit
    /// `VideoCodec=h264&AudioCodec=aac&Static=false` forces a real re-encode. The minted
    /// `PlaySessionId` is what makes this hand-built URL valid (without it Emby returns HTTP 400).
    /// `api_key` rides in the query (mirrors Emby's own stream URLs); the token is NOT duplicated
    /// into the header path.
    public static func transcodedDownloadRequest(server: URL,
                                                 token: String,
                                                 identity: EmbyClientIdentity,
                                                 userId: String,
                                                 itemId: String,
                                                 mediaSourceId: String,
                                                 playSessionId: String,
                                                 videoBitrate: Int,
                                                 audioBitrate: Int,
                                                 audioStreamIndex: Int? = nil) throws -> URLRequest {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "Static", value: "false"),
            URLQueryItem(name: "Container", value: "mp4"),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "VideoBitrate", value: String(videoBitrate)),
            URLQueryItem(name: "AudioBitrate", value: String(audioBitrate)),
            URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "PlaySessionId", value: playSessionId),
            URLQueryItem(name: "DeviceId", value: identity.deviceId),
            URLQueryItem(name: "api_key", value: token),
        ]
        if let audioStreamIndex, audioStreamIndex >= 0 {
            query.append(URLQueryItem(name: "AudioStreamIndex", value: String(audioStreamIndex)))
        }
        let url = try EmbyPlayback.embyURL(server: server, path: "/videos/\(itemId)/stream.mp4", queryItems: query)
        var req = URLRequest(url: url)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(EmbyAuth.authorizationHeader(identity: identity, userId: userId, token: token),
                     forHTTPHeaderField: "Authorization")
        return req
    }

    /// #83 "Original quality (compatible)" remux download request (Emby).
    ///
    /// Like `transcodedDownloadRequest` it is an EXPLICIT `stream.mp4` with the PlaybackInfo-minted
    /// `PlaySessionId` (required — Emby returns HTTP 400 without it), but it ALLOWS video stream-copy
    /// by listing the source's real `VideoCodec` alongside `AllowVideoStreamCopy=true` +
    /// `EnableAutoStreamCopy=true`, so the original video bytes are preserved. Audio is copied when
    /// `copyAudio` (aac/ac3/eac3), otherwise transcoded to AAC.
    ///
    /// CAVEAT (research B): for HEVC/DTS, copying into mp4 can fail server-side on some Emby
    /// versions; the download is still gated by the client AVPlayer probe + (for HEVC) the
    /// `hev1`→`hvc1` tag fixup, and the app falls back to a forced transcode if it fails.
    /// NOT range-resumable; restart on failure; ALWAYS tear the encoder down with
    /// `activeEncodingStopRequest`. `api_key` rides in the query; REDACT it in logs.
    public static func compatibleRemuxDownloadRequest(server: URL,
                                                      token: String,
                                                      identity: EmbyClientIdentity,
                                                      userId: String,
                                                      itemId: String,
                                                      mediaSourceId: String,
                                                      playSessionId: String,
                                                      videoCodec: String,
                                                      audioCodec: String? = nil,
                                                      copyAudio: Bool,
                                                      audioBitrate: Int,
                                                      audioStreamIndex: Int? = nil) throws -> URLRequest {
        let videoCodecList = videoCodec == "h264" ? "h264" : "\(videoCodec),h264"
        // Stream copy requires the source audio codec in the requested list (see
        // DownloadAudioCodecList) — `AllowAudioStreamCopy` alone never copied ac3/eac3.
        let audioCodecList = DownloadAudioCodecList.forRemux(sourceAudioCodec: audioCodec,
                                                             copyAudio: copyAudio)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "Static", value: "false"),
            URLQueryItem(name: "Container", value: "mp4"),
            URLQueryItem(name: "VideoCodec", value: videoCodecList),
            URLQueryItem(name: "AudioCodec", value: audioCodecList),
            URLQueryItem(name: "AudioBitrate", value: String(audioBitrate)),
            URLQueryItem(name: "AllowVideoStreamCopy", value: "true"),
            URLQueryItem(name: "AllowAudioStreamCopy", value: copyAudio ? "true" : "false"),
            URLQueryItem(name: "EnableAutoStreamCopy", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "PlaySessionId", value: playSessionId),
            URLQueryItem(name: "DeviceId", value: identity.deviceId),
            URLQueryItem(name: "api_key", value: token),
        ]
        if let audioStreamIndex, audioStreamIndex >= 0 {
            query.append(URLQueryItem(name: "AudioStreamIndex", value: String(audioStreamIndex)))
        }
        let url = try EmbyPlayback.embyURL(server: server, path: "/videos/\(itemId)/stream.mp4", queryItems: query)
        var req = URLRequest(url: url)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(EmbyAuth.authorizationHeader(identity: identity, userId: userId, token: token),
                     forHTTPHeaderField: "Authorization")
        return req
    }

    /// Direct-play audio stream URL for music playback (#111) — the Emby twin of
    /// ``JellyfinLibrary/audioStreamURL(server:identity:userId:itemId:maxStreamingBitrate:)``.
    /// Targets `/Audio/{itemId}/universal`, which streams the original bytes for a
    /// container in the allowlist within `MaxStreamingBitrate` and otherwise transcodes
    /// to HLS/AAC (AVPlayer plays either). Token is NOT in the URL — auth rides in the
    /// header via ``authenticatedRequest(url:token:identity:userId:)``.
    public static func audioStreamURL(server: URL,
                                      identity: EmbyClientIdentity,
                                      userId: String,
                                      itemId: String,
                                      maxStreamingBitrate: Int = 140_000_000) throws -> URL {
        let shape = requestFactory.audioStream(
            userId: userId,
            deviceId: identity.deviceId,
            itemId: itemId,
            maxStreamingBitrate: maxStreamingBitrate,
            containers: JellyfinLibrary.musicDirectPlayContainers
        )
        return try url(server: server, shape: shape)
    }

    /// Bare image URL — token is NOT baked in (mirror Jellyfin's no-token-in-stored-URL
    /// rule). The caller attaches the Emby auth header (or `api_key` query) on the live
    /// request.
    public static func imageURL(server: URL,
                                itemId: String,
                                imageType: EmbyImageType,
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

    /// `DELETE /Videos/ActiveEncodings?DeviceId=..&PlaySessionId=..`
    ///
    /// CLEANUP INVARIANT: `/Sessions/Playing/Stopped` does NOT terminate the encoder.
    /// For transcode/HLS sources this must be called on stop. NOTE: this admin endpoint
    /// uses uppercase `/Videos/`, distinct from the lowercase `/videos/` playable paths.
    public static func activeEncodingStopRequest(server: URL,
                                                 token: String,
                                                 identity: EmbyClientIdentity,
                                                 userId: String,
                                                 deviceId: String,
                                                 playSessionId: String) throws -> URLRequest {
        let shape = requestFactory.activeEncodingStop(
            deviceId: deviceId,
            playSessionId: playSessionId
        )
        let url = try url(server: server, shape: shape)
        var req = authenticatedRequest(url: url, token: token, identity: identity, userId: userId)
        req.httpMethod = shape.httpMethod
        return req
    }

    public static func authenticatedRequest(url: URL,
                                            token: String,
                                            identity: EmbyClientIdentity,
                                            userId: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: userId, token: token)
        return req
    }

    private static func get(url: URL,
                            token: String,
                            identity: EmbyClientIdentity,
                            userId: String? = nil) -> URLRequest {
        var req = authenticatedRequest(url: url, token: token, identity: identity, userId: userId)
        req.httpMethod = "GET"
        return req
    }

    public static let gridItemFields = MediaBrowserLibraryFields.gridItem
    public static let fullItemFields = MediaBrowserLibraryFields.fullItem

    private static func url(server: URL, shape: MediaBrowserLibraryRequestShape) throws -> URL {
        try url(server: server, path: shape.path, queryItems: shape.queryItems)
    }

    private static func url(server: URL, path: String, queryItems: [URLQueryItem]) throws -> URL {
        let base = try EmbyPlayback.embyURL(server: server, path: path)
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw EmbyPlaybackError.invalidURL
        }
        comps.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = comps.url else { throw EmbyPlaybackError.invalidURL }
        return url
    }
}
