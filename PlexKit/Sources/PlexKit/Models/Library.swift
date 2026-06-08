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
                media: [Media]? = nil) {
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
