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
@Suite("Mac explicit navigation transitions")
@MainActor
struct MacNavigationPolicyTests {
    @Test func homeActivationAlwaysReachesRoot() {
        for previous: MacSidebarDestination in [.home, .offline, .library("movies"), .music(.albums)] {
            let navigation = populatedCoordinator()
            MacNavigationPolicy.activate(.home, from: previous, navigation: navigation)
            #expect(navigation.selection == .home)
            #expect(navigation.homePath.isEmpty)
            #expect(navigation.searchPath.isEmpty)
            #expect(navigation.musicPath.count == 2)
            #expect(navigation.librariesPath.count == 2)
        }
    }

    @Test func everyExplicitMusicPivotIncludingReselectionReachesRoot() {
        for pivot: MusicPivot in [.home, .artists, .albums, .playlists] {
            for previous: MacSidebarDestination in [.home, .music(pivot), .music(.artists)] {
                let navigation = populatedCoordinator()
                MacNavigationPolicy.activate(.music(pivot), from: previous, navigation: navigation)
                #expect(navigation.selection == .music)
                #expect(navigation.musicPath.isEmpty)
                #expect(navigation.searchPath.isEmpty)
                #expect(navigation.homePath.count == 2)
            }
        }
    }

    @Test func destinationsDismissSearchEvenOnReselectionAndKeepLibraryHistory() {
        for destination: MacSidebarDestination in [.offline, .library("movies")] {
            let navigation = populatedCoordinator()
            MacNavigationPolicy.activate(destination, from: destination, navigation: navigation)
            #expect(navigation.searchPath.isEmpty)
            #expect(navigation.selection == MacNavigationPolicy.destination(for: destination))
            #expect(navigation.librariesPath.count == 2)
        }
        let navigation = populatedCoordinator()
        MacNavigationPolicy.activate(.library("shows"), from: .library("movies"), navigation: navigation)
        #expect(navigation.librariesPath.isEmpty)
    }

    @Test func searchBackPopsOneLevelBeforeRequestingDismissal() {
        let navigation = populatedCoordinator()
        #expect(!MacNavigationPolicy.navigateBack(isSearching: true, selection: .home, navigation: navigation))
        #expect(navigation.searchPath.count == 1)
        #expect(!MacNavigationPolicy.navigateBack(isSearching: true, selection: .home, navigation: navigation))
        #expect(navigation.searchPath.isEmpty)
        #expect(MacNavigationPolicy.navigateBack(isSearching: true, selection: .home, navigation: navigation))
        #expect(navigation.homePath.count == 2)
    }

    @Test func browseBackOnlyPopsItsOwnStack() {
        let navigation = populatedCoordinator()
        #expect(!MacNavigationPolicy.navigateBack(isSearching: false, selection: .music(.albums), navigation: navigation))
        #expect(navigation.musicPath.count == 1)
        #expect(navigation.homePath.count == 2)
        #expect(navigation.searchPath.count == 2)
    }

    @Test func commandValidationMatchesAuthenticationPlaybackAndActualBackAction() {
        let navigation = RootNavigationCoordinator()
        func availability(authenticated: Bool = true, playing: Bool = false, searching: Bool = false) -> MacNavigationPolicy.CommandAvailability {
            MacNavigationPolicy.availability(isAuthenticated: authenticated, isPlayingVideo: playing,
                                             isSearching: searching, selection: .home, navigation: navigation)
        }
        #expect(availability() == .init(canNavigateBack: false, canSelectDestination: true))
        #expect(availability(searching: true) == .init(canNavigateBack: true, canSelectDestination: true))
        navigation.homePath.append("detail")
        #expect(availability().canNavigateBack)
        for searching in [false, true] {
            #expect(availability(playing: true, searching: searching) == .init())
            #expect(availability(authenticated: false, searching: searching) == .init())
        }
    }

    @Test func searchQueryEditsStillRevealNewResultsAfterBack() {
        let navigation = populatedCoordinator()
        _ = MacNavigationPolicy.navigateBack(isSearching: true, selection: .home, navigation: navigation)
        navigation.searchQueryDidChange(from: "first", to: " first ")
        #expect(navigation.searchPath.count == 1)
        navigation.searchQueryDidChange(from: "first", to: "second")
        #expect(navigation.searchPath.isEmpty)
        navigation.searchPath.append("detail")
        navigation.focusSearchFromCommand(selectsSearch: false)
        #expect(navigation.searchPath.isEmpty)
    }

    private func populatedCoordinator() -> RootNavigationCoordinator {
        let navigation = RootNavigationCoordinator()
        for destination: AppDestination in [.home, .libraries, .music, .search] {
            for _ in 0..<2 {
                navigation.push(.init(ratingKey: "fixture", title: "Fixture", type: "movie"), on: destination)
            }
        }
        return navigation
    }
}
#endif
