import Foundation
import PMSKit

/// Collapses duplicate movie tiles in a library grid (GH #108).
///
/// Jellyfin/Emby return one `BaseItem` per physical file/version when a library is
/// queried recursively (`Recursive=true&IncludeItemTypes=Movie`, the GH #99 fix for
/// nested libraries). Multiple editions/versions of one logical movie therefore arrive
/// as separate `MediaItem`s with **distinct `ratingKey`s but identical title/year/art** —
/// the grid renders them as 2–3 indistinguishable poster tiles for the same movie.
///
/// This collapser groups items by `MediaItem.movieVersionIdentity` (a robust provider-id /
/// title+year identity defined in PMSKit) and keeps ONE representative per group, attaching
/// the collapsed siblings on `MediaItem.versions` so the detail screen can offer a version
/// chooser. The first item seen for a key (in arrival order) wins as the representative,
/// mirroring the episode de-dup in `Array<MediaItem>.normalizedForContainerBrowser`.
///
/// ## Load-all model (GH #108 rework)
/// The collapsing grid loads EVERY page up front (`LibraryPagingModel` fetches all pages
/// when `source.collapsesMovieVersions`), then displays a stable, fully-deduped list — the
/// same proven pattern as `normalizedForContainerBrowser`. This collapser is a simple
/// append-only accumulator: `ingest(_:)` appends each arriving page in order, and
/// `collapsedItems()` re-derives the dense deduped list. There is NO sparse per-offset
/// window, NO placeholder projection, and NO server-offset translation — those produced
/// the F1/F2/F3 bugs (mis-mapped alphabet jumps, permanent shimmer holes, a shrinking
/// total). Because the grid renders the dense collapsed list directly and the rail is built
/// from that same list's positions, those failure modes are structurally impossible now.
@MainActor
struct MovieVersionCollapser {
    /// Every raw item ingested so far, in arrival (server-sorted, page) order. Append-only;
    /// pages arrive in sorted server order so first-seen order — and thus the representative
    /// chosen per group — is stable.
    private var rawItems: [MediaItem] = []

    /// Record a freshly-fetched page's items, appended in arrival order.
    mutating func ingest(_ items: [MediaItem]) {
        rawItems.append(contentsOf: items)
    }

    /// The complete, dense, deduped movie list across every page ingested so far, in order
    /// of first appearance. One representative per `movieVersionIdentity` group, each carrying
    /// its collapsed siblings as `versions` (nil for single-member groups). Stable and complete
    /// once the full load has finished.
    func collapsedItems() -> [MediaItem] {
        rawItems.collapsingMovieVersions()
    }
}
