import Foundation

// MARK: - Library sections (`/library/sections`)

public struct SectionsResponse: Decodable, Sendable {
    public let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    public struct Container: Decodable, Sendable {
        public let size: Int?
        public let directory: [Section]
        enum CodingKeys: String, CodingKey {
            case size
            case directory = "Directory"
        }
    }
}

public struct Section: Decodable, Sendable, Identifiable {
    public let key: String
    public let title: String
    public let type: String
    public var id: String { key }

    public init(key: String, title: String, type: String) {
        self.key = key
        self.title = title
        self.type = type
    }
}

// MARK: - Metadata (`/library/metadata/<id>`, section items)

public struct MetadataResponse: Decodable, Sendable {
    public let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    public struct Container: Decodable, Sendable {
        public let size: Int?
        public let metadata: [MediaItem]
        enum CodingKeys: String, CodingKey {
            case size
            case metadata = "Metadata"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.size = try c.decodeIfPresent(Int.self, forKey: .size)
            // `Metadata` may be absent (e.g. an empty container); treat as [].
            self.metadata = try c.decodeIfPresent([MediaItem].self, forKey: .metadata) ?? []
        }
    }
}

public struct MediaItem: Decodable, Sendable, Identifiable {
    public let ratingKey: String
    public let key: String?
    public let title: String
    public let type: String
    public let duration: Int?
    public let viewOffset: Int?
    public let viewCount: Int?
    public let year: Int?
    public let summary: String?
    public let thumb: String?
    public let art: String?
    public let media: [Media]?
    /// Chapter markers, when PMS provides them (`Chapter` elements on the metadata).
    /// Absent for most items; the player hides chapter UI when this is empty/nil so the
    /// control degrades gracefully.
    public let chapters: [Chapter]?

    /// Critic/aggregate rating on a 0–10 scale (PMS `rating`). The DetailView renders it
    /// as e.g. "7.8" next to a star glyph. `nil` for items PMS doesn't rate.
    public let rating: Double?
    /// Content/age rating string (PMS `contentRating`), e.g. "PG-13", "TV-MA". Surfaced
    /// as a small capsule on the detail header so the viewer sees the certification.
    public let contentRating: String?
    /// One-line tagline (PMS `tagline`), shown under the title when present.
    public let tagline: String?
    /// Genre tags (`Genre` elements). Joined into a comma list on the detail header.
    /// Empty/nil when the item carries no genres.
    public let genres: [Tag]?

    public var id: String { ratingKey }

    enum CodingKeys: String, CodingKey {
        case ratingKey
        case key
        case title
        case type
        case duration
        case viewOffset
        case viewCount
        case year
        case summary
        case thumb
        case art
        case media = "Media"
        case chapters = "Chapter"
        case rating
        case contentRating
        case tagline
        case genres = "Genre"
    }

    public init(ratingKey: String,
                key: String? = nil,
                title: String,
                type: String,
                duration: Int? = nil,
                viewOffset: Int? = nil,
                viewCount: Int? = nil,
                year: Int? = nil,
                summary: String? = nil,
                thumb: String? = nil,
                art: String? = nil,
                media: [Media]? = nil,
                chapters: [Chapter]? = nil,
                rating: Double? = nil,
                contentRating: String? = nil,
                tagline: String? = nil,
                genres: [Tag]? = nil) {
        self.ratingKey = ratingKey
        self.key = key
        self.title = title
        self.type = type
        self.duration = duration
        self.viewOffset = viewOffset
        self.viewCount = viewCount
        self.year = year
        self.summary = summary
        self.thumb = thumb
        self.art = art
        self.media = media
        self.chapters = chapters
        self.rating = rating
        self.contentRating = contentRating
        self.tagline = tagline
        self.genres = genres
    }
}

/// A simple Plex tag element (`Genre`, `Director`, `Role`, …). PMS represents each as a
/// `<Genre tag="Action"/>`-style child; we only need the human `tag` for display.
public struct Tag: Decodable, Sendable, Identifiable, Hashable {
    public let tag: String
    public var id: String { tag }

    enum CodingKeys: String, CodingKey { case tag }

    public init(tag: String) { self.tag = tag }
}

/// One chapter marker on a `MediaItem`.
///
/// PMS emits `Chapter` elements with millisecond `startTimeOffset`/`endTimeOffset`
/// boundaries and an optional human `tag` (e.g. "Chapter 1").
///
/// NOTE: visionOS's AVKit does NOT expose `AVNavigationMarkersGroup` /
/// `AVPlayerItem.navigationMarkerGroups` (those are tvOS/iOS only), so there are no
/// native scrubber chapter ticks here. Instead the player surfaces these chapters via a
/// custom "Chapters" info-panel tab whose rows seek the `AVPlayer` playhead directly to
/// each chapter's `startTimeOffset`.
public struct Chapter: Decodable, Sendable, Identifiable {
    public let id: Int
    public let tag: String?
    /// Chapter start, in milliseconds from the start of the item.
    public let startTimeOffset: Int?
    /// Chapter end, in milliseconds from the start of the item.
    public let endTimeOffset: Int?
    /// A thumbnail key for the chapter card, when present.
    public let thumb: String?

    enum CodingKeys: String, CodingKey {
        case id
        case tag
        case startTimeOffset
        case endTimeOffset
        case thumb
    }

    public init(id: Int,
                tag: String? = nil,
                startTimeOffset: Int? = nil,
                endTimeOffset: Int? = nil,
                thumb: String? = nil) {
        self.id = id
        self.tag = tag
        self.startTimeOffset = startTimeOffset
        self.endTimeOffset = endTimeOffset
        self.thumb = thumb
    }
}

public struct Media: Decodable, Sendable, Identifiable {
    public let id: Int
    public let duration: Int?
    public let bitrate: Int?
    public let width: Int?
    public let height: Int?
    public let videoCodec: String?
    public let audioCodec: String?
    public let container: String?
    public let part: [Part]

    enum CodingKeys: String, CodingKey {
        case id
        case duration
        case bitrate
        case width
        case height
        case videoCodec
        case audioCodec
        case container
        case part = "Part"
    }

    public init(id: Int,
                duration: Int? = nil,
                bitrate: Int? = nil,
                width: Int? = nil,
                height: Int? = nil,
                videoCodec: String? = nil,
                audioCodec: String? = nil,
                container: String? = nil,
                part: [Part]) {
        self.id = id
        self.duration = duration
        self.bitrate = bitrate
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.container = container
        self.part = part
    }
}

public struct Part: Decodable, Sendable, Identifiable {
    public let id: Int
    public let key: String
    public let duration: Int?
    public let file: String?
    public let size: Int?
    public let container: String?

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case duration
        case file
        case size
        case container
    }

    public init(id: Int,
                key: String,
                duration: Int? = nil,
                file: String? = nil,
                size: Int? = nil,
                container: String? = nil) {
        self.id = id
        self.key = key
        self.duration = duration
        self.file = file
        self.size = size
        self.container = container
    }
}

// MARK: - Hubs (`/hubs`, `/hubs/search`)

public struct HubsResponse: Decodable, Sendable {
    public let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    public struct Container: Decodable, Sendable {
        public let size: Int?
        public let hub: [Hub]
        enum CodingKeys: String, CodingKey {
            case size
            case hub = "Hub"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.size = try c.decodeIfPresent(Int.self, forKey: .size)
            self.hub = try c.decodeIfPresent([Hub].self, forKey: .hub) ?? []
        }
    }
}

public struct Hub: Decodable, Sendable, Identifiable {
    public let hubKey: String?
    public let key: String?
    public let title: String
    public let type: String?
    public let hubIdentifier: String?
    public let size: Int?
    public let metadata: [MediaItem]

    public var id: String { hubIdentifier ?? hubKey ?? key ?? title }

    enum CodingKeys: String, CodingKey {
        case hubKey
        case key
        case title
        case type
        case hubIdentifier
        case size
        case metadata = "Metadata"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hubKey = try c.decodeIfPresent(String.self, forKey: .hubKey)
        self.key = try c.decodeIfPresent(String.self, forKey: .key)
        self.title = try c.decode(String.self, forKey: .title)
        self.type = try c.decodeIfPresent(String.self, forKey: .type)
        self.hubIdentifier = try c.decodeIfPresent(String.self, forKey: .hubIdentifier)
        self.size = try c.decodeIfPresent(Int.self, forKey: .size)
        self.metadata = try c.decodeIfPresent([MediaItem].self, forKey: .metadata) ?? []
    }

    public init(hubKey: String? = nil,
                key: String? = nil,
                title: String,
                type: String? = nil,
                hubIdentifier: String? = nil,
                size: Int? = nil,
                metadata: [MediaItem] = []) {
        self.hubKey = hubKey
        self.key = key
        self.title = title
        self.type = type
        self.hubIdentifier = hubIdentifier
        self.size = size
        self.metadata = metadata
    }
}
