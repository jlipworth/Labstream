import Testing
import Foundation
@testable import PMSKit

@Suite("Library visibility (GH #104)")
struct LibraryVisibilityTests {

    // Throwaway defaults suite so tests never touch the real UserDefaults.
    private func makeStore() -> (LibraryVisibilityStore, UserDefaults) {
        let suiteName = "test.libraryVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (LibraryVisibilityStore(defaults: defaults), defaults)
    }

    private struct Lib: Equatable { let id: String; let title: String; let kind: String }

    // MARK: Backend key derivation

    @Test func backendKeyUsesServerIDWhenPresent() {
        #expect(LibraryVisibility.backendKey(backend: .plex, serverID: "ABC", baseURLHost: "host") == "plex:ABC")
        #expect(LibraryVisibility.backendKey(backend: .jellyfin, serverID: "S1", baseURLHost: nil) == "jellyfin:S1")
        #expect(LibraryVisibility.backendKey(backend: .emby, serverID: "E9", baseURLHost: nil) == "emby:E9")
    }

    @Test func backendKeyFallsBackToHostForLegacySessions() {
        #expect(LibraryVisibility.backendKey(backend: .jellyfin, serverID: nil, baseURLHost: "jelly.example.internal")
                == "jellyfin:jelly.example.internal")
        #expect(LibraryVisibility.backendKey(backend: .emby, serverID: "  ", baseURLHost: "emby.example.internal")
                == "emby:emby.example.internal")
    }

    @Test func backendKeyIsNilWhenIdentityUnresolvable() {
        #expect(LibraryVisibility.backendKey(backend: .plex, serverID: nil, baseURLHost: nil) == nil)
        #expect(LibraryVisibility.backendKey(backend: .plex, serverID: "", baseURLHost: "  ") == nil)
    }

    @Test func backendKeysDifferAcrossBackendsEvenWithSameID() {
        // Guards per-backend isolation at the key level.
        #expect(LibraryVisibility.backendKey(backend: .plex, serverID: "X", baseURLHost: nil)
                != LibraryVisibility.backendKey(backend: .jellyfin, serverID: "X", baseURLHost: nil))
    }

    // MARK: Visibility filter

    @Test func filterRemovesOnlyHiddenIDs() {
        let libs = [Lib(id: "1", title: "Movies", kind: "movies"),
                    Lib(id: "2", title: "Shows", kind: "tvshows"),
                    Lib(id: "3", title: "Folders", kind: "folders")]
        let visible = LibraryVisibility.visible(libs, hiddenIDs: ["2"]) { $0.id }
        #expect(visible.map(\.id) == ["1", "3"])
    }

    @Test func filterPreservesOrderAndReturnsAllWhenNothingHidden() {
        let libs = [Lib(id: "a", title: "A", kind: "movies"), Lib(id: "b", title: "B", kind: "movies")]
        #expect(LibraryVisibility.visible(libs, hiddenIDs: []) { $0.id } == libs)
    }

    @Test func newlyAddedLibraryDefaultsVisible() {
        // Hidden set was built from an old library list that lacked "new"; "new" must stay visible.
        let libs = [Lib(id: "old", title: "Old", kind: "movies"), Lib(id: "new", title: "New", kind: "movies")]
        let visible = LibraryVisibility.visible(libs, hiddenIDs: ["old"]) { $0.id }
        #expect(visible.map(\.id) == ["new"])
    }

    // MARK: Default noise pre-selection

    @Test func preselectsKnownNoiseKinds() {
        let candidates = [
            LibraryVisibility.Candidate(id: "m", title: "Movies", kind: "movies"),
            LibraryVisibility.Candidate(id: "c", title: "My Collections", kind: "collections"),
            LibraryVisibility.Candidate(id: "f", title: "Drives", kind: "folders"),
            LibraryVisibility.Candidate(id: "h", title: "Camera Roll", kind: "homevideos"),
            LibraryVisibility.Candidate(id: "t", title: "TV", kind: "tvshows"),
        ]
        #expect(LibraryVisibility.defaultHiddenSelection(from: candidates) == ["c", "f", "h"])
    }

    @Test func preselectsTrailersByTitleEvenWhenKindIsMovies() {
        // Plex "Trailers" surfaces as an ordinary movie section, so the type filter can't catch it.
        let candidates = [
            LibraryVisibility.Candidate(id: "m", title: "Movies", kind: "movies"),
            LibraryVisibility.Candidate(id: "tr", title: "Movie Trailers", kind: "movies"),
            LibraryVisibility.Candidate(id: "ex", title: "Extras", kind: "movies"),
        ]
        #expect(LibraryVisibility.defaultHiddenSelection(from: candidates) == ["tr", "ex"])
    }

    @Test func preselectsNothingForAllPrimaryContent() {
        let candidates = [
            LibraryVisibility.Candidate(id: "m", title: "Movies", kind: "movies"),
            LibraryVisibility.Candidate(id: "t", title: "Shows", kind: "tvshows"),
        ]
        #expect(LibraryVisibility.defaultHiddenSelection(from: candidates).isEmpty)
    }

    // MARK: Store add/remove/toggle

    @Test func storeRoundTripsHiddenSet() {
        let (store, _) = makeStore()
        store.setHiddenIDs(["a", "b"], forBackendKey: "plex:S")
        #expect(store.hiddenIDs(forBackendKey: "plex:S") == ["a", "b"])
    }

    @Test func toggleAddsAndRemoves() {
        let (store, _) = makeStore()
        let key = "plex:S"
        #expect(store.toggle(id: "x", hidden: true, forBackendKey: key) == ["x"])
        #expect(store.isHidden(id: "x", forBackendKey: key))
        #expect(store.toggle(id: "x", hidden: false, forBackendKey: key).isEmpty)
        #expect(!store.isHidden(id: "x", forBackendKey: key))
    }

    @Test func emptySetIsClearedFromDefaults() {
        let (store, defaults) = makeStore()
        store.setHiddenIDs(["a"], forBackendKey: "plex:S")
        store.setHiddenIDs([], forBackendKey: "plex:S")
        #expect(defaults.data(forKey: "libraryVisibility.hidden.plex:S") == nil)
        #expect(store.hiddenIDs(forBackendKey: "plex:S").isEmpty)
    }

    @Test func nilBackendKeyMeansNothingHiddenAndIsNoOpOnWrite() {
        let (store, _) = makeStore()
        store.setHiddenIDs(["a"], forBackendKey: nil)
        #expect(store.hiddenIDs(forBackendKey: nil).isEmpty)
    }

    // MARK: Per-backend isolation

    @Test func hiddenSetsAreIsolatedPerBackendKey() {
        let (store, _) = makeStore()
        store.setHiddenIDs(["a"], forBackendKey: "plex:S")
        store.setHiddenIDs(["b"], forBackendKey: "jellyfin:S")
        // Backend A's hidden set never affects backend B even with the same server id fragment.
        #expect(store.hiddenIDs(forBackendKey: "plex:S") == ["a"])
        #expect(store.hiddenIDs(forBackendKey: "jellyfin:S") == ["b"])
    }

    // MARK: Prompt gating

    @Test func promptShowsOncePerBackendKey() {
        let (store, _) = makeStore()
        let key = "plex:S"
        #expect(!store.hasShownPrompt(forBackendKey: key))
        store.markPromptShown(forBackendKey: key)
        #expect(store.hasShownPrompt(forBackendKey: key))
        // A different backend key has not been prompted yet.
        #expect(!store.hasShownPrompt(forBackendKey: "jellyfin:S"))
    }

    @Test func nilBackendKeyNeverPrompts() {
        let (store, _) = makeStore()
        #expect(store.hasShownPrompt(forBackendKey: nil))
        store.markPromptShown(forBackendKey: nil) // no-op, must not crash
        #expect(store.hasShownPrompt(forBackendKey: nil))
    }
}
