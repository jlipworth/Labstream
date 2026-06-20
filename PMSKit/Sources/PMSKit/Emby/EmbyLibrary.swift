import Foundation

public enum EmbyLibrary {
    /// `GET /Users/{UserId}/Views` — the user's libraries/views.
    public static func userViewsRequest(server: URL,
                                        token: String,
                                        identity: EmbyClientIdentity,
                                        userId: String) throws -> URLRequest {
        let url = try url(server: server, path: "/Users/\(userId)/Views", queryItems: [
            URLQueryItem(name: "IncludeExternalContent", value: "false"),
        ])
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
                                    includeItemTypes: String = "Movie,Series,Season,Episode",
                                    fields: String = fullItemFields,
                                    filters: [String] = []) throws -> URLRequest {
        var query = baseItemsQuery(fields: fields)
        if let parentId { query.append(URLQueryItem(name: "ParentId", value: parentId)) }
        query.append(URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"))
        if let startIndex { query.append(URLQueryItem(name: "StartIndex", value: String(startIndex))) }
        if let limit { query.append(URLQueryItem(name: "Limit", value: String(limit))) }
        if let searchTerm, !searchTerm.isEmpty {
            query.append(URLQueryItem(name: "SearchTerm", value: searchTerm))
        }
        if let nameStartsWith, !nameStartsWith.isEmpty {
            query.append(URLQueryItem(name: "NameStartsWith", value: nameStartsWith))
        }
        replaceQueryItem(named: "IncludeItemTypes", with: includeItemTypes, in: &query)
        if !filters.isEmpty { query.append(URLQueryItem(name: "Filters", value: filters.joined(separator: ","))) }
        replaceQueryItem(named: "SortBy", with: sortBy, in: &query)
        replaceQueryItem(named: "SortOrder", with: sortOrder, in: &query)
        let url = try url(server: server, path: "/Users/\(userId)/Items", queryItems: query)
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `GET /Users/{UserId}/Items/Resume` — continue-watching rail.
    public static func resumeItemsRequest(server: URL,
                                          token: String,
                                          identity: EmbyClientIdentity,
                                          userId: String,
                                          parentId: String? = nil,
                                          limit: Int = 20) throws -> URLRequest {
        var query = [
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
            URLQueryItem(name: "Fields", value: fullItemFields),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImages", value: "true"),
        ]
        if let parentId { query.append(URLQueryItem(name: "ParentId", value: parentId)) }
        let url = try url(server: server, path: "/Users/\(userId)/Items/Resume", queryItems: query)
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `GET /Shows/NextUp?UserId=..`
    public static func nextUpRequest(server: URL,
                                     token: String,
                                     identity: EmbyClientIdentity,
                                     userId: String,
                                     parentId: String? = nil,
                                     limit: Int = 20) throws -> URLRequest {
        var query = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: fullItemFields),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImages", value: "true"),
        ]
        if let parentId { query.append(URLQueryItem(name: "ParentId", value: parentId)) }
        let url = try url(server: server, path: "/Shows/NextUp", queryItems: query)
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `GET /Users/{UserId}/Items/Latest`
    public static func latestItemsRequest(server: URL,
                                          token: String,
                                          identity: EmbyClientIdentity,
                                          userId: String,
                                          parentId: String? = nil,
                                          includeItemTypes: String = "Movie,Episode",
                                          limit: Int = 20) throws -> URLRequest {
        var query = [
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes),
            URLQueryItem(name: "Fields", value: fullItemFields),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "GroupItems", value: "false"),
        ]
        if let parentId { query.append(URLQueryItem(name: "ParentId", value: parentId)) }
        let url = try url(server: server, path: "/Users/\(userId)/Items/Latest", queryItems: query)
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `GET /Users/{UserId}/Items/{itemId}`
    public static func itemRequest(server: URL,
                                   token: String,
                                   identity: EmbyClientIdentity,
                                   userId: String,
                                   itemId: String) throws -> URLRequest {
        let url = try url(server: server, path: "/Users/\(userId)/Items/\(itemId)", queryItems: [
            URLQueryItem(name: "Fields", value: fullItemFields),
        ])
        return get(url: url, token: token, identity: identity, userId: userId)
    }

    /// `POST`/`DELETE /Users/{UserId}/PlayedItems/{itemId}`
    public static func markPlayedRequest(server: URL,
                                         token: String,
                                         identity: EmbyClientIdentity,
                                         userId: String,
                                         itemId: String,
                                         played: Bool) throws -> URLRequest {
        let url = try url(server: server,
                          path: "/Users/\(userId)/PlayedItems/\(itemId)",
                          queryItems: [])
        var req = authenticatedRequest(url: url, token: token, identity: identity, userId: userId)
        req.httpMethod = played ? "POST" : "DELETE"
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
    public static func transcodedDownloadRequest(server: URL,
                                                 token: String,
                                                 identity: EmbyClientIdentity,
                                                 userId: String,
                                                 transcodingURL: String) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, pathOrURLString: transcodingURL)
        var req = URLRequest(url: url)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        // The transcoding URL already carries api_key; still attach the identity header so the
        // request is well-formed (mirrors authenticatedRequest), but do NOT duplicate the token
        // anywhere it isn't already present.
        req.setValue(EmbyAuth.authorizationHeader(identity: identity, userId: userId, token: token),
                     forHTTPHeaderField: "Authorization")
        return req
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
        let url = try url(server: server, path: "/Videos/ActiveEncodings", queryItems: [
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "PlaySessionId", value: playSessionId),
        ])
        var req = authenticatedRequest(url: url, token: token, identity: identity, userId: userId)
        req.httpMethod = "DELETE"
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

    private static func baseItemsQuery(fields: String = fullItemFields) -> [URLQueryItem] {
        [
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Season,Episode"),
            URLQueryItem(name: "Fields", value: fields),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
        ]
    }

    public static let gridItemFields = "PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating"
    public static let fullItemFields = "MediaSources,Overview,Chapters,Genres,ProviderIds,ParentId,PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating,Taglines"

    private static func replaceQueryItem(named name: String, with value: String, in query: inout [URLQueryItem]) {
        query.removeAll { $0.name == name }
        query.append(URLQueryItem(name: name, value: value))
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
