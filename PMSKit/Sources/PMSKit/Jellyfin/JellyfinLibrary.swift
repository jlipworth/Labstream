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
    public let collectionType: String?
    public let overview: String?
    public let productionYear: Int?
    public let runTimeTicks: Int?
    public let officialRating: String?
    public let communityRating: Double?
    public let taglines: [String]
    public let genres: [String]
    public let mediaSources: [JellyfinItemMediaSourceDto]
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
        case collectionType = "CollectionType"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case runTimeTicks = "RunTimeTicks"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case taglines = "Taglines"
        case genres = "Genres"
        case mediaSources = "MediaSources"
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
        collectionType = try c.decodeIfPresent(String.self, forKey: .collectionType)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        productionYear = try c.decodeIfPresent(Int.self, forKey: .productionYear)
        runTimeTicks = try c.decodeIfPresent(Int.self, forKey: .runTimeTicks)
        officialRating = try c.decodeIfPresent(String.self, forKey: .officialRating)
        communityRating = try c.decodeIfPresent(Double.self, forKey: .communityRating)
        taglines = try c.decodeIfPresent([String].self, forKey: .taglines) ?? []
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        mediaSources = try c.decodeIfPresent([JellyfinItemMediaSourceDto].self, forKey: .mediaSources) ?? []
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
            media: mediaSources.isEmpty ? nil : mediaSources.enumerated().map { $0.element.toPlexMedia(index: $0.offset, itemId: id) },
            rating: communityRating,
            contentRating: officialRating,
            tagline: taglines.first,
            genres: genres.isEmpty ? nil : genres.map(Tag.init(tag:)),
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

public struct JellyfinItemMediaSourceDto: Decodable, Sendable, Equatable {
    public let id: String?
    public let container: String?
    public let bitrate: Int?
    public let width: Int?
    public let height: Int?
    public let videoCodec: String?
    public let audioCodec: String?
    public let mediaStreams: [JellyfinItemMediaStreamDto]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case container = "Container"
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
        container = try c.decodeIfPresent(String.self, forKey: .container)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec)
        mediaStreams = try c.decodeIfPresent([JellyfinItemMediaStreamDto].self, forKey: .mediaStreams) ?? []
    }

    func toPlexMedia(index: Int, itemId: String) -> Media {
        let part = Part(id: index + 1,
                        key: "jellyfin://item/\(itemId)/media/\(id ?? String(index))",
                        duration: nil,
                        file: nil,
                        size: nil,
                        container: container,
                        streams: mediaStreams.enumerated().compactMap { $0.element.toPlexStream(fallbackID: $0.offset + 1) })
        return Media(id: index + 1,
                     duration: nil,
                     bitrate: bitrate.map { $0 / 1_000 },
                     width: width,
                     height: height,
                     videoCodec: videoCodec,
                     audioCodec: audioCodec,
                     container: container,
                     part: [part])
    }
}

public struct JellyfinItemMediaStreamDto: Decodable, Sendable, Equatable {
    public let index: Int?
    public let type: String?
    public let codec: String?
    public let language: String?
    public let displayTitle: String?
    public let isDefault: Bool?
    public let isForced: Bool?
    public let channels: Int?
    public let title: String?
    public let width: Int?
    public let height: Int?

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case isDefault = "IsDefault"
        case isForced = "IsForced"
        case channels = "Channels"
        case title = "Title"
        case width = "Width"
        case height = "Height"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        displayTitle = try c.decodeIfPresent(String.self, forKey: .displayTitle)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault)
        isForced = try c.decodeIfPresent(Bool.self, forKey: .isForced)
        channels = try c.decodeIfPresent(Int.self, forKey: .channels)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
    }

    func toPlexStream(fallbackID: Int) -> Stream? {
        guard let streamType else { return nil }
        return Stream(id: index ?? fallbackID,
                      streamType: streamType.rawValue,
                      index: index,
                      codec: codec,
                      language: language,
                      languageTag: nil,
                      languageCode: nil,
                      displayTitle: displayTitle,
                      extendedDisplayTitle: displayTitle,
                      selected: nil,
                      isDefault: isDefault,
                      forced: isForced,
                      channels: channels,
                      title: title)
    }

    private var streamType: StreamType? {
        switch type {
        case "Video": return .video
        case "Audio": return .audio
        case "Subtitle": return .subtitle
        default: return nil
        }
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
                                    recursive: Bool = false,
                                    limit: Int? = nil,
                                    searchTerm: String? = nil,
                                    sortBy: String = "SortName",
                                    sortOrder: String = "Ascending",
                                    filters: [String] = []) throws -> URLRequest {
        var query = baseItemsQuery(userId: userId)
        if let parentId { query.append(URLQueryItem(name: "parentId", value: parentId)) }
        query.append(URLQueryItem(name: "recursive", value: recursive ? "true" : "false"))
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let searchTerm, !searchTerm.isEmpty {
            query.append(URLQueryItem(name: "searchTerm", value: searchTerm))
        }
        if !filters.isEmpty { query.append(URLQueryItem(name: "filters", value: filters.joined(separator: ","))) }
        replaceQueryItem(named: "sortBy", with: sortBy, in: &query)
        replaceQueryItem(named: "sortOrder", with: sortOrder, in: &query)
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
                                       itemId: String) throws -> URLRequest {
        let url = try url(server: server,
                          path: "/Items/\(itemId)/Download",
                          queryItems: [])
        var req = get(url: url, token: token, identity: identity)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        return req
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
            URLQueryItem(name: "fields", value: "Overview,Genres,MediaSources,People,ProviderIds,ParentId,PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating,Taglines"),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "sortBy", value: "SortName"),
            URLQueryItem(name: "sortOrder", value: "Ascending"),
        ]
    }

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
