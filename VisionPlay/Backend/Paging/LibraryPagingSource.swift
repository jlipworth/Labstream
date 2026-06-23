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

// TODO(#96): Search, Detail child lists, and Music keep their existing paging/search paths
// for later phases; this first pass intentionally scopes the shared model to video LibraryGridView.
@MainActor
struct LibraryPagingSource {
    static let defaultPageSize = 200

    let title: String
    let identity: String
    let backendLabel: String
    let pageSize: Int
    let cacheEmptyFirstPage: Bool
    let awaitAlphabetBeforeInitialLoad: Bool
    let fetchPage: @MainActor @Sendable (_ start: Int, _ limit: Int) async throws -> LibraryPagingPage
    let fetchAlphabetCounts: @MainActor @Sendable () async -> [(display: String, count: Int)]

    init(title: String,
         identity: String,
         backendLabel: String,
         pageSize: Int = Self.defaultPageSize,
         cacheEmptyFirstPage: Bool,
         awaitAlphabetBeforeInitialLoad: Bool,
         fetchPage: @escaping @MainActor @Sendable (_ start: Int, _ limit: Int) async throws -> LibraryPagingPage,
         fetchAlphabetCounts: @escaping @MainActor @Sendable () async -> [(display: String, count: Int)]) {
        self.title = title
        self.identity = identity
        self.backendLabel = backendLabel
        self.pageSize = pageSize
        self.cacheEmptyFirstPage = cacheEmptyFirstPage
        self.awaitAlphabetBeforeInitialLoad = awaitAlphabetBeforeInitialLoad
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
