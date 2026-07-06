import Foundation

/// Shared request policy for Jellyfin/Emby library grid screens.
///
/// Some MediaBrowser servers expose a library root (notably Emby `collectionType=movies`) as a
/// folder whose actual items are nested below it. A non-recursive `/Users/{id}/Items?ParentId=...`
/// request can therefore return an empty page for a populated library. Keep that server-shape quirk
/// out of SwiftUI by centralizing when the grid should flatten a library root.
public enum MediaBrowserLibraryGridPolicy {
    public static func itemTypes(collectionType: String?) -> String {
        switch collectionType?.lowercased() {
        case "movies":
            return "Movie"
        case "tvshows":
            return "Series"
        case "homevideos", "livetv":
            return "Video"
        case "boxsets":
            // Collections view: the grid lists the box sets themselves; children load via
            // the collection detail read path (generic Items + ParentId).
            return "BoxSet"
        default:
            return "Movie,Series,Season,Episode,Video"
        }
    }

    /// True for movie libraries, whose recursive query returns one item per physical
    /// file/version — distinct ids with identical title/year — so the grid must collapse them
    /// to one tile per logical movie (GH #108). Other library kinds list distinct logical items.
    public static func collapsesMovieVersions(collectionType: String?) -> Bool {
        collectionType?.lowercased() == "movies"
    }

    /// Sort/filter facets safe to offer for a MediaBrowser library grid. TV grids list
    /// `Series` containers, which never carry a resume position in Jellyfin/Emby, so
    /// `Filters=IsResumable` on them deterministically returns zero items — hide the
    /// "In Progress" facet there instead of offering a filter that always comes back empty.
    public static func browseCapabilities(collectionType: String?) -> LibraryBrowseCapabilities {
        guard itemTypes(collectionType: collectionType) != "Series" else {
            return LibraryBrowseCapabilities(sorts: LibraryBrowseSort.allCases,
                                             filters: LibraryBrowseFilter.allCases.filter { $0 != .inProgress })
        }
        return .videoMVP
    }

    public static func recursive(collectionType: String?) -> Bool {
        switch collectionType?.lowercased() {
        case "movies":
            // Emby can report a Movies view with zero direct Movie children while recursive lookup
            // returns the real contents (GH #99). Jellyfin tolerates the same shape, so keep both
            // MediaBrowser backends aligned for flat movie libraries.
            return true
        case "boxsets":
            // Same flat-view shape as movies: the IncludeItemTypes=BoxSet filter keeps a
            // recursive query scoped to box sets, and box sets don't nest, so recursive is
            // safe and tolerates servers whose view root has no direct children.
            return true
        default:
            // TV libraries intentionally show Series at the root; folder-like/collection roots keep
            // their immediate child semantics unless proven otherwise.
            return false
        }
    }
}
