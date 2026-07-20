#if os(macOS)
import Foundation
import Testing
@testable import Labstream

@Suite("Mac sidebar destination policy")
struct MacSidebarPolicyTests {
    private let server = "plex:server:user"

    @Test func plexFixturePreservesOrderAndSeparatesMusic() {
        let catalog = MacSidebarDestinationPolicy.catalog(
            serverIdentity: server,
            candidates: [
                .init(id: "2", title: "Shows", kind: .tvShows),
                .init(id: "1", title: "Movies", kind: .movies),
                .init(id: "3", title: "Music", kind: .music),
            ],
            hiddenIDs: [],
            supportsPlaylists: true
        )

        #expect(catalog.libraries.map(\.id) == ["2", "1"])
        #expect(catalog.musicLibraries.map(\.id) == ["3"])
        #expect(catalog.musicDestinations == [.home, .artists, .albums, .playlists])
    }

    @Test func jellyfinFixtureFiltersHiddenAndGatesPlaylists() {
        let catalog = MacSidebarDestinationPolicy.catalog(
            serverIdentity: "jellyfin:server:user",
            candidates: [
                .init(id: "movies", title: "Movies", kind: .movies),
                .init(id: "hidden", title: "Shows", kind: .tvShows),
                .init(id: "music", title: "Music", kind: .music),
            ],
            hiddenIDs: ["hidden"],
            supportsPlaylists: false
        )

        #expect(catalog.libraries.map(\.id) == ["movies"])
        #expect(catalog.musicDestinations == [.home, .artists, .albums])
    }

    @Test func embyFixtureHidesMusicSectionWhenMusicLibraryIsHidden() {
        let catalog = MacSidebarDestinationPolicy.catalog(
            serverIdentity: "emby:server:user",
            candidates: [
                .init(id: "shows", title: "TV", kind: .tvShows),
                .init(id: "music", title: "Audio", kind: .music),
            ],
            hiddenIDs: ["music"],
            supportsPlaylists: true
        )

        #expect(catalog.libraries.map(\.id) == ["shows"])
        #expect(catalog.musicLibraries.isEmpty)
        #expect(catalog.musicDestinations.isEmpty)
    }

    @Test func duplicateNamesAreDisambiguatedOnlyForAccessibility() {
        let catalog = MacSidebarDestinationPolicy.catalog(
            serverIdentity: server,
            candidates: [
                .init(id: "movies-a", title: "Media", kind: .movies),
                .init(id: "shows-a", title: "Media", kind: .tvShows),
                .init(id: "unique", title: "Clips", kind: .homeVideos),
            ],
            hiddenIDs: [],
            supportsPlaylists: false
        )

        #expect(catalog.libraries.map(\.title) == ["Media", "Media", "Clips"])
        #expect(catalog.libraries.map(\.accessibilityTitle) == [
            "Media, Movies library, 1 of 2", "Media, TV shows library, 2 of 2", "Clips",
        ])
    }

    @Test func invalidAndForeignRoutesFallBackToHome() {
        let catalog = MacSidebarDestinationPolicy.catalog(
            serverIdentity: server,
            candidates: [.init(id: "movies", title: "Movies", kind: .movies)],
            hiddenIDs: [],
            supportsPlaylists: false
        )

        #expect(MacSidebarDestinationPolicy.restoredRoute(
            .library(serverIdentity: server, id: "removed"), in: catalog
        ) == .home)
        #expect(MacSidebarDestinationPolicy.restoredRoute(
            .library(serverIdentity: "other-server", id: "movies"), in: catalog
        ) == .home)
        #expect(MacSidebarDestinationPolicy.restoredRoute(
            .music(.playlists, serverIdentity: server), in: catalog
        ) == .home)
        #expect(MacSidebarDestinationPolicy.restoredRoute(
            .library(serverIdentity: server, id: "movies"), in: catalog
        ) == .library(serverIdentity: server, id: "movies"))
    }

    @Test func persistenceKeepsIndependentStableServerRoutes() throws {
        let name = "MacSidebarPolicyTests.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let store = MacSidebarSelectionStore(defaults: suite)
        let plexRoute = MacSidebarRouteID.library(serverIdentity: server, id: "movies")
        let embyRoute = MacSidebarRouteID.music(.albums, serverIdentity: "emby:server:user")

        store.save(plexRoute, for: server)
        store.save(embyRoute, for: "emby:server:user")

        #expect(store.route(for: server) == plexRoute)
        #expect(store.route(for: "emby:server:user") == embyRoute)
    }
}
#endif
