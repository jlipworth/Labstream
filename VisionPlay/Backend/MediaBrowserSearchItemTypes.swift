import Foundation

/// `IncludeItemTypes` for a MediaBrowser (Jellyfin/Emby) search within a library view, keyed
/// by its collection type. Shared by both backend services' `searchResults` so the facet
/// table lives in one place (the two services used to carry byte-identical private copies).
///
/// Search is format-normalized here, but match semantics stay native (#103): MediaBrowser
/// `searchTerm` is not made fuzzy. Music libraries facet too (#111): `toMediaItem()` maps
/// MusicArtist/MusicAlbum/Audio onto PMS music kinds, and the detail/playback path is
/// backend-aware, so SearchView's Artists/Albums/Songs rails resolve and play.
func mediaBrowserSearchItemTypes(forCollectionType collectionType: String?) -> String {
    switch collectionType?.lowercased() {
    case "movies":
        return "Movie"
    case "tvshows":
        return "Series,Season,Episode"
    case "homevideos", "livetv":
        return "Video"
    case "music":
        return "MusicArtist,MusicAlbum,Audio"
    default:
        return "Movie,Series,Season,Episode,Video"
    }
}
