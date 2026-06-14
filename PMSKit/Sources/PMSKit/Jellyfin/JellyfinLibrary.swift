import Foundation

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

public enum JellyfinImageType: String, Sendable, Equatable {
    case primary = "Primary"
    case backdrop = "Backdrop"
}

public struct JellyfinUserViewsResponse: Decodable, Sendable, Equatable {
    public let items: [JellyfinBaseItemDto]
    public let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([JellyfinBaseItemDto].self, forKey: .items) ?? []
        totalRecordCount = try c.decodeIfPresent(Int.self, forKey: .totalRecordCount)
    }
}

public struct JellyfinItemsResponse: Decodable, Sendable, Equatable {
    public let items: [JellyfinBaseItemDto]
    public let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([JellyfinBaseItemDto].self, forKey: .items) ?? []
        totalRecordCount = try c.decodeIfPresent(Int.self, forKey: .totalRecordCount)
    }
}

public struct JellyfinBaseItemDto: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let type: String?
    public let overview: String?
    public let productionYear: Int?
    public let runTimeTicks: Int?
    public let userData: JellyfinUserDataDto?
    public let imageTags: [String: String]
    public let backdropImageTags: [String]
    public let parentId: String?
    public let seriesId: String?
    public let seriesName: String?
    public let parentIndexNumber: Int?
    public let indexNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case runTimeTicks = "RunTimeTicks"
        case userData = "UserData"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentId = "ParentId"
        case seriesId = "SeriesId"
        case seriesName = "SeriesName"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        type = try c.decodeIfPresent(String.self, forKey: .type)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        productionYear = try c.decodeIfPresent(Int.self, forKey: .productionYear)
        runTimeTicks = try c.decodeIfPresent(Int.self, forKey: .runTimeTicks)
        userData = try c.decodeIfPresent(JellyfinUserDataDto.self, forKey: .userData)
        imageTags = try c.decodeIfPresent([String: String].self, forKey: .imageTags) ?? [:]
        backdropImageTags = try c.decodeIfPresent([String].self, forKey: .backdropImageTags) ?? []
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        seriesName = try c.decodeIfPresent(String.self, forKey: .seriesName)
        parentIndexNumber = try c.decodeIfPresent(Int.self, forKey: .parentIndexNumber)
        indexNumber = try c.decodeIfPresent(Int.self, forKey: .indexNumber)
    }

    public func toMediaItem() -> MediaItem? {
        guard let mappedType = mediaItemType else { return nil }
        return MediaItem(
            ratingKey: id,
            title: name,
            type: mappedType,
            duration: runTimeTicks.map { $0 / 10_000 },
            viewOffset: userData?.playbackPositionTicks.map { $0 / 10_000 },
            viewCount: userData?.played == true ? 1 : 0,
            year: productionYear,
            summary: overview,
            thumb: syntheticImagePath(type: .primary, tag: imageTags[JellyfinImageType.primary.rawValue]),
            art: syntheticImagePath(type: .backdrop, tag: backdropImageTags.first),
            grandparentTitle: mappedType == "episode" ? seriesName : nil,
            grandparentRatingKey: mappedType == "episode" ? seriesId : nil,
            parentTitle: mappedType == "season" ? seriesName : nil,
            parentRatingKey: parentId,
            parentIndex: parentIndexNumber,
            index: indexNumber)
    }

    private var mediaItemType: String? {
        switch type {
        case "Movie": return "movie"
        case "Series": return "show"
        case "Season": return "season"
        case "Episode": return "episode"
        default: return nil
        }
    }

    private func syntheticImagePath(type: JellyfinImageType, tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        return "jellyfin://item/\(id)/\(type.rawValue)?tag=\(tag)"
    }
}

public struct JellyfinUserDataDto: Decodable, Sendable, Equatable {
    public let playbackPositionTicks: Int?
    public let played: Bool?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
    }
}

public enum JellyfinLibrary {
    public static func userViewsRequest(server: URL,
                                        token: String,
                                        identity: JellyfinClientIdentity,
                                        userId: String) throws -> URLRequest {
        let url = try url(server: server, path: "/UserViews", queryItems: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "includeExternalContent", value: "false"),
        ])
        return get(url: url, token: token, identity: identity)
    }

    public static func itemsRequest(server: URL,
                                    token: String,
                                    identity: JellyfinClientIdentity,
                                    userId: String,
                                    parentId: String? = nil,
                                    recursive: Bool = false) throws -> URLRequest {
        var query = baseItemsQuery(userId: userId)
        if let parentId { query.append(URLQueryItem(name: "parentId", value: parentId)) }
        query.append(URLQueryItem(name: "recursive", value: recursive ? "true" : "false"))
        let url = try url(server: server, path: "/Items", queryItems: query)
        return get(url: url, token: token, identity: identity)
    }

    public static func itemRequest(server: URL,
                                   token: String,
                                   identity: JellyfinClientIdentity,
                                   userId: String,
                                   itemId: String) throws -> URLRequest {
        let url = try url(server: server, path: "/Items/\(itemId)", queryItems: [
            URLQueryItem(name: "userId", value: userId),
        ])
        return get(url: url, token: token, identity: identity)
    }

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

    private static func baseItemsQuery(userId: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series,Season,Episode"),
            URLQueryItem(name: "fields", value: "Overview,Genres,MediaSources,People,ProviderIds,ParentId,PrimaryImageAspectRatio,UserData"),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "sortBy", value: "SortName"),
            URLQueryItem(name: "sortOrder", value: "Ascending"),
        ]
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
