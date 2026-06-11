import CoreSpotlight
import Foundation
import PMSKit

/// Best-effort CoreSpotlight indexing of library items as they're browsed
/// (issue #24): Home hubs and library grid pages feed batches here, so anything
/// the user has seen becomes findable in system search and deep-links back into
/// its DetailView (handled via `onContinueUserActivity` in ContentView).
///
/// Deliberate choices:
///   - Index-as-you-browse, not a full library crawl — no background machinery,
///     and the index only ever contains what the user actually surfaced.
///   - No poster thumbnails: each would cost a `/photo/:/transcode` round-trip per
///     item (with a token-bearing URL); titles + descriptions are plenty for search.
///   - Music stays out, consistent with it being hidden from browse (#15).
///   - `uniqueIdentifier` is the bare ratingKey — exactly what the deep-link path
///     needs to re-fetch metadata. Items from a previous server simply fail that
///     fetch and the tap becomes a no-op (plus the index is cleared on sign-out).
enum SpotlightIndexer {
    /// Single domain for everything we index, so sign-out can wipe it in one call.
    static let domainIdentifier = "com.jlipworth.VisionPlex.media"

    /// Queue a batch for indexing. Fire-and-forget: indexing is a nicety and must
    /// never affect browse, so failures are only logged.
    static func index(_ items: [MediaItem]) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let searchable = items.compactMap(searchableItem(for:))
        guard !searchable.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(searchable) { error in
            if let error {
                NSLog("%@", "SpotlightIndexer: indexing failed: \(error.localizedDescription)")
            }
        }
    }

    /// Remove everything we've indexed. Called on sign-out so library titles don't
    /// linger in system search after the account is gone.
    static func deleteAll() {
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
                if let error {
                    NSLog("%@", "SpotlightIndexer: delete failed: \(error.localizedDescription)")
                }
            }
    }

    private static func searchableItem(for item: MediaItem) -> CSSearchableItem? {
        guard !item.isMusic, !item.title.isEmpty else { return nil }

        let attrs = CSSearchableItemAttributeSet(contentType: .movie)
        // Episodes index under their full context line ("Show · S1E3 · Title") so a
        // search for the show name surfaces them too.
        attrs.title = item.kind == .episode ? item.displaySubtitleLine : item.title
        attrs.contentDescription = description(for: item)
        // Keywords broaden recall: show name and year alongside the title.
        attrs.keywords = [item.title, item.grandparentTitle, item.year.map(String.init)]
            .compactMap { $0 }

        return CSSearchableItem(uniqueIdentifier: item.ratingKey,
                                domainIdentifier: domainIdentifier,
                                attributeSet: attrs)
    }

    /// "Movie · 2009 — <summary>"-style description so the search result card reads
    /// like something, even when PMS has no summary for the item.
    private static func description(for item: MediaItem) -> String {
        var lead: String
        switch item.kind {
        case .movie: lead = "Movie"
        case .show: lead = "TV Series"
        case .season: lead = "Season"
        case .episode: lead = "Episode"
        default: lead = "Video"
        }
        if let year = item.year { lead += " · \(year)" }
        if let summary = item.summary, !summary.isEmpty {
            return "\(lead) — \(summary)"
        }
        return "\(lead) · VisionPlex library"
    }
}
