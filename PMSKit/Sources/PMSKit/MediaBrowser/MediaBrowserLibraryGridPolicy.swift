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
        default:
            return "Movie,Series,Season,Episode"
        }
    }

    public static func recursive(collectionType: String?) -> Bool {
        switch collectionType?.lowercased() {
        case "movies":
            // Emby can report a Movies view with zero direct Movie children while recursive lookup
            // returns the real contents (GH #99). Jellyfin tolerates the same shape, so keep both
            // MediaBrowser backends aligned for flat movie libraries.
            return true
        default:
            // TV libraries intentionally show Series at the root; folder-like/collection roots keep
            // their immediate child semantics unless proven otherwise.
            return false
        }
    }
}
