import Foundation
import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Library catalog loader")
@MainActor
struct LibraryCatalogLoaderTests {
    @Test func plexDescriptorsPreserveNativeOrderIdentityAndKinds() throws {
        let descriptors = [
            PlexSection(key: "2", title: "Shows", type: "show"),
            PlexSection(key: "1", title: "Movies", type: "movie"),
            PlexSection(key: "3", title: "Music", type: "artist"),
        ].map(LibraryCatalogDescriptor.init(plex:))

        #expect(descriptors.map(\.id) == ["plex:2", "plex:1", "plex:3"])
        #expect(descriptors.map(\.sourceID) == ["2", "1", "3"])
        #expect(descriptors.map(\.kind) == [.tvShows, .movies, .music])
        #expect(descriptors.map(\.sourceKind) == ["show", "movie", "artist"])
        #expect(try #require(descriptors[0].plexSection).key == "2")
        #expect(descriptors[0].mediaBrowserLink == nil)
    }

    @Test func mediaBrowserDescriptorsPreserveOrderAndBackendScopedIdentity() throws {
        let views = [
            MediaBrowserLibraryLink(id: "same", title: "Movies", collectionType: "movies"),
            MediaBrowserLibraryLink(id: "music", title: "Audio", collectionType: "music"),
            MediaBrowserLibraryLink(id: "lists", title: "Playlists", collectionType: "playlists"),
        ]
        let jellyfin = views.map { LibraryCatalogDescriptor(mediaBrowser: $0, backend: .jellyfin) }
        let emby = views.map { LibraryCatalogDescriptor(mediaBrowser: $0, backend: .emby) }

        #expect(jellyfin.map(\.sourceID) == ["same", "music", "lists"])
        #expect(jellyfin.map(\.kind) == [.movies, .music, .other])
        #expect(jellyfin[0].id == "jellyfin:same")
        #expect(emby[0].id == "emby:same")
        #expect(try #require(jellyfin[1].mediaBrowserLink).collectionType == "music")
        #expect(jellyfin[0].plexSection == nil)
    }

    @Test func everyLoadPerformsOneFetchAndAddsNoImplicitCache() async throws {
        let calls = TestLockedBox(0)
        let expected = [LibraryCatalogDescriptor(
            plex: PlexSection(key: "1", title: "Movies", type: "movie"))]
        let loader = LibraryCatalogLoader(backend: .plex, authority: BrowseSessionAuthority()) {
            calls.withValue { $0 += 1 }
            return expected
        }

        #expect(try await loader.load() == expected)
        #expect(calls.value == 1)
        #expect(try await loader.load() == expected)
        #expect(calls.value == 2)
    }

    @Test func catalogDescriptorsRebuildExistingLibraryDestinationsWithoutChangingShape() throws {
        let plex = LibraryCatalogDescriptor(
            plex: PlexSection(key: "p", title: "Plex Movies", type: "movie"))
        let jellyfin = LibraryCatalogDescriptor(
            mediaBrowser: MediaBrowserLibraryLink(id: "j", title: "JF Shows",
                                                  collectionType: "tvshows"),
            backend: .jellyfin)
        let emby = LibraryCatalogDescriptor(
            mediaBrowser: MediaBrowserLibraryLink(id: "e", title: "Emby Videos",
                                                  collectionType: "homevideos"),
            backend: .emby)

        let roots = [plex, jellyfin, emby].map(LibraryRootItem.init(catalog:))
        #expect(roots.map(\.id) == ["plex:p", "jellyfin:j", "emby:e"])
        #expect(roots.map(\.kind) == [.movies, .tvShows, .homeVideos])
        if case .plex(let section) = roots[0].destination {
            #expect(section.key == "p")
            #expect(section.type == "movie")
        } else {
            Issue.record("Plex descriptor must retain the Plex destination")
        }
        if case .jellyfin(let view) = roots[1].destination {
            #expect(view.id == "j")
            #expect(view.collectionType == "tvshows")
        } else {
            Issue.record("Jellyfin descriptor must retain the Jellyfin destination")
        }
        if case .emby(let view) = roots[2].destination {
            #expect(view.id == "e")
            #expect(view.collectionType == "homevideos")
        } else {
            Issue.record("Emby descriptor must retain the Emby destination")
        }

        #expect(LibraryGridSource(catalog: plex).capabilityIdentity == "plex:p")
        #expect(LibraryGridSource(catalog: jellyfin).capabilityIdentity == "jellyfin:j")
        #expect(LibraryGridSource(catalog: emby).capabilityIdentity == "emby:e")
    }

    @Test func musicPolicyFiltersOutsideRepositoryAndPreservesNativeCatalogOrder() {
        let catalog = [
            LibraryCatalogDescriptor(
                mediaBrowser: MediaBrowserLibraryLink(id: "movies", title: "Movies",
                                                      collectionType: "movies"),
                backend: .jellyfin),
            LibraryCatalogDescriptor(
                mediaBrowser: MediaBrowserLibraryLink(id: "music-b", title: "Music B",
                                                      collectionType: "music"),
                backend: .jellyfin),
            LibraryCatalogDescriptor(
                mediaBrowser: MediaBrowserLibraryLink(id: "lists", title: "Playlists",
                                                      collectionType: "playlists"),
                backend: .jellyfin),
            LibraryCatalogDescriptor(
                mediaBrowser: MediaBrowserLibraryLink(id: "music-a", title: "Music A",
                                                      collectionType: "music"),
                backend: .jellyfin),
        ]

        #expect(MusicCatalogPolicy.musicLibraries(from: catalog).map(\.id)
                == ["music-b", "music-a"])
        #expect(MusicCatalogPolicy.firstPlaylistViewID(from: catalog) == "lists")

        let plex = [
            LibraryCatalogDescriptor(plex: PlexSection(key: "video", title: "Video", type: "movie")),
            LibraryCatalogDescriptor(plex: PlexSection(key: "audio", title: "Audio", type: "artist")),
        ]
        #expect(MusicCatalogPolicy.musicLibraries(from: plex).map(\.id) == ["audio"])
        #expect(MusicCatalogPolicy.firstPlaylistViewID(from: plex) == nil)
    }

    @Test func searchAndMusicLoadIdentitiesTrackOpaqueAuthorityAndAllowedLibraries() throws {
        let model = AppModel(
            identity: ClientIdentity(clientIdentifier: "device-a", product: "Labstream",
                                     version: "1", deviceName: "Mac"),
            activeBackend: .jellyfin
        )
        model.jellyfinServerBaseURL = URL(string: "https://jellyfin.example.test")!
        model.jellyfinAccessToken = "token"
        model.jellyfinUserID = "user"

        let searchA = SearchLoadIdentity(appModel: model, query: " query ")
        let musicVisibleA = MusicCatalogLoadIdentity(appModel: model,
                                                     allowedLibraryIDs: ["music-a"])
        let musicVisibleB = MusicCatalogLoadIdentity(appModel: model,
                                                     allowedLibraryIDs: ["music-b"])
        #expect(searchA.query == "query")
        #expect(musicVisibleA != musicVisibleB)

        let unchangedDisplayKey = model.activeBrowseSessionKey
        model.identity = ClientIdentity(clientIdentifier: "device-b", product: "Labstream",
                                        version: "1", deviceName: "Mac")
        #expect(model.activeBrowseSessionKey == unchangedDisplayKey)
        #expect(SearchLoadIdentity(appModel: model, query: "query") != searchA)
        #expect(MusicCatalogLoadIdentity(appModel: model,
                                        allowedLibraryIDs: ["music-a"]) != musicVisibleA)
    }

    @Test func catalogClientBindsCoreAndCatalogToOneOpaqueAuthority() throws {
        let model = AppModel(
            identity: ClientIdentity(clientIdentifier: "device-a", product: "Labstream",
                                     version: "1", deviceName: "Mac"),
            activeBackend: .emby
        )
        model.embyServerBaseURL = URL(string: "https://emby.example.test")!
        model.embyAccessToken = "token"
        model.embyUserID = "user"
        let client = try MediaBrowserCatalogClient(appModel: model)
        let authority = try #require(model.activeAuthenticatedBrowseSession).authority
        let matching = LibraryCatalogSnapshot(backend: .emby, authority: authority,
                                              descriptors: [])
        #expect(client.matches(matching))
        #expect(client.isCurrent(in: model))

        model.identity = ClientIdentity(clientIdentifier: "device-b", product: "Labstream",
                                        version: "1", deviceName: "Mac")
        let replacementAuthority = try #require(model.activeAuthenticatedBrowseSession).authority
        let replacement = LibraryCatalogSnapshot(backend: .emby,
                                                  authority: replacementAuthority,
                                                  descriptors: [])
        #expect(!client.matches(replacement))
        #expect(!client.isCurrent(in: model))
    }

    @Test func onlyRepositoryOwnsLoaderForSharedEnumerationSurfaces() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let migrated = [
            "Labstream/Shared/UI/LibraryGridView.swift",
            "Labstream/Shared/UI/LibraryVisibilityEditor.swift",
            "Labstream/Shared/UI/MediaBrowserHomeProvider.swift",
            "Labstream/Platforms/macOS/UI/MacSidebarPolicy.swift",
            "Labstream/Shared/UI/SearchView.swift",
            "Labstream/Shared/Music/MusicLibraryView.swift",
            "Labstream/Shared/Music/MediaBrowserMusicProvider.swift",
            "Labstream/Shared/SystemIntegration/MediaItemEntity.swift",
            "Labstream/Platforms/visionOS/SharePlay/WatchTogetherMediaLookup.swift",
        ]
        for path in migrated {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("catalogRepository.catalog"), "Missing repository adoption in \(path)")
            #expect(!source.contains("LibraryCatalogLoader(appModel:"),
                    "Surface bypasses repository in \(path)")
            #expect(!source.contains("service.libraries()"), "Direct Plex catalog read remains in \(path)")
            #expect(!source.contains("userViewLinks()"), "Direct MediaBrowser catalog read remains in \(path)")
        }

        let repository = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/Backend/LibraryCatalogRepository.swift"), encoding: .utf8)
        #expect(repository.contains("LibraryCatalogLoader(appModel: appModel,"))

        let home = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/UI/MediaBrowserHomeProvider.swift"), encoding: .utf8)
        #expect(!home.contains("homeLibraryLinks"))

        let search = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/UI/SearchView.swift"), encoding: .utf8)
        #expect(!search.contains("searchWithLibraries"))
        #expect(search.contains("searchResults(query: trimmed, views: views)"))

        let musicProvider = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/Music/MediaBrowserMusicProvider.swift"), encoding: .utf8)
        #expect(!musicProvider.contains("musicLibraryLinks()"))

        let shellSources = try [
            "Labstream/Platforms/visionOS/UI/VisionRootShell.swift",
            "Labstream/Platforms/Mobile/UI/MobileRootShell.swift",
            "Labstream/Platforms/macOS/UI/MacRootShell.swift",
            "Labstream/Platforms/tvOS/UI/TVRootShell.swift",
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        #expect(shellSources.contains("SearchView("))
        #expect(shellSources.contains(
            "MusicLibraryView(catalogRepository: runtime.libraryCatalogRepository)"))

        for path in [
            "Labstream/Shared/Backend/MediaBrowserBrowseCore.swift",
            "Labstream/Shared/Backend/Jellyfin/JellyfinBrowseService.swift",
            "Labstream/Shared/Backend/Emby/EmbyBrowseService.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("func searchResults(query: String, limitPerLibrary:"),
                    "Self-enumerating Search API remains in \(path)")
        }

        let contentView = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/App/ContentView.swift"), encoding: .utf8)
        #expect(contentView.contains(
            "libraryCatalogRepository: runtime.libraryCatalogRepository"))

        let visionApp = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Platforms/visionOS/App/Labstream.swift"), encoding: .utf8)
        #expect(visionApp.contains(
            "catalogRepository: runtime.libraryCatalogRepository"))
    }
}
