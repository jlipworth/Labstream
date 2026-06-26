import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser library dialect")
struct MediaBrowserLibraryDialectTests {
    @Test func sharedFieldStringsBackJellyfinAndEmbyConstants() {
        #expect(JellyfinLibrary.gridItemFields == MediaBrowserLibraryFields.gridItem)
        #expect(EmbyLibrary.gridItemFields == MediaBrowserLibraryFields.gridItem)
        #expect(JellyfinLibrary.fullItemFields == MediaBrowserLibraryFields.fullItem)
        #expect(EmbyLibrary.fullItemFields == MediaBrowserLibraryFields.fullItem)
        #expect(JellyfinLibrary.gridItemFields == EmbyLibrary.gridItemFields)
        #expect(JellyfinLibrary.fullItemFields == EmbyLibrary.fullItemFields)
    }

    @Test func dialectPreservesJellyfinAndEmbyPathAndQueryNames() {
        let jellyfin = MediaBrowserLibraryQueryDialect.jellyfin
        let emby = MediaBrowserLibraryQueryDialect.emby

        #expect(jellyfin.path(.userViews(userId: "user-1")) == "/UserViews")
        #expect(jellyfin.path(.items(userId: "user-1")) == "/Items")
        #expect(jellyfin.queryName(.userId) == "userId")
        #expect(jellyfin.queryName(.parentId) == "parentId")
        #expect(jellyfin.queryName(.includeItemTypes) == "includeItemTypes")
        #expect(jellyfin.queryName(.nameStartsWith) == "nameStartsWith")

        #expect(emby.path(.userViews(userId: "user-9")) == "/path/to/user/Views")
        #expect(emby.path(.items(userId: "user-9")) == "/path/to/user/Items")
        #expect(emby.queryName(.userId) == "UserId")
        #expect(emby.queryName(.parentId) == "ParentId")
        #expect(emby.queryName(.includeItemTypes) == "IncludeItemTypes")
        #expect(emby.queryName(.nameStartsWith) == "NameStartsWith")
    }
}
