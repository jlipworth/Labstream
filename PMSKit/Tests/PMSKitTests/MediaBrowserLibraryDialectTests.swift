import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser library dialect")
struct MediaBrowserLibraryDialectTests {
    @Test func sharedFieldStringsBackJellyfinAndEmbyConstants() {
        let expectedGrid = "Overview,PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating,ProviderIds,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesPrimaryImageTag"
        let expectedFull = "Overview,Genres,MediaSources,People,Studios,ProviderIds,ParentId,PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating,CriticRating,Taglines,Chapters,ExtraIds,LocalTrailerCount,SpecialFeatureCount,RemoteTrailers,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesPrimaryImageTag"

        #expect(MediaBrowserMetadataFieldProfiles.grid.fields == expectedGrid)
        #expect(MediaBrowserMetadataFieldProfiles.search.fields == expectedFull)
        #expect(MediaBrowserMetadataFieldProfiles.home.fields == expectedFull)
        #expect(MediaBrowserMetadataFieldProfiles.playlist.fields == expectedFull)
        #expect(MediaBrowserMetadataFieldProfiles.item.fields == expectedFull)
        #expect(MediaBrowserMetadataFieldProfiles.relatedMedia.fields == expectedFull)
        #expect(MediaBrowserMetadataFieldProfiles.music.fields == expectedFull)
        #expect(MediaBrowserMetadataFieldProfiles.grid.purpose == .grid)
        #expect(MediaBrowserMetadataFieldProfiles.search.purpose == .search)
        #expect(MediaBrowserMetadataFieldProfiles.home.purpose == .home)
        #expect(MediaBrowserMetadataFieldProfiles.playlist.purpose == .playlist)
        #expect(MediaBrowserMetadataFieldProfiles.item.purpose == .item)
        #expect(MediaBrowserMetadataFieldProfiles.relatedMedia.purpose == .relatedMedia)
        #expect(MediaBrowserMetadataFieldProfiles.music.purpose == .music)
        #expect(JellyfinLibrary.gridItemFields == MediaBrowserLibraryFields.gridItem)
        #expect(EmbyLibrary.gridItemFields == MediaBrowserLibraryFields.gridItem)
        #expect(JellyfinLibrary.fullItemFields == MediaBrowserLibraryFields.fullItem)
        #expect(EmbyLibrary.fullItemFields == MediaBrowserLibraryFields.fullItem)
        #expect(JellyfinLibrary.gridItemFields == EmbyLibrary.gridItemFields)
        #expect(JellyfinLibrary.fullItemFields == EmbyLibrary.fullItemFields)
        #expect(MediaBrowserLibraryFields.fullItem.contains("ExtraIds"))
        #expect(MediaBrowserLibraryFields.fullItem.contains("LocalTrailerCount"))
        #expect(MediaBrowserLibraryFields.fullItem.contains("SpecialFeatureCount"))
        #expect(MediaBrowserLibraryFields.fullItem.contains("RemoteTrailers"))
    }

    @Test func dialectPreservesJellyfinAndEmbyPathAndQueryNames() {
        let jellyfin = MediaBrowserLibraryQueryDialect.jellyfin
        let emby = MediaBrowserLibraryQueryDialect.emby

        #expect(jellyfin.path(.userViews(userId: "user-1")) == "/UserViews")
        #expect(jellyfin.path(.items(userId: "user-1")) == "/Items")
        #expect(jellyfin.path(.albumArtists) == "/Artists/AlbumArtists")
        #expect(jellyfin.path(.playlistItems(playlistId: "playlist-1")) == "/Playlists/playlist-1/Items")
        #expect(jellyfin.includesUserIDInRootQuery)
        #expect(jellyfin.queryName(.userId) == "userId")
        #expect(jellyfin.queryName(.parentId) == "parentId")
        #expect(jellyfin.queryName(.includeItemTypes) == "includeItemTypes")
        #expect(jellyfin.queryName(.nameStartsWith) == "nameStartsWith")

        #expect(emby.path(.userViews(userId: "user-9")) == "/Users/user-9/Views")
        #expect(emby.path(.items(userId: "user-9")) == "/Users/user-9/Items")
        #expect(emby.path(.albumArtists) == "/Artists/AlbumArtists")
        #expect(emby.path(.playlistItems(playlistId: "playlist-9")) == "/Playlists/playlist-9/Items")
        #expect(!emby.includesUserIDInRootQuery)
        #expect(emby.queryName(.userId) == "UserId")
        #expect(emby.queryName(.parentId) == "ParentId")
        #expect(emby.queryName(.includeItemTypes) == "IncludeItemTypes")
        #expect(emby.queryName(.nameStartsWith) == "NameStartsWith")
    }
}
