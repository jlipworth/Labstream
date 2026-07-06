import Foundation

/// The backend-neutral portion of a Jellyfin/Emby library request.
///
/// Authentication, URL error mapping, and the final `URLRequest` remain in the backend
/// adapters. Keeping this value ordered is intentional: several MediaBrowser servers accept
/// duplicate query names and URL query order is part of the request compatibility contract.
public struct MediaBrowserLibraryRequestShape: Sendable {
    public let path: String
    public let queryItems: [URLQueryItem]
    public let httpMethod: String
    public let accept: String?

    public init(path: String,
                queryItems: [URLQueryItem],
                httpMethod: String = "GET",
                accept: String? = nil) {
        self.path = path
        self.queryItems = queryItems
        self.httpMethod = httpMethod
        self.accept = accept
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
                      sortBy: String? = "SortName",
                      sortOrder: String? = "Ascending",
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
        // A `nil` sort strips the seeded default entirely so the server's own ordering wins
        // (a BoxSet's curated child order has no SortBy equivalent).
        setOrRemoveQueryItem(.sortBy, value: sortBy, in: &query)
        setOrRemoveQueryItem(.sortOrder, value: sortOrder, in: &query)

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

    public func resumeItems(userId: String,
                            parentId: String? = nil,
                            startIndex: Int? = nil,
                            limit: Int = 20,
                            fields: String = MediaBrowserLibraryFields.fullItem)
        -> MediaBrowserLibraryRequestShape {
        var query: [URLQueryItem] = []
        if dialect == .jellyfin { query.append(dialect.queryItem(.userId, value: userId)) }
        query.append(dialect.queryItem(.limit, value: String(limit)))
        query.append(dialect.queryItem(.includeItemTypes, value: "Movie,Episode,Video"))
        query.append(dialect.queryItem(.fields, value: fields))
        query.append(dialect.queryItem(.enableUserData, value: "true"))
        query.append(dialect.queryItem(.enableImages, value: "true"))
        if dialect == .jellyfin {
            query.append(dialect.queryItem(.excludeActiveSessions, value: "false"))
        }
        if let parentId { query.append(dialect.queryItem(.parentId, value: parentId)) }
        if let startIndex { query.append(dialect.queryItem(.startIndex, value: String(startIndex))) }
        return MediaBrowserLibraryRequestShape(
            path: dialect.path(.resume(userId: userId)),
            queryItems: query
        )
    }

    public func nextUp(userId: String,
                       parentId: String? = nil,
                       startIndex: Int? = nil,
                       limit: Int = 20,
                       fields: String = MediaBrowserLibraryFields.fullItem)
        -> MediaBrowserLibraryRequestShape {
        var query = [
            dialect.queryItem(.userId, value: userId),
            dialect.queryItem(.limit, value: String(limit)),
            dialect.queryItem(.fields, value: fields),
            dialect.queryItem(.enableUserData, value: "true"),
            dialect.queryItem(.enableImages, value: "true"),
        ]
        if dialect == .jellyfin {
            query.append(dialect.queryItem(.enableResumable, value: "true"))
        }
        if let parentId { query.append(dialect.queryItem(.parentId, value: parentId)) }
        if let startIndex { query.append(dialect.queryItem(.startIndex, value: String(startIndex))) }
        return MediaBrowserLibraryRequestShape(path: dialect.path(.nextUp), queryItems: query)
    }

    public func latestItems(userId: String,
                            parentId: String? = nil,
                            includeItemTypes: String = "Movie,Episode,Video",
                            limit: Int = 20,
                            fields: String = MediaBrowserLibraryFields.fullItem)
        -> MediaBrowserLibraryRequestShape {
        var query: [URLQueryItem] = []
        if dialect == .jellyfin { query.append(dialect.queryItem(.userId, value: userId)) }
        query.append(dialect.queryItem(.limit, value: String(limit)))
        query.append(dialect.queryItem(.includeItemTypes, value: includeItemTypes))
        query.append(dialect.queryItem(.fields, value: fields))
        query.append(dialect.queryItem(.enableUserData, value: "true"))
        query.append(dialect.queryItem(.enableImages, value: "true"))
        query.append(dialect.queryItem(.groupItems, value: "false"))
        if let parentId { query.append(dialect.queryItem(.parentId, value: parentId)) }
        return MediaBrowserLibraryRequestShape(
            path: dialect.path(.latest(userId: userId)),
            queryItems: query
        )
    }

    public func item(userId: String,
                     itemId: String,
                     fields: String = MediaBrowserLibraryFields.fullItem)
        -> MediaBrowserLibraryRequestShape {
        MediaBrowserLibraryRequestShape(
            path: dialect.path(.item(userId: userId, itemId: itemId)),
            queryItems: [dialect.queryItem(.fields, value: fields)]
        )
    }

    public func markPlayed(userId: String, itemId: String, played: Bool)
        -> MediaBrowserLibraryRequestShape {
        MediaBrowserLibraryRequestShape(
            path: dialect.path(.playedItem(userId: userId, itemId: itemId)),
            queryItems: [],
            httpMethod: played ? "POST" : "DELETE"
        )
    }

    public func textSubtitle(itemId: String,
                             mediaSourceId: String,
                             streamIndex: Int,
                             format: String) -> MediaBrowserLibraryRequestShape {
        let cleanFormat = format.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let ext = ["srt", "vtt"].contains(cleanFormat) ? cleanFormat : "vtt"
        let accept = ext == "srt"
            ? "application/x-subrip,text/plain,*/*"
            : "text/vtt,text/plain,*/*"
        return MediaBrowserLibraryRequestShape(
            path: dialect.path(.textSubtitle(
                itemId: itemId,
                mediaSourceId: mediaSourceId,
                streamIndex: streamIndex,
                extension: ext
            )),
            queryItems: [],
            accept: accept
        )
    }

    public func audioStream(userId: String,
                            deviceId: String,
                            itemId: String,
                            maxStreamingBitrate: Int,
                            containers: String) -> MediaBrowserLibraryRequestShape {
        MediaBrowserLibraryRequestShape(
            path: dialect.path(.audio(itemId: itemId)),
            queryItems: [
                dialect.queryItem(.streamUserId, value: userId),
                dialect.queryItem(.deviceId, value: deviceId),
                dialect.queryItem(.maxStreamingBitrate, value: String(maxStreamingBitrate)),
                dialect.queryItem(.container, value: containers),
                dialect.queryItem(.transcodingContainer, value: "ts"),
                dialect.queryItem(.transcodingProtocol, value: "hls"),
                dialect.queryItem(.audioCodec, value: "aac"),
            ]
        )
    }

    public func image(itemId: String,
                      imageType: String,
                      tag: String?,
                      width: Int? = nil,
                      height: Int? = nil) -> MediaBrowserLibraryRequestShape {
        var query: [URLQueryItem] = []
        if let tag, !tag.isEmpty { query.append(dialect.queryItem(.tag, value: tag)) }
        if let width { query.append(dialect.queryItem(.width, value: String(width))) }
        if let height { query.append(dialect.queryItem(.height, value: String(height))) }
        return MediaBrowserLibraryRequestShape(
            path: dialect.path(.image(itemId: itemId, imageType: imageType)),
            queryItems: query
        )
    }

    public func chapterImage(itemId: String,
                             chapterIndex: Int,
                             tag: String?,
                             width: Int? = nil,
                             height: Int? = nil) -> MediaBrowserLibraryRequestShape {
        var query: [URLQueryItem] = []
        if let tag, !tag.isEmpty { query.append(dialect.queryItem(.tag, value: tag)) }
        if let width { query.append(dialect.queryItem(.fillWidth, value: String(width))) }
        if let height { query.append(dialect.queryItem(.fillHeight, value: String(height))) }
        return MediaBrowserLibraryRequestShape(
            path: dialect.path(.chapterImage(itemId: itemId, chapterIndex: chapterIndex)),
            queryItems: query
        )
    }

    public func activeEncodingStop(deviceId: String,
                                   playSessionId: String) -> MediaBrowserLibraryRequestShape {
        MediaBrowserLibraryRequestShape(
            path: dialect.path(.activeEncodings),
            queryItems: [
                dialect.queryItem(.activeDeviceId, value: deviceId),
                dialect.queryItem(.playSessionId, value: playSessionId),
            ],
            httpMethod: "DELETE"
        )
    }

    private func replaceQueryItem(_ name: MediaBrowserLibraryQueryName,
                                  with value: String,
                                  in query: inout [URLQueryItem]) {
        let wireName = dialect.queryName(name)
        query.removeAll { $0.name == wireName }
        query.append(URLQueryItem(name: wireName, value: value))
    }

    /// Replace the query item when `value` is non-nil, or remove it entirely when `value` is
    /// nil (used to drop a seeded default so the server's own ordering applies).
    private func setOrRemoveQueryItem(_ name: MediaBrowserLibraryQueryName,
                                      value: String?,
                                      in query: inout [URLQueryItem]) {
        if let value {
            replaceQueryItem(name, with: value, in: &query)
        } else {
            let wireName = dialect.queryName(name)
            query.removeAll { $0.name == wireName }
        }
    }
}
