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
/// same proven pattern as `normalizedForContainerBrowser`. This collapser incrementally
/// incorporates each arriving item exactly once and returns only the projected positions
/// changed by that page. Existing version groups are republished progressively so a user can
/// select every version discovered so far while later pages are still loading. That immutable
/// snapshot costs the size of each group touched by the page, but unrelated groups/history are
/// never revisited. There is NO sparse per-offset window, NO placeholder projection, and NO
/// server-offset translation — those produced the F1/F2/F3 bugs (mis-mapped alphabet jumps,
/// permanent shimmer holes, a shrinking total). Because the grid renders the dense collapsed
/// list directly and the rail is built from that same list's positions, those failure modes are
/// structurally impossible now.
@MainActor
struct MovieVersionCollapser {
    struct ProjectionUpdate {
        let index: Int
        let item: MediaItem
    }

    /// The delta needed to update the dense grid projection after one page. `count` is the
    /// complete distinct-item count after the ingest; `updates` contains both newly appended
    /// representatives and existing representatives whose ordered `versions` group grew.
    struct ProjectionDelta {
        let count: Int
        let updates: [ProjectionUpdate]
    }

    private var groupIndexByIdentity: [String: Int] = [:]
    private var groups: [[MediaItem]] = []
    private var projectedItems: [MediaItem] = []

#if DEBUG
    /// Deterministic complexity seams. Grouping visits every input once. Projection work counts
    /// the members in only duplicate groups touched by each page; this honestly includes the
    /// growing immutable snapshot needed to preserve the progressive version-chooser contract.
    private(set) var groupedItemCountForTesting = 0
    private(set) var projectedVersionMemberCountForTesting = 0
#endif

    /// Incorporate a freshly fetched page in arrival order. Existing identities update their
    /// original representative in place; new identities append one dense position. Only groups
    /// touched by this page are re-projected, rather than collapsing all prior raw history again.
    @discardableResult
    mutating func ingest(_ items: [MediaItem]) -> ProjectionDelta {
        var touchedIndices: [Int] = []
        var touchedIndexSet: Set<Int> = []
        touchedIndices.reserveCapacity(items.count)
        touchedIndexSet.reserveCapacity(items.count)

        for item in items {
#if DEBUG
            groupedItemCountForTesting += 1
#endif
            let identity = item.movieVersionIdentity
            let groupIndex: Int
            if let existingIndex = groupIndexByIdentity[identity] {
                groupIndex = existingIndex
                groups[groupIndex].append(item)
            } else {
                groupIndex = groups.count
                groupIndexByIdentity[identity] = groupIndex
                groups.append([item])
                projectedItems.append(item)
            }

            if touchedIndexSet.insert(groupIndex).inserted {
                touchedIndices.append(groupIndex)
            }
        }

        let updates = touchedIndices.map { index in
            let group = groups[index]
#if DEBUG
            if group.count > 1 {
                projectedVersionMemberCountForTesting += group.count
            }
#endif
            let projected = group.count == 1
                ? group[0]
                : group[0].with(versions: group)
            projectedItems[index] = projected
            return ProjectionUpdate(index: index, item: projected)
        }
        return ProjectionDelta(count: projectedItems.count, updates: updates)
    }

    /// The complete, dense, deduped movie list across every page ingested so far, in order
    /// of first appearance. One representative per `movieVersionIdentity` group, each carrying
    /// its collapsed siblings as `versions` (nil for single-member groups). Stable and complete
    /// once the full load has finished.
    func collapsedItems() -> [MediaItem] {
        projectedItems
    }
}
