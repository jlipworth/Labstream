import Foundation

/// Cross-backend browse intent for video library grids.
///
/// The UI offers only combinations that every supported backend can express without
/// client-side filtering. Backend adapters map this typed intent to their native wire
/// parameters so unsupported facets are not silently ignored.
public struct LibraryBrowseQuery: Sendable, Equatable, Hashable {
    public var sort: LibraryBrowseSort
    public var filter: LibraryBrowseFilter

    public init(sort: LibraryBrowseSort = .titleAscending,
                filter: LibraryBrowseFilter = .all) {
        self.sort = sort
        self.filter = filter
    }

    public static let `default` = LibraryBrowseQuery()

    public var identityComponent: String {
        "sort=\(sort.rawValue);filter=\(filter.rawValue)"
    }

    /// A-Z offsets are meaningful only for the same unfiltered alphabetical result set
    /// used to compute letter counts.
    public var supportsAlphabetRail: Bool {
        sort.isAlphabetical && filter == .all
    }

    public var mediaBrowserSortBy: String { sort.mediaBrowserSortBy }
    public var mediaBrowserSortOrder: String { sort.mediaBrowserSortOrder }

    public var mediaBrowserFilters: [String] {
        filter.mediaBrowserFilters
    }

    public var plexQueryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "sort", value: sort.plexSort)]
        items.append(contentsOf: filter.plexQueryItems)
        return items
    }
}

public enum LibraryBrowseSort: String, CaseIterable, Identifiable, Sendable {
    case titleAscending
    case titleDescending
    case recentlyAdded
    case releaseDate
    case rating

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .titleAscending:  return "Title A–Z"
        case .titleDescending: return "Title Z–A"
        case .recentlyAdded:   return "Recently Added"
        case .releaseDate:     return "Release Date"
        case .rating:          return "Rating"
        }
    }

    public var isAlphabetical: Bool {
        switch self {
        case .titleAscending: return true
        case .titleDescending, .recentlyAdded, .releaseDate, .rating: return false
        }
    }

    public var plexSort: String {
        switch self {
        case .titleAscending:  return "titleSort"
        case .titleDescending: return "titleSort:desc"
        case .recentlyAdded:   return "addedAt:desc"
        case .releaseDate:     return "originallyAvailableAt:desc"
        case .rating:          return "rating:desc"
        }
    }

    public var mediaBrowserSortBy: String {
        switch self {
        case .titleAscending, .titleDescending:
            return "SortName"
        case .recentlyAdded:
            return "DateCreated"
        case .releaseDate:
            return "PremiereDate"
        case .rating:
            return "CommunityRating"
        }
    }

    public var mediaBrowserSortOrder: String {
        switch self {
        case .titleAscending:
            return "Ascending"
        case .titleDescending, .recentlyAdded, .releaseDate, .rating:
            return "Descending"
        }
    }
}

public enum LibraryBrowseFilter: String, CaseIterable, Identifiable, Sendable {
    // MVP filters are restricted to facets every backend can express without value-picker
    // round trips. Favorite is intentionally deferred: MediaBrowser has `IsFavorite`,
    // but Plex section `/filters` does not advertise a stable favorite facet in the
    // official discovery payload. Genre/year/decade also need a second picker/value
    // discovery layer, so they stay out of this one-tap MVP rather than being silently
    // sent as unsupported query items.
    case all
    case unwatched
    case watched
    case inProgress

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all:        return "All"
        case .unwatched:  return "Unwatched"
        case .watched:    return "Watched"
        case .inProgress: return "In Progress"
        }
    }

    public var plexQueryItems: [URLQueryItem] {
        switch self {
        case .all:
            return []
        case .unwatched:
            return [URLQueryItem(name: "unwatched", value: "1")]
        case .watched:
            // `unwatched=0` is not a facet PMS reliably honors for a watched-only listing.
            // The robust Plex expression is the negated boolean `unwatched!=1`, encoded as a
            // query item whose NAME carries the `!` operator (PlexURLQueryEncoder percent-
            // encodes it to `%21`, which PMS decodes back to the `unwatched!=1` negation).
            return [URLQueryItem(name: "unwatched!", value: "1")]
        case .inProgress:
            return [URLQueryItem(name: "inProgress", value: "1")]
        }
    }

    public var mediaBrowserFilters: [String] {
        switch self {
        case .all:
            return []
        case .unwatched:
            return ["IsUnplayed"]
        case .watched:
            return ["IsPlayed"]
        case .inProgress:
            return ["IsResumable"]
        }
    }
}
