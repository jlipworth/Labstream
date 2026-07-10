import Foundation

/// Backend-neutral search result model. The top level preserves each backend's
/// source-library order; presentation policy is applied by ``presentationGroups``.
public struct SearchResults: Sendable {
    public static let empty = SearchResults(groups: [])

    public let groups: [SearchResultGroup]

    public var isEmpty: Bool {
        groups.allSatisfy { group in group.hubs.allSatisfy { $0.metadata.isEmpty } }
    }

    public init(groups: [SearchResultGroup]) {
        self.groups = groups.compactMap { group in
            let hubs = group.hubs.filter { !$0.metadata.isEmpty }
            guard !hubs.isEmpty else { return nil }
            return SearchResultGroup(id: group.id, libraryID: group.libraryID,
                                     title: group.title, hubs: hubs,
                                     backendID: group.backendID)
        }
    }

    /// Plex `/hubs/search` is the native matcher. Re-bucket its hits by source
    /// library while retaining the discovery order from `/library/sections`.
    public static func plexNativeHubs(_ hubs: [Hub], sections: [Section]) -> SearchResults {
        var sectionTitles: [String: String] = [:]
        var sectionIDs: [Int: String] = [:]
        var discoveredLibraryOrder: [String] = []
        for section in sections {
            let normalizedKey = normalizedPlexSectionKey(section.key) ?? section.key
            sectionTitles[section.key] = section.title
            sectionTitles[normalizedKey] = section.title
            if let id = Int(normalizedKey) { sectionIDs[id] = normalizedKey }
            if !discoveredLibraryOrder.contains(normalizedKey) {
                discoveredLibraryOrder.append(normalizedKey)
            }
        }

        var itemsByLibrary: [String: [MediaItem]] = [:]
        var libraryOrder: [String] = []
        var fallbackItems: [MediaItem] = []
        var seen = Set<String>()

        for item in hubs.flatMap(\.metadata) where seen.insert(item.ratingKey).inserted {
            let sectionKey = normalizedPlexSectionKey(item.librarySectionKey)
                ?? item.librarySectionID.flatMap { sectionIDs[$0] }
                ?? item.librarySectionID.map(String.init)
            guard let sectionKey else {
                fallbackItems.append(item)
                continue
            }
            if itemsByLibrary[sectionKey] == nil { libraryOrder.append(sectionKey) }
            itemsByLibrary[sectionKey, default: []].append(item)
        }

        // Known libraries follow server discovery order, not search relevance. Keep
        // attributed results from an unknown/new section visible afterward in their
        // first-encounter order rather than dropping them.
        let knownLibraryKeys = Set(discoveredLibraryOrder)
        let orderedLibraryKeys = discoveredLibraryOrder.filter { itemsByLibrary[$0] != nil }
            + libraryOrder.filter { !knownLibraryKeys.contains($0) }
        var groups = orderedLibraryKeys.compactMap { sectionKey in
            SearchResultGroup.mediaBrowserLibrary(
                backendID: .plex, libraryID: sectionKey,
                title: sectionTitles[sectionKey] ?? "Library \(sectionKey)",
                items: itemsByLibrary[sectionKey] ?? [])
        }
        let fallbackHubs = SearchResultGrouping.mediaTypeHubs(
            items: fallbackItems, identifierPrefix: "plex-unattributed")
        if !fallbackHubs.isEmpty {
            groups.append(SearchResultGroup(id: "plex-library-unattributed", libraryID: nil,
                                            title: "All Plex Libraries", hubs: fallbackHubs))
        }
        return SearchResults(groups: groups)
    }

    private static func normalizedPlexSectionKey(_ rawKey: String?) -> String? {
        guard let rawKey else { return nil }
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let index = parts.lastIndex(of: "sections"),
           parts.indices.contains(parts.index(after: index)) {
            return parts[parts.index(after: index)]
        }
        return parts.last ?? trimmed
    }

    /// Pure, deterministic UI projection. It deliberately preserves group and
    /// hub order: Plex callers supply discovery order, while MediaBrowser callers
    /// supply stable user-view order. Music stays inside its source library.
    public var presentationGroups: [SearchPresentationGroup] {
        groups.map { group in
            SearchPresentationGroup(id: group.id, libraryID: group.libraryID,
                                    title: group.title,
                                    sections: group.hubs.map(SearchPresentationSection.init))
        }
    }
}

public struct SearchResultGroup: Identifiable, Sendable {
    public let id: String
    /// Originating backend (`plex`/`jellyfin`/`emby`). Carried so callers can scope
    /// paged "view all" queries to the right backend without re-deriving it.
    public let backendID: String?
    /// Plex section key or Jellyfin/Emby user-view id. Kept explicit so music
    /// destinations retain their source context instead of falling back to an
    /// unscoped artist children query.
    public let libraryID: String?
    public let title: String
    public let hubs: [Hub]

    public init(id: String, libraryID: String?, title: String, hubs: [Hub],
                backendID: String? = nil) {
        self.id = id
        self.backendID = backendID
        self.libraryID = libraryID
        self.title = title
        self.hubs = hubs
    }

    public static func mediaBrowserLibrary(backendID: MediaBackendID, libraryID: String,
                                           title: String, items: [MediaItem]) -> SearchResultGroup? {
        let hubs = SearchResultGrouping.mediaTypeHubs(
            items: items, identifierPrefix: "\(backendID.rawValue)-\(libraryID)")
        guard !hubs.isEmpty else { return nil }
        return SearchResultGroup(id: "\(backendID.rawValue)-library-\(libraryID)",
                                 libraryID: libraryID, title: title, hubs: hubs,
                                 backendID: backendID.rawValue)
    }
}

/// Render kinds let SwiftUI retain specialized playable song rows without
/// hard-coding presentation order in the view.
public enum SearchPresentationKind: String, Sendable {
    case standard, artists, albums, songs, playlists
}

public struct SearchPresentationGroup: Identifiable, Sendable {
    public let id: String
    public let libraryID: String?
    public let title: String
    public let sections: [SearchPresentationSection]
}

public struct SearchPresentationSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let kind: SearchPresentationKind
    public let items: [MediaItem]

    fileprivate init(hub: Hub) {
        id = hub.id
        title = hub.title
        items = hub.metadata
        switch hub.metadata.first?.kind {
        case .artist: kind = .artists
        case .album: kind = .albums
        case .track: kind = .songs
        // Only AUDIO playlists get the music treatment (SearchMusicRail →
        // PlaylistDetailView's track loader). Video/photo playlists route through the
        // standard hub to DetailView's video flow. Buckets are homogeneous per
        // `MediaTypeBucket`, so the first item's flavor speaks for the hub.
        case .playlist:
            kind = (hub.metadata.first?.isAudioPlaylist ?? true) ? .playlists : .standard
        default: kind = .standard
        }
    }
}

public enum SearchResultGrouping {
    public static func mediaTypeHubs(items: [MediaItem], identifierPrefix: String) -> [Hub] {
        var buckets: [MediaTypeBucket: [MediaItem]] = [:]
        var seenByBucket: [MediaTypeBucket: Set<String>] = [:]
        for item in items {
            let bucket = MediaTypeBucket(item: item)
            var seen = seenByBucket[bucket, default: []]
            guard seen.insert(item.ratingKey).inserted else { continue }
            seenByBucket[bucket] = seen
            buckets[bucket, default: []].append(item)
        }
        return MediaTypeBucket.displayOrder.compactMap { bucket in
            guard let media = buckets[bucket], !media.isEmpty else { return nil }
            return Hub(title: bucket.title, type: bucket.hubType,
                       hubIdentifier: "\(identifierPrefix)-\(bucket.rawValue)",
                       size: media.count, metadata: media)
        }
    }
}

private enum MediaTypeBucket: String, Hashable {
    case movies, shows, seasons, episodes, videos, videoPlaylists
    case collections, trailersAndExtras
    case artists, albums, songs, playlists, other

    static let displayOrder: [MediaTypeBucket] = [
        .movies, .shows, .seasons, .episodes, .videos, .videoPlaylists,
        .collections, .trailersAndExtras,
        .artists, .albums, .songs, .playlists, .other,
    ]

    init(item: MediaItem) {
        switch item.kind {
        case .movie: self = .movies
        case .show: self = .shows
        case .season: self = .seasons
        case .episode: self = .episodes
        case .artist: self = .artists
        case .album: self = .albums
        case .track: self = .songs
        // Split playlist flavors into separate buckets so each hub is homogeneous:
        // audio playlists join the music `.playlists` bucket; video/photo playlists
        // get their own bucket that presents through the standard/video path.
        case .playlist: self = item.isAudioPlaylist ? .playlists : .videoPlaylists
        case .collection: self = .collections
        case .trailer, .extra: self = .trailersAndExtras
        case .other(let raw) where raw == "video": self = .videos
        case .other: self = .other
        }
    }

    var title: String {
        switch self {
        case .movies: "Movies"; case .shows: "Shows"; case .seasons: "Seasons"
        case .episodes: "Episodes"; case .videos: "Videos"
        case .videoPlaylists: "Playlists"; case .collections: "Collections"
        case .trailersAndExtras: "Trailers & Extras"; case .artists: "Artists"
        case .albums: "Albums"; case .songs: "Songs"; case .playlists: "Playlists"
        case .other: "Other Results"
        }
    }

    var hubType: String {
        switch self {
        case .movies: "movie"; case .shows: "show"; case .seasons: "season"
        case .episodes: "episode"; case .videos: "video"
        case .videoPlaylists: "playlist"; case .collections: "collection"
        case .trailersAndExtras: "extra"; case .artists: "artist"
        case .albums: "album"; case .songs: "track"; case .playlists: "playlist"
        case .other: "search"
        }
    }
}
