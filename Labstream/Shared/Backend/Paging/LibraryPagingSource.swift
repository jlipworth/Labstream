import Foundation
import PMSKit

struct LibraryPagingPage: Sendable {
    let items: [MediaItem]
    let total: Int

    init(items: [MediaItem], reportedTotal: Int?) {
        self.items = items
        self.total = PagingPageWindow.normalizedTotal(reported: reportedTotal,
                                                      returnedCount: items.count)
    }
}

// Shared page-fetch contract for browse grids. Search, Detail child lists, and Music
// now use the same browse load-state/paging primitives where useful, while each
// screen keeps its own backend-specific request source.
@MainActor
struct LibraryPagingSource {
    static let defaultPageSize = 200

    let title: String
    let identity: String
    let backendLabel: String
    let pageSize: Int
    let cacheEmptyFirstPage: Bool
    let awaitAlphabetBeforeInitialLoad: Bool
    /// When true, collapse duplicate movie tiles (same title+year, distinct backend ids) to
    /// one representative carrying the others as `versions` (GH #108). Set only for the
    /// Jellyfin/Emby recursive movie grids that surface one item per physical file/version;
    /// Plex (server-deduped flat listing) and non-movie libraries leave this false.
    let collapsesMovieVersions: Bool
    /// False when the current sort/filter makes A-Z offsets meaningless (non-alphabetical
    /// sort or narrowed result set). The paged path enforces this inside
    /// `fetchAlphabetCounts`; the collapsing path builds buckets locally after the full
    /// load, so it must consult this flag instead.
    let supportsAlphabetRail: Bool
    let fetchPage: @MainActor @Sendable (_ start: Int, _ limit: Int) async throws -> LibraryPagingPage
    let fetchAlphabetCounts: @MainActor @Sendable () async -> [(display: String, count: Int)]

    init(title: String,
         identity: String,
         backendLabel: String,
         pageSize: Int = Self.defaultPageSize,
         cacheEmptyFirstPage: Bool,
         awaitAlphabetBeforeInitialLoad: Bool,
         collapsesMovieVersions: Bool = false,
         supportsAlphabetRail: Bool = true,
         fetchPage: @escaping @MainActor @Sendable (_ start: Int, _ limit: Int) async throws -> LibraryPagingPage,
         fetchAlphabetCounts: @escaping @MainActor @Sendable () async -> [(display: String, count: Int)]) {
        self.title = title
        self.identity = identity
        self.backendLabel = backendLabel
        self.pageSize = pageSize
        self.cacheEmptyFirstPage = cacheEmptyFirstPage
        self.awaitAlphabetBeforeInitialLoad = awaitAlphabetBeforeInitialLoad
        self.collapsesMovieVersions = collapsesMovieVersions
        self.supportsAlphabetRail = supportsAlphabetRail
        self.fetchPage = fetchPage
        self.fetchAlphabetCounts = fetchAlphabetCounts
    }
}

enum LibraryPagingError: LocalizedError {
    case missingPlexServer

    var errorDescription: String? {
        switch self {
        case .missingPlexServer:
            return "No server selected."
        }
    }

    var performanceLabel: String {
        switch self {
        case .missingPlexServer:
            return "missing_plex_server"
        }
    }
}
