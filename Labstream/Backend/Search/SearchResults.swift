import Foundation
import PMSKit

/// Backend-neutral search presentation model.
///
/// The top level is a source-library section (Movies, TV Shows, Music, etc.). Each
/// library owns child hubs grouped by native/type result kind. Match semantics remain
/// native to each backend; this layer only normalizes presentation shape (#103).
struct SearchResults: Sendable {
    static let empty = SearchResults(groups: [])

    let groups: [SearchResultGroup]

    var isEmpty: Bool {
        groups.allSatisfy { group in group.hubs.allSatisfy { $0.metadata.isEmpty } }
    }

    init(groups: [SearchResultGroup]) {
        self.groups = groups.compactMap { group in
            let hubs = group.hubs.filter { !$0.metadata.isEmpty }
            guard !hubs.isEmpty else { return nil }
            return SearchResultGroup(id: group.id, title: group.title, hubs: hubs)
        }
    }

    /// Plex `/hubs/search` is still the native matcher, but its hits normally carry
    /// `librarySectionKey`/`librarySectionID`. Re-bucket those hits by source library
    /// so Plex, Jellyfin, and Emby all render the same top-level shape (#103). If PMS
    /// omits library attribution for a hit, keep it visible in a fallback group.
    static func plexNativeHubs(_ hubs: [Hub], sections: [Section]) -> SearchResults {
        let sectionTitles = Dictionary(uniqueKeysWithValues: sections.map { ($0.key, $0.title) })
        let sectionIDs = Dictionary(uniqueKeysWithValues: sections.compactMap { section -> (Int, String)? in
            guard let id = Int(section.key) else { return nil }
            return (id, section.key)
        })

        var itemsByLibrary: [String: [MediaItem]] = [:]
        var libraryOrder: [String] = []
        var fallbackItems: [MediaItem] = []
        var seen = Set<String>()

        for item in hubs.flatMap(\.metadata) where seen.insert(item.ratingKey).inserted {
            let sectionKey = item.librarySectionKey
                ?? item.librarySectionID.flatMap { sectionIDs[$0] }
                ?? item.librarySectionID.map(String.init)
            guard let sectionKey else {
                fallbackItems.append(item)
                continue
            }
            if itemsByLibrary[sectionKey] == nil { libraryOrder.append(sectionKey) }
            itemsByLibrary[sectionKey, default: []].append(item)
        }

        var groups = libraryOrder.compactMap { sectionKey -> SearchResultGroup? in
            SearchResultGroup.mediaBrowserLibrary(backendID: "plex",
                                                  libraryID: sectionKey,
                                                  title: sectionTitles[sectionKey] ?? "Library \(sectionKey)",
                                                  items: itemsByLibrary[sectionKey] ?? [])
        }
        if let fallback = SearchResultGroup.mediaBrowserLibrary(backendID: "plex",
                                                                libraryID: "unattributed",
                                                                title: "All Plex Libraries",
                                                                items: fallbackItems) {
            groups.append(fallback)
        }
        return SearchResults(groups: groups)
    }
}

struct SearchResultGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let hubs: [Hub]

    static func mediaBrowserLibrary(backendID: String,
                                    libraryID: String,
                                    title: String,
                                    items: [MediaItem]) -> SearchResultGroup? {
        let hubs = SearchResultGrouping.mediaTypeHubs(items: items,
                                                      identifierPrefix: "\(backendID)-\(libraryID)")
        guard !hubs.isEmpty else { return nil }
        return SearchResultGroup(id: "\(backendID)-library-\(libraryID)",
                                 title: title,
                                 hubs: hubs)
    }
}

enum SearchResultGrouping {
    static func mediaTypeHubs(items: [MediaItem], identifierPrefix: String) -> [Hub] {
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
            return Hub(title: bucket.title,
                       type: bucket.hubType,
                       hubIdentifier: "\(identifierPrefix)-\(bucket.rawValue)",
                       size: media.count,
                       metadata: media)
        }
    }
}

private enum MediaTypeBucket: String, Hashable, CaseIterable {
    case movies
    case shows
    case seasons
    case episodes
    case videos
    case artists
    case albums
    case songs
    case playlists
    case other

    static let displayOrder: [MediaTypeBucket] = [
        .movies, .shows, .seasons, .episodes, .videos,
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
        case .playlist: self = .playlists
        case .other(let raw) where raw == "video": self = .videos
        case .other: self = .other
        }
    }

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .shows: return "Shows"
        case .seasons: return "Seasons"
        case .episodes: return "Episodes"
        case .videos: return "Videos"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        case .playlists: return "Playlists"
        case .other: return "Other Results"
        }
    }

    var hubType: String {
        switch self {
        case .movies: return "movie"
        case .shows: return "show"
        case .seasons: return "season"
        case .episodes: return "episode"
        case .videos: return "video"
        case .artists: return "artist"
        case .albums: return "album"
        case .songs: return "track"
        case .playlists: return "playlist"
        case .other: return "search"
        }
    }
}
