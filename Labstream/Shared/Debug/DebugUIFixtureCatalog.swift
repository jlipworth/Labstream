#if DEBUG
import Foundation
import SwiftUI
import PMSKit

/// Small synthetic catalog used only by DEBUG agent/UI-test launches. It exercises the real Home,
/// Libraries, navigation, and detail views without network credentials or a parallel mock UI.
/// Production launches never compile this catalog.
@MainActor
enum DebugUIFixtureCatalog {
    struct HomeContent {
        let hubs: [Hub]
        let mediaBrowserLibraries: [MediaBrowserHomeLibraryLink]
        let mediaBrowserRails: [MediaBrowserHomeRail]
    }

    static var isBrowseEnabled: Bool {
        DebugUITestLaunchConfiguration.usesBrowseFixture
    }

    /// Container and rows used by the real `ContainerBrowserView` in the season-surface UI
    /// contract test. Keeping this catalog-only means the test exercises shipping UI without
    /// credentials, a server, or a parallel mock implementation.
    static let seasonContainer = MediaItem(
        ratingKey: "tv-season-surface",
        title: "Season 1",
        type: "season",
        grandparentTitle: "Fixture Series",
        parentTitle: "Fixture Series",
        index: 1
    )

    static func containerChildren(for container: MediaItem) -> [MediaItem]? {
        guard DebugUITestLaunchConfiguration.fixtureKind == .season,
              container.ratingKey == seasonContainer.ratingKey else { return nil }
        return [
            MediaItem(ratingKey: "tv-season-surface-e1", title: "The First Stream",
                      type: "episode", duration: 2_700_000,
                      grandparentTitle: "Fixture Series", parentTitle: "Season 1",
                      parentIndex: 1, index: 1),
            MediaItem(ratingKey: "tv-season-surface-e2", title: "Nothing Stored Locally",
                      type: "episode", duration: 2_760_000,
                      grandparentTitle: "Fixture Series", parentTitle: "Season 1",
                      parentIndex: 1, index: 2),
        ]
    }

    static func homeContent(for backend: MediaBackendKind) -> HomeContent? {
        guard isBrowseEnabled else { return nil }
        let rows = fixtureItems(backend: backend)
        if backend == .plex {
            var hubs = [
                Hub(title: "Continue Watching", hubIdentifier: "fixture-resume", metadata: Array(rows.prefix(4))),
                // A recently-added key makes this rail View All–eligible, so fixture
                // tests exercise the tvOS trailing View All card in the lazy rail.
                Hub(key: "/library/sections/1/recentlyAdded", title: "Recently Added",
                    hubIdentifier: "fixture-latest", metadata: rows),
            ]
            hubs.append(contentsOf: mixedShapeHubs(backend: backend))
            // Enough additional shelves that Home's LazyVStack must realize and
            // derealize rows during vertical traversal — the regime where SwiftUI's
            // DynamicContainer item removal runs (2026-07-21 manual-session crash).
            for shelf in 1...6 {
                hubs.append(Hub(title: shelfTitles[shelf - 1],
                                hubIdentifier: "fixture-shelf-\(shelf)",
                                metadata: shelfItems(backend: backend, shelf: shelf)))
            }
            return HomeContent(
                hubs: hubs,
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
            ] + mixedShapeHubs(backend: backend).map {
                MediaBrowserHomeRail(id: $0.id, title: $0.title,
                                     items: $0.metadata, destination: nil)
            })
    }

    /// Reproduces #360 without a server: the leading movie is landscape, later
    /// cards alternate aspect and missing metadata, and episode art mixes stills/posters.
    static func mixedShapeHubs(backend: MediaBackendKind) -> [Hub] {
        let prefix = backend.rawValue
        let shelves: [(String, String)] = [
            ("movie", "Mixed Artwork Movies"), ("show", "Mixed Artwork Shows"),
            ("episode", "Mixed Artwork Episodes"),
        ]
        return shelves.map { kind, title in
            let items: [MediaItem] = (0..<8).map { index in
                let isEpisode = kind == "episode"
                let isLandscape = index.isMultiple(of: 2)
                let itemTitle = "\(isEpisode ? "Chapter" : "Horizon") \(index + 1)"
                let artwork = "fixture://home-artwork/\(isLandscape ? "landscape" : "portrait")"
                return MediaItem(ratingKey: "\(prefix)-shapes-\(kind)-\(index)",
                                 title: itemTitle, type: kind,
                                 year: isLandscape ? 2026 : nil, thumb: artwork,
                                 grandparentTitle: isEpisode ? "Distant Horizons" : nil,
                                 parentIndex: isEpisode ? 1 : nil,
                                 index: isEpisode ? index + 1 : nil,
                                 primaryImageAspectRatio: isLandscape ? 16.0 / 9.0 : 2.0 / 3.0)
            }
            return Hub(title: title, type: kind, hubIdentifier: "fixture-shapes-\(kind)",
                       metadata: items)
        }
    }

    /// Real raster sources make crop versus stretch visible: the white circle must
    /// remain round in either shelf shape. These paths never make network requests.
    static func homeArtwork(for path: String?) -> Image? {
        guard isBrowseEnabled else { return nil }
        switch path {
        case "fixture://home-artwork/landscape": return landscapeArtwork
        case "fixture://home-artwork/portrait": return portraitArtwork
        default: return nil
        }
    }

    private static let landscapeArtwork = makeHomeArtwork(width: 320, height: 180)
    private static let portraitArtwork = makeHomeArtwork(width: 120, height: 180)

    private static func makeHomeArtwork(width: CGFloat, height: CGFloat) -> Image? {
        let renderer = ImageRenderer(content:
            ZStack {
                LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white).frame(width: 70, height: 70)
            }.frame(width: width, height: height))
        guard let image = renderer.cgImage else { return nil }
        return Image(decorative: image, scale: 1)
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

    /// Title-substring matches over the fixture rows, so agent runs can drive the real Search
    /// root and its pushed detail without a server.
    static func searchResults(query: String, backend: MediaBackendKind) -> SearchResults? {
        guard isBrowseEnabled else { return nil }
        let matches = fixtureItems(backend: backend).filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
        return SearchResults(groups: [
            SearchResultGroup(id: "fixture-search", libraryID: "1", title: "Movies",
                              hubs: [Hub(title: "Movies", hubIdentifier: "fixture-search-movies",
                                         metadata: matches)],
                              backendID: backend.rawValue),
        ])
    }

    private static let mediaBrowserLibraries = [
        MediaBrowserHomeLibraryLink(id: "movies", title: "Movies", collectionType: "movies"),
        MediaBrowserHomeLibraryLink(id: "shows", title: "TV Shows", collectionType: "tvshows"),
    ]

    /// Store-safe, plainly fictional merchandising copy. Keep test mechanics in identifiers rather
    /// than visible labels so credential-free screenshots still represent the shipping experience.
    private static let shelfTitles = [
        "Recommended For You", "Science Fiction", "Award Winners",
        "New Releases", "Popular Movies", "Stories From the Sea",
    ]

    private static let syntheticShelfItemTitles = [
        "Glass Horizon", "Echoes of Titan", "The Last Meridian", "Paper Moons",
        "Midnight Current", "Arctic Signal", "Second Sunrise", "The Quiet Engine",
        "Distant Harbor", "After the Aurora", "Redwood Sky", "The Far Lantern",
    ]

    private static func shelfItems(backend: MediaBackendKind, shelf: Int) -> [MediaItem] {
        let prefix = backend.rawValue
        return (0..<12).map { index in
            MediaItem(ratingKey: "\(prefix)-shelf\(shelf)-\(index)",
                      title: syntheticShelfItemTitles[
                        (index + shelf - 1) % syntheticShelfItemTitles.count
                      ],
                      type: "movie",
                      duration: 5_400_000, year: 2020 + (index % 6))
        }
    }

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
