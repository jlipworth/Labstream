import CoreSpotlight
import Foundation
import PMSKit
import UniformTypeIdentifiers

/// Best-effort CoreSpotlight indexing of library items as they're browsed
/// (issue #24): Home hubs and library grid pages feed batches here, so anything
/// the user has seen becomes findable in system search and routes back into
/// its DetailView (handled via `onContinueUserActivity` in ContentView).
///
/// Deliberate choices:
///   - Index-as-you-browse, not a full library crawl — no background machinery,
///     and the index only ever contains what the user actually surfaced.
///   - No poster thumbnails: each would cost a `/photo/:/transcode` round-trip per
///     item (with a token-bearing URL); titles + descriptions are plenty for search.
///   - Music stays out of this first system-video surface; music now has dedicated
///     in-app routes, but these App Intents/deep links target video DetailView.
///   - `uniqueIdentifier` keeps the legacy Plex server namespace plus ratingKey for
///     compatibility; non-Plex entries use the versioned backend/server/item shape.
///     These ids are token-free but still private user/server metadata and are never logged.
enum SpotlightIndexer {
    /// Single domain for everything we index, so sign-out can wipe it in one call.
    static let domainIdentifier = "com.jlipworth.Labstream.media"

    /// Queue a batch for indexing. Fire-and-forget: indexing is a nicety and must
    /// never affect browse, so failures are only logged.
    static func index(_ items: [MediaItem], server: URL) {
        index(items, backend: .plex, server: server)
    }

    static func index(_ items: [MediaItem], backend: MediaBackendKind, server: URL) {
        guard PlaybackPreferences.systemMediaSuggestionsEnabled() else { return }
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let searchable = items.compactMap { searchableItem(for: $0, backend: backend, server: server) }
        guard !searchable.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(searchable) { error in
            if let error {
                NSLog("SpotlightIndexer: indexing failed (%@)",
                      DiagnosticRedactor.safeErrorSummary(error))
            }
        }
    }

    /// Remove everything we've indexed. Called on sign-out so library titles don't
    /// linger in system search after the account is gone. Settings can also call this
    /// as a manual stale-index cleanup action; completion reports whether CoreSpotlight
    /// accepted the delete request.
    static func deleteAll(completion: (@Sendable (Bool) -> Void)? = nil) {
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
                if let error {
                    NSLog("SpotlightIndexer: delete failed (%@)",
                          DiagnosticRedactor.safeErrorSummary(error))
                    completion?(false)
                } else {
                    completion?(true)
                }
            }
    }

    /// Recover the ratingKey from a CoreSpotlight identifier. Identifiers from older builds
    /// were bare ratingKeys; newer helpers can also parse backend-scoped ids.
    static func routeKey(from searchableIdentifier: String) -> BackendScopedMediaID {
        MediaSearchIdentifier.routeKey(from: searchableIdentifier)
    }

    static func ratingKey(from searchableIdentifier: String) -> String {
        routeKey(from: searchableIdentifier).ratingKey
    }

    private static func searchableItem(for item: MediaItem, backend: MediaBackendKind, server: URL) -> CSSearchableItem? {
        guard !item.isMusic, !item.title.isEmpty else { return nil }

        let attrs = CSSearchableItemAttributeSet(contentType: contentType(for: item))
        // Episodes index under their full context line ("Show · S1E3 · Title") so a
        // search for the show name surfaces them too.
        attrs.title = item.kind == .episode ? item.displaySubtitleLine : item.title
        attrs.contentDescription = description(for: item)
        // Keywords broaden recall: show name and year alongside the title.
        attrs.keywords = [item.title, item.grandparentTitle, item.year.map(String.init)]
            .compactMap { $0 }

        return CSSearchableItem(uniqueIdentifier: searchableIdentifier(for: item, backend: backend, server: server),
                                domainIdentifier: domainIdentifier,
                                attributeSet: attrs)
    }

    private static func searchableIdentifier(for item: MediaItem, backend: MediaBackendKind, server: URL) -> String {
        if backend == .plex {
            // Keep Plex identifiers byte-compatible with the existing index while routing
            // remains active-backend-checked in `RootView`.
            return MediaSearchIdentifier.make(ratingKey: item.ratingKey, server: server)
        }
        return MediaSearchIdentifier.make(ratingKey: item.ratingKey,
                                          server: server,
                                          backend: backend.backendChoice)
    }

    private static func contentType(for item: MediaItem) -> UTType {
        item.kind == .movie ? .movie : .audiovisualContent
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
        return "\(lead) · Labstream library"
    }
}
