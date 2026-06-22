import Testing
@testable import PMSKit

@Suite("MediaBrowser library grid policy")
struct MediaBrowserLibraryGridPolicyTests {
    @Test func movieLibrariesFlattenNestedServerRoots() {
        #expect(MediaBrowserLibraryGridPolicy.itemTypes(collectionType: "movies") == "Movie")
        #expect(MediaBrowserLibraryGridPolicy.recursive(collectionType: "movies") == true)
    }

    @Test func tvLibrariesKeepSeriesRootSemantics() {
        #expect(MediaBrowserLibraryGridPolicy.itemTypes(collectionType: "tvshows") == "Series")
        #expect(MediaBrowserLibraryGridPolicy.recursive(collectionType: "tvshows") == false)
    }

    @Test func homeVideoLibrariesUseStandaloneVideoItems() {
        #expect(MediaBrowserLibraryGridPolicy.itemTypes(collectionType: "homevideos") == "Video")
        #expect(MediaBrowserLibraryGridPolicy.itemTypes(collectionType: "livetv") == "Video")
        #expect(MediaBrowserLibraryGridPolicy.recursive(collectionType: "homevideos") == false)
    }

    @Test func unknownLibrariesKeepImmediateChildrenAndMixedTypes() {
        #expect(MediaBrowserLibraryGridPolicy.itemTypes(collectionType: nil) == "Movie,Series,Season,Episode,Video")
        #expect(MediaBrowserLibraryGridPolicy.recursive(collectionType: nil) == false)
    }

    @Test func collectionTypeMatchingIsCaseInsensitive() {
        #expect(MediaBrowserLibraryGridPolicy.itemTypes(collectionType: "Movies") == "Movie")
        #expect(MediaBrowserLibraryGridPolicy.recursive(collectionType: "Movies") == true)
    }
}
