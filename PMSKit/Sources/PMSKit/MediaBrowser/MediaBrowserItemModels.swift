import Foundation

// Emby and Jellyfin share a forked HTTP API, so their item-model DTOs are identical
// except for one thing: the synthetic URI scheme baked into image/media references
// (`emby://…` vs `jellyfin://…`), which downstream consumers (PosterImage,
// PlaybackController, TrickPlayThumbnailProviders, DownloadManager) parse to route.
//
// We model that single delta with a phantom `Flavor` type and define the DTOs once,
// generically. Each backend keeps its familiar public type names via the typealiases
// at the bottom of this file, so call sites and tests are unchanged.
//
// The struct fields are a superset of both backends: Emby-only fields (seasonId/
// seasonName on items, supportsDirect* on media sources, playCount/isFavorite on user
// data) simply decode as nil for Jellyfin payloads, which never carry them.

public protocol MediaBrowserFlavor: Sendable {
    /// Scheme used to mint synthetic image/media URIs, e.g. "emby" -> `emby://item/…`.
    static var syntheticScheme: String { get }
}

public enum EmbyFlavor: MediaBrowserFlavor {
    public static let syntheticScheme = "emby"
}

public enum JellyfinFlavor: MediaBrowserFlavor {
    public static let syntheticScheme = "jellyfin"
}

public enum MediaBrowserImageType: String, Sendable, Equatable {
    case primary = "Primary"
    case backdrop = "Backdrop"
}

public struct MediaBrowserUserViewsResponse<Flavor: MediaBrowserFlavor>: Decodable, Sendable, Equatable {
    public let items: [MediaBrowserBaseItemDto<Flavor>]
    public let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([MediaBrowserBaseItemDto<Flavor>].self, forKey: .items) ?? []
        totalRecordCount = try c.decodeIfPresent(Int.self, forKey: .totalRecordCount)
    }
}

public struct MediaBrowserItemsResponse<Flavor: MediaBrowserFlavor>: Decodable, Sendable, Equatable {
    public let items: [MediaBrowserBaseItemDto<Flavor>]
    public let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([MediaBrowserBaseItemDto<Flavor>].self, forKey: .items) ?? []
        totalRecordCount = try c.decodeIfPresent(Int.self, forKey: .totalRecordCount)
    }

    public static func decode(from data: Data) throws -> MediaBrowserItemsResponse<Flavor> {
        try JSONDecoder().decode(MediaBrowserItemsResponse<Flavor>.self, from: data)
    }
}

public struct MediaBrowserBaseItemDto<Flavor: MediaBrowserFlavor>: Decodable, Sendable, Equatable, Identifiable {
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
    public let chapters: [MediaBrowserChapterDto<Flavor>]
    public let mediaSources: [MediaBrowserItemMediaSourceDto<Flavor>]
    public let userData: MediaBrowserUserDataDto?
    public let imageTags: [String: String]
    public let backdropImageTags: [String]
    public let parentId: String?
    public let seriesId: String?
    public let seriesName: String?
    public let seasonId: String?
    public let seasonName: String?
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
        case chapters = "Chapters"
        case mediaSources = "MediaSources"
        case userData = "UserData"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentId = "ParentId"
        case seriesId = "SeriesId"
        case seriesName = "SeriesName"
        case seasonId = "SeasonId"
        case seasonName = "SeasonName"
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
        chapters = try c.decodeIfPresent([MediaBrowserChapterDto<Flavor>].self, forKey: .chapters) ?? []
        mediaSources = try c.decodeIfPresent([MediaBrowserItemMediaSourceDto<Flavor>].self, forKey: .mediaSources) ?? []
        userData = try c.decodeIfPresent(MediaBrowserUserDataDto.self, forKey: .userData)
        imageTags = try c.decodeIfPresent([String: String].self, forKey: .imageTags) ?? [:]
        backdropImageTags = try c.decodeIfPresent([String].self, forKey: .backdropImageTags) ?? []
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        seriesName = try c.decodeIfPresent(String.self, forKey: .seriesName)
        seasonId = try c.decodeIfPresent(String.self, forKey: .seasonId)
        seasonName = try c.decodeIfPresent(String.self, forKey: .seasonName)
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
            thumb: syntheticImagePath(type: .primary, tag: imageTags[MediaBrowserImageType.primary.rawValue]),
            art: syntheticImagePath(type: .backdrop, tag: backdropImageTags.first),
            media: mediaSources.isEmpty ? nil : mediaSources.enumerated().map { $0.element.toPlexMedia(index: $0.offset, itemId: id) },
            chapters: chapters.isEmpty ? nil : chapters.enumerated().map { $0.element.toPlexChapter(index: $0.offset, itemId: id) },
            rating: shouldExposeCommunityRating ? communityRating : nil,
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
        case "Video": return "video"
        default: return nil
        }
    }

    private var shouldExposeCommunityRating: Bool {
        switch type {
        case "Movie", "Series":
            return true
        default:
            return false
        }
    }

    private func syntheticImagePath(type: MediaBrowserImageType, tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        return "\(Flavor.syntheticScheme)://item/\(id)/\(type.rawValue)?tag=\(tag)"
    }
}

public struct MediaBrowserChapterDto<Flavor: MediaBrowserFlavor>: Decodable, Sendable, Equatable {
    public let startPositionTicks: Int?
    public let name: String?
    public let imageTag: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
        case imageTag = "ImageTag"
    }

    func toPlexChapter(index: Int, itemId: String) -> Chapter {
        Chapter(id: index + 1,
                tag: name,
                startTimeOffset: startPositionTicks.map { $0 / 10_000 },
                endTimeOffset: nil,
                thumb: syntheticChapterImagePath(index: index, itemId: itemId))
    }

    private func syntheticChapterImagePath(index: Int, itemId: String) -> String? {
        guard let imageTag, !imageTag.isEmpty else { return nil }
        return "\(Flavor.syntheticScheme)://item/\(itemId)/Chapter/\(index)?tag=\(imageTag)"
    }
}

public struct MediaBrowserItemMediaSourceDto<Flavor: MediaBrowserFlavor>: Decodable, Sendable, Equatable {
    public let id: String?
    public let container: String?
    public let bitrate: Int?
    public let width: Int?
    public let height: Int?
    public let videoCodec: String?
    public let audioCodec: String?
    public let supportsDirectPlay: Bool?
    public let supportsDirectStream: Bool?
    public let supportsTranscoding: Bool?
    public let mediaStreams: [MediaBrowserItemMediaStreamDto]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case container = "Container"
        case bitrate = "Bitrate"
        case width = "Width"
        case height = "Height"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
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
        supportsDirectPlay = try c.decodeIfPresent(Bool.self, forKey: .supportsDirectPlay)
        supportsDirectStream = try c.decodeIfPresent(Bool.self, forKey: .supportsDirectStream)
        supportsTranscoding = try c.decodeIfPresent(Bool.self, forKey: .supportsTranscoding)
        mediaStreams = try c.decodeIfPresent([MediaBrowserItemMediaStreamDto].self, forKey: .mediaStreams) ?? []
    }

    func toPlexMedia(index: Int, itemId: String) -> Media {
        let part = Part(id: index + 1,
                        key: "\(Flavor.syntheticScheme)://item/\(itemId)/media/\(id ?? String(index))",
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

public struct MediaBrowserItemMediaStreamDto: Decodable, Sendable, Equatable {
    public let index: Int?
    public let type: String?
    public let codec: String?
    public let language: String?
    public let externalURL: String?
    public let deliveryURL: String?
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
        case externalURL = "ExternalUrl"
        case deliveryURL = "DeliveryUrl"
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
        externalURL = try c.decodeIfPresent(String.self, forKey: .externalURL)
        deliveryURL = try c.decodeIfPresent(String.self, forKey: .deliveryURL)
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
                      key: deliveryURL ?? externalURL,
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

    var isLowRiskTranscodeAudio: Bool {
        guard type == "Audio", let codec = codec?.lowercased() else { return false }
        guard ["aac", "ac3", "eac3"].contains(codec) else { return false }
        return (channels ?? 0) <= 6 || channels == nil
    }

    var looksLikeCommentaryOrDescriptiveAudio: Bool {
        let text = [displayTitle, title]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return text.contains("commentary") ||
            text.contains("description") ||
            text.contains("descriptive")
    }
}

public struct MediaBrowserUserDataDto: Decodable, Sendable, Equatable {
    public let playbackPositionTicks: Int?
    public let played: Bool?
    public let playCount: Int?
    public let isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
    }
}

// MARK: - Backend-specific names (preserve existing call sites & tests)

public typealias EmbyImageType = MediaBrowserImageType
public typealias EmbyUserViewsResponse = MediaBrowserUserViewsResponse<EmbyFlavor>
public typealias EmbyItemsResponse = MediaBrowserItemsResponse<EmbyFlavor>
public typealias EmbyBaseItemDto = MediaBrowserBaseItemDto<EmbyFlavor>
public typealias EmbyChapterDto = MediaBrowserChapterDto<EmbyFlavor>
public typealias EmbyItemMediaSourceDto = MediaBrowserItemMediaSourceDto<EmbyFlavor>
public typealias EmbyItemMediaStreamDto = MediaBrowserItemMediaStreamDto
public typealias EmbyUserDataDto = MediaBrowserUserDataDto

public typealias JellyfinImageType = MediaBrowserImageType
public typealias JellyfinUserViewsResponse = MediaBrowserUserViewsResponse<JellyfinFlavor>
public typealias JellyfinItemsResponse = MediaBrowserItemsResponse<JellyfinFlavor>
public typealias JellyfinBaseItemDto = MediaBrowserBaseItemDto<JellyfinFlavor>
public typealias JellyfinChapterDto = MediaBrowserChapterDto<JellyfinFlavor>
public typealias JellyfinItemMediaSourceDto = MediaBrowserItemMediaSourceDto<JellyfinFlavor>
public typealias JellyfinItemMediaStreamDto = MediaBrowserItemMediaStreamDto
public typealias JellyfinUserDataDto = MediaBrowserUserDataDto
