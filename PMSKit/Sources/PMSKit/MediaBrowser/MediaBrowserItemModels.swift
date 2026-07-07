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
    case logo = "Logo"
    /// Episode-still / thumbnail image (distinct from `primary`, which is the poster).
    case thumb = "Thumb"
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
    /// Separate critic rating (`CriticRating`, e.g. Rotten-Tomatoes critic %), distinct
    /// from the audience `communityRating`. See #76.
    public let criticRating: Double?
    public let taglines: [String]
    public let genres: [String]
    /// Cast/crew (`People`) — each carries a `Name` and a `Type` (Actor/Director/…). See #76.
    public let people: [MediaBrowserPersonDto]
    /// Production studios (`Studios`) — each carries a `Name`. See #76.
    public let studios: [MediaBrowserNamedDto]
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
    /// External provider ids (`ProviderIds`, e.g. `{"Tmdb": "603", "Imdb": "tt0133093"}`).
    /// Surfaced on `MediaItem.providerIds` to give the movie-grid collapser a robust
    /// cross-edition identity (#108). Empty when the request didn't ask for `ProviderIds`
    /// (the grid field list does for movie libraries) or the item carries none.
    public let providerIds: [String: String]
    /// Primary-image aspect ratio (width / height) the server computed for this item's
    /// poster art (`PrimaryImageAspectRatio`). ~1.778 for 16:9 (YouTube), ~1.0 for square
    /// channel art, ~0.667 for a 2:3 movie poster. Surfaced on `MediaItem` so poster cells
    /// size to the real shape instead of force-cropping to 2:3. See GH #101.
    public let primaryImageAspectRatio: Double?

    // MARK: - Parent/series image tags (artwork fallback — see #86)
    //
    // Jellyfin/Emby episodes frequently carry no own `Primary` image (and seasons often
    // no own `Backdrop`). The server then exposes the right image on the parent/series
    // item via these companion tag + owning-item-id fields, which the web clients use to
    // fall back. We decode them so `toMediaItem()` can mint a synthetic ref against the
    // *owning* item id (season/series), not the episode id.

    /// Series poster tag (`SeriesPrimaryImageTag`), paired with `seriesId`.
    public let seriesPrimaryImageTag: String?
    /// Season-thumb owning item id + tag (`ParentThumbItemId`/`ParentThumbImageTag`).
    public let parentThumbItemId: String?
    public let parentThumbImageTag: String?
    /// Parent backdrop owning item id + tags (`ParentBackdropItemId`/`ParentBackdropImageTags`).
    public let parentBackdropItemId: String?
    public let parentBackdropImageTags: [String]
    /// Parent primary owning item id + tag (`ParentPrimaryImageItemId`/`ParentPrimaryImageTag`).
    public let parentPrimaryImageItemId: String?
    public let parentPrimaryImageTag: String?

    // Music hierarchy (#111). An `Audio` row carries its album name/id + album-artist directly
    // (it does NOT use Series*/Season* — those are TV-only); an album's primary art lives on the
    // album, so a track without its own Primary mints art against `AlbumId`/`AlbumPrimaryImageTag`.
    /// Album display name for an `Audio` track (`Album`).
    public let album: String?
    /// Owning album id for an `Audio` track (`AlbumId`) — the music parent for nav + art.
    public let albumId: String?
    /// Album-artist display name (`AlbumArtist`) — the grandparent of a track, parent of an album.
    public let albumArtist: String?
    /// Album primary-image tag (`AlbumPrimaryImageTag`), paired with `albumId` for a track's poster.
    public let albumPrimaryImageTag: String?
    /// Child count (`ChildCount`) — e.g. the number of tracks in a playlist (#111). Present
    /// only when the request asks for the `ChildCount` field.
    public let childCount: Int?

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
        case criticRating = "CriticRating"
        case taglines = "Taglines"
        case genres = "Genres"
        case people = "People"
        case studios = "Studios"
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
        case providerIds = "ProviderIds"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case parentThumbItemId = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case parentBackdropItemId = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentPrimaryImageItemId = "ParentPrimaryImageItemId"
        case parentPrimaryImageTag = "ParentPrimaryImageTag"
        case album = "Album"
        case albumId = "AlbumId"
        case albumArtist = "AlbumArtist"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case childCount = "ChildCount"
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
        criticRating = try c.decodeIfPresent(Double.self, forKey: .criticRating)
        taglines = try c.decodeIfPresent([String].self, forKey: .taglines) ?? []
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        people = try c.decodeIfPresent([MediaBrowserPersonDto].self, forKey: .people) ?? []
        studios = try c.decodeIfPresent([MediaBrowserNamedDto].self, forKey: .studios) ?? []
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
        providerIds = try c.decodeIfPresent([String: String].self, forKey: .providerIds) ?? [:]
        primaryImageAspectRatio = try c.decodeIfPresent(Double.self, forKey: .primaryImageAspectRatio)
        seriesPrimaryImageTag = try c.decodeIfPresent(String.self, forKey: .seriesPrimaryImageTag)
        parentThumbItemId = try c.decodeIfPresent(String.self, forKey: .parentThumbItemId)
        parentThumbImageTag = try c.decodeIfPresent(String.self, forKey: .parentThumbImageTag)
        parentBackdropItemId = try c.decodeIfPresent(String.self, forKey: .parentBackdropItemId)
        parentBackdropImageTags = try c.decodeIfPresent([String].self, forKey: .parentBackdropImageTags) ?? []
        parentPrimaryImageItemId = try c.decodeIfPresent(String.self, forKey: .parentPrimaryImageItemId)
        parentPrimaryImageTag = try c.decodeIfPresent(String.self, forKey: .parentPrimaryImageTag)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        albumPrimaryImageTag = try c.decodeIfPresent(String.self, forKey: .albumPrimaryImageTag)
        childCount = try c.decodeIfPresent(Int.self, forKey: .childCount)
    }

    public func toMediaItem() -> MediaItem? {
        guard let mappedType = mediaItemType else { return nil }

        // Own-item artwork tags first.
        let ownPrimary = imageTags[MediaBrowserImageType.primary.rawValue]
        let ownThumb = imageTags[MediaBrowserImageType.thumb.rawValue]
        let ownLogo = imageTags[MediaBrowserImageType.logo.rawValue]

        // Parent/series fallback for the poster: an episode with no own Primary should
        // resolve to its season thumb, then the series poster; a season with no own
        // Primary to the series poster (#86). Each fallback is minted against the OWNING
        // item id (season/series), not this item's id — the image lives on that item.
        let ownPrimaryPath = syntheticImagePath(type: .primary, tag: ownPrimary)
        let primaryThumb: String? = {
            switch mappedType {
            case "episode":
                return ownPrimaryPath ?? parentThumbPath ?? seriesPrimaryPath
            case "season":
                return ownPrimaryPath ?? seriesPrimaryPath
            case "track":
                // A track rarely has its own Primary — its art lives on the owning album (#111).
                return ownPrimaryPath ?? albumPrimaryPath
            default:
                return ownPrimaryPath
            }
        }()

        // Backdrop: own → parent backdrop. (Series backdrop has no companion tag field on
        // the wire, and the resolver needs a tag, so the chain ends at parent.)
        let backdrop: String? =
            syntheticImagePath(type: .backdrop, tag: backdropImageTags.first)
            ?? parentBackdropPath

        // Episode-still Thumb (distinct from the poster): only episodes should prefer this
        // landscape still in `MediaItem.thumb`. Movies/shows/seasons must keep their Primary
        // poster in `thumb`, otherwise a backend-provided Thumb would replace poster/grid art
        // and violate #86's "movies unaffected" acceptance.
        let resolvedThumb: String? = {
            guard mappedType == "episode" else { return primaryThumb }
            return syntheticImagePath(type: .thumb, tag: ownThumb) ?? primaryThumb
        }()

        let cast = people.filter { ($0.type ?? "") == "Actor" }
            .compactMap { $0.name }.filter { !$0.isEmpty }
        let crewDirectors = people.filter { ($0.type ?? "") == "Director" }
            .compactMap { $0.name }.filter { !$0.isEmpty }
        let studioNames = studios.compactMap { $0.name }.filter { !$0.isEmpty }

        return MediaItem(
            ratingKey: id,
            title: name,
            type: mappedType,
            duration: runTimeTicks.map { $0 / 10_000 },
            viewOffset: userData?.playbackPositionTicks.map { $0 / 10_000 },
            viewCount: userData?.played == true ? 1 : 0,
            year: productionYear,
            summary: overview,
            thumb: resolvedThumb,
            art: backdrop,
            media: mediaSources.isEmpty ? nil : mediaSources.enumerated().map { $0.element.toCanonicalMedia(index: $0.offset, itemId: id) },
            chapters: chapters.isEmpty ? nil : chapters.enumerated().map { $0.element.toCanonicalChapter(index: $0.offset, itemId: id) },
            rating: shouldExposeCommunityRating ? communityRating : nil,
            contentRating: officialRating,
            tagline: taglines.first,
            genres: genres.isEmpty ? nil : genres.map(Tag.init(tag:)),
            criticRating: criticRating,
            roles: cast.isEmpty ? nil : cast.map(Tag.init(tag:)),
            directors: crewDirectors.isEmpty ? nil : crewDirectors.map(Tag.init(tag:)),
            studios: studioNames.isEmpty ? nil : studioNames.map(Tag.init(tag:)),
            logo: syntheticImagePath(type: .logo, tag: ownLogo),
            // Music (#111): a TRACK's grandparent is the album-artist, its parent the album; an
            // ALBUM's parent is the album-artist. Video types keep the episode/season wiring.
            grandparentTitle: mappedType == "episode" ? seriesName
                : (mappedType == "track" ? albumArtist : nil),
            grandparentRatingKey: mappedType == "episode" ? seriesId : nil,
            grandparentThumb: mappedType == "episode" ? seriesPrimaryPath : nil,
            parentTitle: mappedType == "season" ? seriesName
                : (mappedType == "track" ? album : (mappedType == "album" ? albumArtist : nil)),
            parentRatingKey: mappedType == "track" ? (albumId ?? parentId) : parentId,
            parentThumb: parentThumbPath ?? albumPrimaryPath ?? seriesPrimaryPath,
            parentIndex: parentIndexNumber,
            index: indexNumber,
            // A playlist's `ChildCount` is its track count, surfaced for the "N tracks"
            // subtitle on the Playlists list (#111).
            leafCount: childCount,
            primaryImageAspectRatio: primaryImageAspectRatio,
            providerIds: providerIds.isEmpty ? nil : providerIds)
    }

    /// Album-poster fallback for a track (#111): `AlbumPrimaryImageTag` minted against `AlbumId`.
    private var albumPrimaryPath: String? {
        guard let tag = albumPrimaryImageTag, let owner = albumId else { return nil }
        return syntheticImagePath(type: .primary, tag: tag, ownerId: owner)
    }

    /// Season-thumb fallback: prefer the `ParentThumb*` companion (owning id + tag), else
    /// the season's own primary via `seasonId`/`ParentPrimaryImage*`.
    private var parentThumbPath: String? {
        if let tag = parentThumbImageTag, let owner = parentThumbItemId ?? seasonId ?? parentId {
            return syntheticImagePath(type: .thumb, tag: tag, ownerId: owner)
        }
        if let tag = parentPrimaryImageTag, let owner = parentPrimaryImageItemId ?? parentId {
            return syntheticImagePath(type: .primary, tag: tag, ownerId: owner)
        }
        return nil
    }

    /// Series-poster fallback via `SeriesPrimaryImageTag` + `seriesId`.
    private var seriesPrimaryPath: String? {
        guard let tag = seriesPrimaryImageTag, let owner = seriesId else { return nil }
        return syntheticImagePath(type: .primary, tag: tag, ownerId: owner)
    }

    /// Parent-backdrop fallback via `ParentBackdropImageTags` + owning id.
    private var parentBackdropPath: String? {
        guard let tag = parentBackdropImageTags.first,
              let owner = parentBackdropItemId ?? seasonId ?? parentId else { return nil }
        return syntheticImagePath(type: .backdrop, tag: tag, ownerId: owner)
    }

    private var mediaItemType: String? {
        switch type {
        case "Movie": return "movie"
        case "Series": return "show"
        case "Season": return "season"
        case "Episode": return "episode"
        case "Video": return "video"
        // Music (#111): map MediaBrowser's music item types onto PMS music kinds so search/browse
        // can facet and route them (artist/album → music nav, track → music playback).
        case "MusicArtist", "AlbumArtist": return "artist"
        case "MusicAlbum": return "album"
        case "Audio": return "track"
        case "Playlist": return "playlist"
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

    /// Mint a synthetic image ref. `ownerId` defaults to this item's id, but a parent/series
    /// fallback passes the OWNING item id so the resolver targets the item the image lives
    /// on (e.g. a season/series), not the episode (#86).
    private func syntheticImagePath(type: MediaBrowserImageType, tag: String?, ownerId: String? = nil) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        return "\(Flavor.syntheticScheme)://item/\(ownerId ?? id)/\(type.rawValue)?tag=\(tag)"
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

    func toCanonicalChapter(index: Int, itemId: String) -> Chapter {
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

    func toCanonicalMedia(index: Int, itemId: String) -> Media {
        let part = Part(id: index + 1,
                        key: "\(Flavor.syntheticScheme)://item/\(itemId)/media/\(id ?? String(index))",
                        duration: nil,
                        file: nil,
                        size: nil,
                        container: container,
                        streams: mediaStreams.enumerated().compactMap { $0.element.toCanonicalStream(fallbackID: $0.offset + 1) })
        // Jellyfin/Emby carry resolution & codecs on the per-stream `MediaStreams`, not on the
        // MediaSource itself (only `Bitrate`/`Container` live there). Fall back to the video /
        // audio streams so resolution ("4K"/"1080p") and codec badges populate (GH #108).
        let videoStream = mediaStreams.first { $0.type?.caseInsensitiveCompare("Video") == .orderedSame }
        let audioStream = mediaStreams.first { $0.type?.caseInsensitiveCompare("Audio") == .orderedSame }
        return Media(id: index + 1,
                     duration: nil,
                     bitrate: bitrate.map { $0 / 1_000 },
                     width: width ?? videoStream?.width,
                     height: height ?? videoStream?.height,
                     videoCodec: videoCodec ?? videoStream?.codec,
                     audioCodec: audioCodec ?? audioStream?.codec,
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
    /// Codec profile string, e.g. "Dolby TrueHD + Dolby Atmos" (audio) or "Main 10". (#195)
    public let profile: String?
    /// HDR/color facts (#195). Jellyfin sends `VideoRange`/`VideoRangeType` plus optional
    /// Dv*/color fields; Emby sends `ExtendedVideoType`/`ExtendedVideoSubType`. All lenient.
    public let bitDepth: Int?
    public let colorRange: String?
    public let colorSpace: String?
    public let colorTransfer: String?
    public let colorPrimaries: String?
    public let videoRange: String?
    public let videoRangeType: String?
    public let videoDoViTitle: String?
    public let dvProfile: Int?
    public let dvLevel: Int?
    public let dvBlSignalCompatibilityId: Int?
    public let rpuPresentFlag: Int?
    public let elPresentFlag: Int?
    public let blPresentFlag: Int?
    public let hdr10PlusPresentFlag: Bool?
    public let extendedVideoType: String?
    public let extendedVideoSubType: String?

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
        case profile = "Profile"
        case bitDepth = "BitDepth"
        case colorRange = "ColorRange"
        case colorSpace = "ColorSpace"
        case colorTransfer = "ColorTransfer"
        case colorPrimaries = "ColorPrimaries"
        case videoRange = "VideoRange"
        case videoRangeType = "VideoRangeType"
        case videoDoViTitle = "VideoDoViTitle"
        case dvProfile = "DvProfile"
        case dvLevel = "DvLevel"
        case dvBlSignalCompatibilityId = "DvBlSignalCompatibilityId"
        case rpuPresentFlag = "RpuPresentFlag"
        case elPresentFlag = "ElPresentFlag"
        case blPresentFlag = "BlPresentFlag"
        case hdr10PlusPresentFlag = "Hdr10PlusPresentFlag"
        case extendedVideoType = "ExtendedVideoType"
        case extendedVideoSubType = "ExtendedVideoSubType"
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
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth)
        colorRange = try c.decodeIfPresent(String.self, forKey: .colorRange)
        colorSpace = try c.decodeIfPresent(String.self, forKey: .colorSpace)
        colorTransfer = try c.decodeIfPresent(String.self, forKey: .colorTransfer)
        colorPrimaries = try c.decodeIfPresent(String.self, forKey: .colorPrimaries)
        videoRange = try c.decodeIfPresent(String.self, forKey: .videoRange)
        videoRangeType = try c.decodeIfPresent(String.self, forKey: .videoRangeType)
        videoDoViTitle = try c.decodeIfPresent(String.self, forKey: .videoDoViTitle)
        dvProfile = try c.decodeIfPresent(Int.self, forKey: .dvProfile)
        dvLevel = try c.decodeIfPresent(Int.self, forKey: .dvLevel)
        dvBlSignalCompatibilityId = try c.decodeIfPresent(Int.self, forKey: .dvBlSignalCompatibilityId)
        rpuPresentFlag = try c.decodeIfPresent(Int.self, forKey: .rpuPresentFlag)
        elPresentFlag = try c.decodeIfPresent(Int.self, forKey: .elPresentFlag)
        blPresentFlag = try c.decodeIfPresent(Int.self, forKey: .blPresentFlag)
        // Jellyfin models this as a bool; be lenient about 1/0 just in case.
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .hdr10PlusPresentFlag) {
            hdr10PlusPresentFlag = b
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .hdr10PlusPresentFlag) {
            hdr10PlusPresentFlag = i != 0
        } else {
            hdr10PlusPresentFlag = nil
        }
        extendedVideoType = try c.decodeIfPresent(String.self, forKey: .extendedVideoType)
        extendedVideoSubType = try c.decodeIfPresent(String.self, forKey: .extendedVideoSubType)
    }

    /// Normalized HDR classification (#195). Video streams only. Precedence:
    /// explicit DV facts / DOVI range type / Emby DolbyVision extended type, then
    /// HDR10+ (flag, range type, or extended type), then transfer function, then the
    /// coarse `VideoRange` verdict.
    public var hdrMetadata: VideoHDRMetadata? {
        guard type?.caseInsensitiveCompare("Video") == .orderedSame else { return nil }
        let rangeType = videoRangeType?.lowercased()
        let extType = extendedVideoType?.lowercased()

        let saysDV = dvProfile != nil
            || rangeType?.hasPrefix("dovi") == true
            || extType?.contains("dolbyvision") == true
            || videoRange?.caseInsensitiveCompare("DolbyVision") == .orderedSame
        var dovi: VideoDolbyVisionInfo?
        if saysDV {
            // When numeric DV facts are missing, synthesize the base-layer compatibility
            // from Jellyfin's "DOVIWith<fallback>" range type so the fallback label survives.
            var compat = dvBlSignalCompatibilityId
            if compat == nil, let rangeType {
                switch rangeType {
                case "doviwithhdr10": compat = 1
                case "doviwithsdr": compat = 2
                case "doviwithhlg": compat = 4
                default: break
                }
            }
            // Emby encodes profile in ExtendedVideoSubType. Live wire shapes (probe
            // 2026-07-03): "DoviProfile5", "DoviProfile76", "DoviProfile81" — for the
            // two-digit forms the digits are <profile><bl-compat-id> (7.6 / 8.1 style),
            // NOT a two-digit profile number.
            var profileNumber = dvProfile
            if profileNumber == nil,
               let sub = extendedVideoSubType?.lowercased(),
               let digits = sub.split(separator: "profile").last.map({ String($0.prefix(while: \.isNumber)) }),
               !digits.isEmpty {
                if digits.count == 2,
                   let first = digits.first?.wholeNumberValue,
                   let second = digits.last?.wholeNumberValue,
                   (4...9).contains(first) {
                    profileNumber = first
                    if compat == nil { compat = second }
                } else {
                    profileNumber = Int(digits)
                }
            }
            dovi = VideoDolbyVisionInfo(profile: profileNumber,
                                        level: dvLevel,
                                        blCompatibilityID: compat,
                                        rpuPresent: rpuPresentFlag.map { $0 != 0 },
                                        elPresent: elPresentFlag.map { $0 != 0 },
                                        blPresent: blPresentFlag.map { $0 != 0 })
        }

        let saysHDR10Plus = hdr10PlusPresentFlag == true
            || rangeType == "hdr10plus"
            || extType?.contains("hdr10plus") == true

        // Emby "HdrHlg" / Jellyfin "HLG" range types when the transfer field is absent.
        var transfer = colorTransfer
        if transfer == nil {
            if rangeType == "hlg" || extType?.contains("hlg") == true { transfer = "hlg" }
            else if rangeType == "hdr10" || extType?.contains("hdr10") == true { transfer = "smpte2084" }
        }

        let rangeDescribesHDR: Bool? = switch videoRange?.lowercased() {
        case "hdr": true
        case "sdr": false
        default: nil
        }

        return VideoHDRMetadata.classify(colorTransfer: transfer,
                                         colorPrimaries: colorPrimaries,
                                         colorSpace: colorSpace,
                                         colorRange: colorRange,
                                         bitDepth: bitDepth,
                                         dolbyVision: dovi,
                                         hdr10PlusPresent: saysHDR10Plus ? true : nil,
                                         rangeDescribesHDR: rangeDescribesHDR)
    }

    func toCanonicalStream(fallbackID: Int) -> Stream? {
        guard let streamType else { return nil }
        // Bridge the HDR classification, not just the raw fields: DTO-only evidence
        // (VideoRangeType "DOVIWith…", Emby ExtendedVideoType/SubType, Hdr10PlusPresentFlag)
        // has no canonical `Stream` column, so translate it into the canonical DV/HDR10+
        // fields — the classified result must be identical on both sides of the bridge. (#195)
        let hdr = hdrMetadata
        var transfer = colorTransfer
        if transfer == nil {
            switch hdr?.format {
            case .hdr10: transfer = "smpte2084"
            case .hlg: transfer = "arib-std-b67"
            default: break
            }
        }
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
                      title: title,
                      profile: profile,
                      bitDepth: bitDepth,
                      colorPrimaries: colorPrimaries,
                      colorRange: colorRange,
                      colorSpace: colorSpace,
                      colorTrc: transfer,
                      doviPresent: hdr?.format == .dolbyVision ? true : nil,
                      doviProfile: hdr?.dolbyVision?.profile,
                      doviLevel: hdr?.dolbyVision?.level,
                      doviBLCompatID: hdr?.dolbyVision?.blCompatibilityID,
                      doviBLPresent: hdr?.dolbyVision?.blPresent,
                      doviELPresent: hdr?.dolbyVision?.elPresent,
                      doviRPUPresent: hdr?.dolbyVision?.rpuPresent,
                      hdr10PlusPresent: hdr?.format == .hdr10Plus ? true : nil)
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
        return (channels ?? 0) <= 6
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

extension [MediaBrowserItemMediaStreamDto] {
    /// For a bitrate-capped transcode, the `MediaStream.Index` of an audio track the server can
    /// cheaply/reliably encode from — or nil when the current (default/first) track is already
    /// low-risk, or when no low-risk alternate exists. Prefers a same-language alternate and
    /// skips commentary/descriptive tracks when possible. Shared by the Jellyfin and Emby
    /// `resolveStream` paths so the steering logic can't diverge between the backends.
    func preferredCompatibleAudioStreamIndexForCappedTranscode() -> Int? {
        let audioStreams = filter { $0.type == "Audio" }
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

/// One `People` entry (cast/crew) on a Jellyfin/Emby item: `{ Name, Type, Role }`.
/// `Type` is "Actor"/"Director"/"Writer"/…; we split actors vs directors downstream. (#76)
public struct MediaBrowserPersonDto: Decodable, Sendable, Equatable {
    public let name: String?
    public let type: String?
    public let role: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case type = "Type"
        case role = "Role"
    }
}

/// A `{ Name }` entry — used for `Studios`. (#76)
public struct MediaBrowserNamedDto: Decodable, Sendable, Equatable {
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
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
