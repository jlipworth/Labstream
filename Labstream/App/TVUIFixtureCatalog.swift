#if os(tvOS) && DEBUG
import Foundation
import PMSKit

/// Small synthetic catalog used only by tvOS UI-test launches. It exercises the real Home,
/// Libraries, navigation, detail, and backend-switching views without network credentials or a
/// parallel mock UI. Production launches never consult this catalog.
@MainActor
enum TVUIFixtureCatalog {
    struct HomeContent {
        let hubs: [Hub]
        let mediaBrowserLibraries: [MediaBrowserHomeLibraryLink]
        let mediaBrowserRails: [MediaBrowserHomeRail]
    }

    static var isBrowseEnabled: Bool {
        TVUITestLaunchConfiguration.usesBrowseFixture
    }

    static func homeContent(for backend: MediaBackendKind) -> HomeContent? {
        guard isBrowseEnabled else { return nil }
        let rows = fixtureItems(backend: backend)
        if backend == .plex {
            return HomeContent(
                hubs: [
                    Hub(title: "Continue Watching", hubIdentifier: "fixture-resume", metadata: Array(rows.prefix(4))),
                    Hub(title: "Recently Added", hubIdentifier: "fixture-latest", metadata: rows),
                ],
                mediaBrowserLibraries: [],
                mediaBrowserRails: [])
        }

        let libraries = mediaBrowserLibraries
        return HomeContent(
            hubs: [],
            mediaBrowserLibraries: libraries,
            mediaBrowserRails: [
                MediaBrowserHomeRail(id: "fixture-resume", title: "Continue Watching",
                                     items: Array(rows.prefix(4)), destination: nil),
                MediaBrowserHomeRail(id: "fixture-latest", title: "Recently Added Movies",
                                     items: rows, destination: nil),
            ])
    }

    static func libraryRootItems(for backend: MediaBackendKind) -> [LibraryRootItem]? {
        guard isBrowseEnabled else { return nil }
        switch backend {
        case .plex:
            return [
                LibraryRootItem(plex: PlexSection(key: "1", title: "Movies", type: "movie")),
                LibraryRootItem(plex: PlexSection(key: "2", title: "TV Shows", type: "show")),
            ]
        case .jellyfin:
            return mediaBrowserLibraries.map {
                LibraryRootItem(jellyfin: MediaBrowserLibraryLink(id: $0.id,
                                                                  title: $0.title,
                                                                  collectionType: $0.collectionType))
            }
        case .emby:
            return mediaBrowserLibraries.map {
                LibraryRootItem(emby: MediaBrowserLibraryLink(id: $0.id,
                                                              title: $0.title,
                                                              collectionType: $0.collectionType))
            }
        }
    }

    private static let mediaBrowserLibraries = [
        MediaBrowserHomeLibraryLink(id: "movies", title: "Movies", collectionType: "movies"),
        MediaBrowserHomeLibraryLink(id: "shows", title: "TV Shows", collectionType: "tvshows"),
    ]

    private static func fixtureItems(backend: MediaBackendKind) -> [MediaItem] {
        let prefix = backend.rawValue
        return [
            MediaItem(ratingKey: "\(prefix)-orbit", title: "The Long Orbit", type: "movie",
                      duration: 7_140_000, viewOffset: 2_160_000, year: 2026,
                      summary: "A research crew follows a signal beyond the mapped edge of the solar system, where every transmission challenges what they thought they knew about the mission and one another.",
                      media: [
                        Media(id: 1, bitrate: 24_000, width: 3_840, height: 2_160,
                              videoCodec: "hevc", audioCodec: "eac3", container: "mkv", part: []),
                        Media(id: 2, bitrate: 8_000, width: 1_920, height: 1_080,
                              videoCodec: "h264", audioCodec: "aac", container: "mp4", part: []),
                      ],
                      chapters: [
                        Chapter(id: 1, tag: "Departure", startTimeOffset: 0),
                        Chapter(id: 2, tag: "The Signal", startTimeOffset: 1_800_000),
                        Chapter(id: 3, tag: "Beyond the Map", startTimeOffset: 4_200_000),
                      ],
                      rating: 8.2, contentRating: "PG-13", tagline: "Some signals should stay distant.",
                      genres: [Tag(tag: "Science Fiction"), Tag(tag: "Drama")],
                      roles: [Tag(tag: "Mara Voss"), Tag(tag: "Elias North"), Tag(tag: "Sana Vale")],
                      directors: [Tag(tag: "Iris Chen")],
                      studios: [Tag(tag: "Labstream Pictures")]),
            MediaItem(ratingKey: "\(prefix)-harbor", title: "Harbor Lights", type: "movie",
                      duration: 6_540_000, year: 2025,
                      summary: "A family returns to the island where their story began."),
            MediaItem(ratingKey: "\(prefix)-atlas", title: "Atlas Station", type: "show",
                      year: 2026, summary: "Engineers keep an impossible station alive."),
            MediaItem(ratingKey: "\(prefix)-quiet", title: "A Quiet Current", type: "movie",
                      duration: 5_820_000, year: 2024),
            MediaItem(ratingKey: "\(prefix)-north", title: "Northbound", type: "movie",
                      duration: 6_060_000, year: 2026),
            MediaItem(ratingKey: "\(prefix)-signal", title: "Signal House", type: "show",
                      year: 2025),
        ]
    }
}
#endif
