import Foundation

/// The backend-neutral portion of a Jellyfin/Emby library request.
///
/// Authentication, URL error mapping, and the final `URLRequest` remain in the backend
/// adapters. Keeping this value ordered is intentional: several MediaBrowser servers accept
/// duplicate query names and URL query order is part of the request compatibility contract.
public struct MediaBrowserLibraryRequestShape: Sendable {
    public let path: String
    public let queryItems: [URLQueryItem]

    public init(path: String, queryItems: [URLQueryItem]) {
        self.path = path
        self.queryItems = queryItems
    }
}

/// Builds the shared wire shape for behavior-identical Jellyfin and Emby library requests.
///
/// The dialect owns every known backend difference in this slice: endpoint paths, query-name
/// casing, and whether the user id is carried by the query. Callers must keep `queryItems` as an
/// ordered array rather than normalizing it into a dictionary.
public struct MediaBrowserLibraryRequestFactory: Sendable {
    public let dialect: MediaBrowserLibraryQueryDialect

    public init(dialect: MediaBrowserLibraryQueryDialect) {
        self.dialect = dialect
    }

    public func userViews(userId: String) -> MediaBrowserLibraryRequestShape {
        var query: [URLQueryItem] = []
        if dialect.includesUserIDInRootQuery {
            query.append(dialect.queryItem(.userId, value: userId))
        }
        query.append(dialect.queryItem(.includeExternalContent, value: "false"))
        return MediaBrowserLibraryRequestShape(
            path: dialect.path(.userViews(userId: userId)),
            queryItems: query
        )
    }

    public func items(userId: String,
                      parentId: String? = nil,
                      recursive: Bool = false,
                      startIndex: Int? = nil,
                      limit: Int? = nil,
                      searchTerm: String? = nil,
                      nameStartsWith: String? = nil,
                      sortBy: String = "SortName",
                      sortOrder: String = "Ascending",
                      includeItemTypes: String = "Movie,Series,Season,Episode,Video",
                      fields: String = MediaBrowserLibraryFields.fullItem,
                      albumArtistIds: String? = nil,
                      artistIds: String? = nil,
                      filters: [String] = []) -> MediaBrowserLibraryRequestShape {
        var query: [URLQueryItem] = []
        if dialect.includesUserIDInRootQuery {
            query.append(dialect.queryItem(.userId, value: userId))
        }
        query.append(dialect.queryItem(.includeItemTypes,
                                       value: "Movie,Series,Season,Episode,Video"))
        query.append(dialect.queryItem(.fields, value: fields))
        query.append(dialect.queryItem(.enableUserData, value: "true"))
        query.append(dialect.queryItem(.sortBy, value: "SortName"))
        query.append(dialect.queryItem(.sortOrder, value: "Ascending"))

        if let parentId { query.append(dialect.queryItem(.parentId, value: parentId)) }
        query.append(dialect.queryItem(.recursive, value: recursive ? "true" : "false"))
        if let startIndex { query.append(dialect.queryItem(.startIndex, value: String(startIndex))) }
        if let limit { query.append(dialect.queryItem(.limit, value: String(limit))) }
        if let searchTerm, !searchTerm.isEmpty {
            query.append(dialect.queryItem(.searchTerm, value: searchTerm))
        }
        if let nameStartsWith, !nameStartsWith.isEmpty {
            query.append(dialect.queryItem(.nameStartsWith, value: nameStartsWith))
        }
        if let albumArtistIds, !albumArtistIds.isEmpty {
            query.append(dialect.queryItem(.albumArtistIds, value: albumArtistIds))
        }
        if let artistIds, !artistIds.isEmpty {
            query.append(dialect.queryItem(.artistIds, value: artistIds))
        }

        replaceQueryItem(.includeItemTypes, with: includeItemTypes, in: &query)
        if !filters.isEmpty {
            query.append(dialect.queryItem(.filters, value: filters.joined(separator: ",")))
        }
        replaceQueryItem(.sortBy, with: sortBy, in: &query)
        replaceQueryItem(.sortOrder, with: sortOrder, in: &query)

        return MediaBrowserLibraryRequestShape(
            path: dialect.path(.items(userId: userId)),
            queryItems: query
        )
    }

    public func albumArtists(userId: String,
                             parentId: String?,
                             startIndex: Int? = nil,
                             limit: Int? = nil,
                             nameStartsWith: String? = nil,
                             sortBy: String = "SortName",
                             sortOrder: String = "Ascending",
                             fields: String = MediaBrowserLibraryFields.gridItem)
        -> MediaBrowserLibraryRequestShape {
        var query = [
            dialect.queryItem(.userId, value: userId),
            dialect.queryItem(.fields, value: fields),
            dialect.queryItem(.enableUserData, value: "true"),
            dialect.queryItem(.enableImages, value: "true"),
            dialect.queryItem(.recursive, value: "true"),
            dialect.queryItem(.sortBy, value: sortBy),
            dialect.queryItem(.sortOrder, value: sortOrder),
        ]
        if let parentId { query.append(dialect.queryItem(.parentId, value: parentId)) }
        if let startIndex { query.append(dialect.queryItem(.startIndex, value: String(startIndex))) }
        if let limit { query.append(dialect.queryItem(.limit, value: String(limit))) }
        if let nameStartsWith, !nameStartsWith.isEmpty {
            query.append(dialect.queryItem(.nameStartsWith, value: nameStartsWith))
        }
        return MediaBrowserLibraryRequestShape(
            path: dialect.path(.albumArtists),
            queryItems: query
        )
    }

    public func playlistItems(userId: String,
                              playlistId: String,
                              startIndex: Int? = nil,
                              limit: Int? = nil,
                              fields: String = MediaBrowserLibraryFields.fullItem)
        -> MediaBrowserLibraryRequestShape {
        var query = [
            dialect.queryItem(.userId, value: userId),
            dialect.queryItem(.fields, value: fields),
            dialect.queryItem(.enableUserData, value: "true"),
            dialect.queryItem(.enableImages, value: "true"),
        ]
        if let startIndex { query.append(dialect.queryItem(.startIndex, value: String(startIndex))) }
        if let limit { query.append(dialect.queryItem(.limit, value: String(limit))) }
        return MediaBrowserLibraryRequestShape(
            path: dialect.path(.playlistItems(playlistId: playlistId)),
            queryItems: query
        )
    }

    private func replaceQueryItem(_ name: MediaBrowserLibraryQueryName,
                                  with value: String,
                                  in query: inout [URLQueryItem]) {
        let wireName = dialect.queryName(name)
        query.removeAll { $0.name == wireName }
        query.append(URLQueryItem(name: wireName, value: value))
    }
}
