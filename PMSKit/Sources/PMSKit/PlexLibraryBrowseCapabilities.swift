import Foundation

/// Plex section sort/filter discovery responses.
///
/// `/library/sections/{sectionId}/filters` and `/sorts` advertise the subset of
/// Plex media-query facets the server/library wants a client to expose. The app
/// maps only these descriptors into visible controls so unsupported facets are
/// hidden instead of being sent and silently ignored.
public struct PlexLibrarySectionFiltersResponse: Decodable, Sendable, Equatable {
    public let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    public struct Container: Decodable, Sendable, Equatable {
        public let directory: [PlexLibraryFilterDescriptor]
        enum CodingKeys: String, CodingKey { case directory = "Directory" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.directory = try c.decodeIfPresent([PlexLibraryFilterDescriptor].self, forKey: .directory) ?? []
        }

        public init(directory: [PlexLibraryFilterDescriptor]) {
            self.directory = directory
        }
    }

    public init(mediaContainer: Container) {
        self.mediaContainer = mediaContainer
    }
}

public struct PlexLibrarySectionSortsResponse: Decodable, Sendable, Equatable {
    public let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    public struct Container: Decodable, Sendable, Equatable {
        public let directory: [PlexLibrarySortDescriptor]
        enum CodingKeys: String, CodingKey { case directory = "Directory" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.directory = try c.decodeIfPresent([PlexLibrarySortDescriptor].self, forKey: .directory) ?? []
        }

        public init(directory: [PlexLibrarySortDescriptor]) {
            self.directory = directory
        }
    }

    public init(mediaContainer: Container) {
        self.mediaContainer = mediaContainer
    }
}

public struct PlexLibraryFilterDescriptor: Decodable, Sendable, Equatable {
    public let filter: String?
    public let filterType: String?
    public let key: String?
    public let title: String?
    public let type: String?

    public init(filter: String?,
                filterType: String? = nil,
                key: String? = nil,
                title: String? = nil,
                type: String? = nil) {
        self.filter = filter
        self.filterType = filterType
        self.key = key
        self.title = title
        self.type = type
    }
}

public struct PlexLibrarySortDescriptor: Decodable, Sendable, Equatable {
    public let key: String?
    public let descKey: String?
    public let defaultDirection: String?
    public let `default`: String?
    public let firstCharacterKey: String?
    public let title: String?

    public init(key: String?,
                descKey: String? = nil,
                defaultDirection: String? = nil,
                default: String? = nil,
                firstCharacterKey: String? = nil,
                title: String? = nil) {
        self.key = key
        self.descKey = descKey
        self.defaultDirection = defaultDirection
        self.default = `default`
        self.firstCharacterKey = firstCharacterKey
        self.title = title
    }
}

/// Filter/sort options that are safe to expose for a library grid.
public struct LibraryBrowseCapabilities: Sendable, Equatable {
    public let sorts: [LibraryBrowseSort]
    public let filters: [LibraryBrowseFilter]

    public init(sorts: [LibraryBrowseSort], filters: [LibraryBrowseFilter]) {
        let orderedSorts = LibraryBrowseSort.allCases.filter { sorts.contains($0) }
        let orderedFilters = LibraryBrowseFilter.allCases.filter { filters.contains($0) }
        self.sorts = orderedSorts.isEmpty ? [.titleAscending] : orderedSorts
        self.filters = orderedFilters.contains(.all) ? orderedFilters : [.all] + orderedFilters
    }

    public static let videoMVP = LibraryBrowseCapabilities(sorts: LibraryBrowseSort.allCases,
                                                           filters: LibraryBrowseFilter.allCases)
    public static let defaultOnly = LibraryBrowseCapabilities(sorts: [.titleAscending],
                                                              filters: [.all])

    public static func plex(filters filterResponse: PlexLibrarySectionFiltersResponse,
                            sorts sortResponse: PlexLibrarySectionSortsResponse) -> LibraryBrowseCapabilities {
        let advertisedFilters = filterResponse.mediaContainer.directory
        let advertisedSorts = sortResponse.mediaContainer.directory
        return LibraryBrowseCapabilities(
            sorts: LibraryBrowseSort.allCases.filter { $0.isSupportedByPlex(advertisedSorts) },
            filters: LibraryBrowseFilter.allCases.filter { $0.isSupportedByPlex(advertisedFilters) })
    }
}

private extension LibraryBrowseSort {
    func isSupportedByPlex(_ descriptors: [PlexLibrarySortDescriptor]) -> Bool {
        switch self {
        case .titleAscending:
            return descriptors.contains { $0.key == "titleSort" }
        case .titleDescending:
            return descriptors.contains { $0.key == "titleSort" && $0.descKey == "titleSort:desc" }
        case .recentlyAdded:
            return descriptors.contains { $0.key == "addedAt" && $0.descKey == "addedAt:desc" }
        case .releaseDate:
            return descriptors.contains { $0.key == "originallyAvailableAt" && $0.descKey == "originallyAvailableAt:desc" }
        case .rating:
            return descriptors.contains { $0.key == "rating" && $0.descKey == "rating:desc" }
        }
    }
}

private extension LibraryBrowseFilter {
    func isSupportedByPlex(_ descriptors: [PlexLibraryFilterDescriptor]) -> Bool {
        switch self {
        case .all:
            return true
        case .unwatched, .watched:
            return descriptors.containsBooleanFilter(named: "unwatched")
        case .inProgress:
            return descriptors.containsBooleanFilter(named: "inProgress")
        }
    }
}

private extension Array where Element == PlexLibraryFilterDescriptor {
    func containsBooleanFilter(named name: String) -> Bool {
        contains { descriptor in
            descriptor.filter == name
                && (descriptor.filterType?.lowercased() == nil || descriptor.filterType?.lowercased() == "boolean")
        }
    }
}
