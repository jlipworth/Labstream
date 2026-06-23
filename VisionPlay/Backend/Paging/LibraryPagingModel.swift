import Foundation
import Observation
import PMSKit

@MainActor
@Observable
final class LibraryPagingModel {
    private(set) var slots: [MediaItem?] = []
    private(set) var alphabetBuckets: [AlphabetBucket] = []
    private(set) var loadState: HomeView.LoadState = .idle
    private(set) var total = 0
    private(set) var pageSize = LibraryPagingSource.defaultPageSize

    @ObservationIgnored private var loadingPages: Set<Int> = []
    @ObservationIgnored private var loadedIdentity: String?
    @ObservationIgnored private var activeIdentity: String?

    func load(source: LibraryPagingSource,
              force: Bool = false,
              isCurrent: @MainActor () -> Bool) async {
        let identity = source.identity
        if !force, loadedIdentity == identity, case .loaded = loadState { return }

        activeIdentity = identity
        pageSize = source.pageSize
        loadState = .loading
        slots = []
        total = 0
        loadingPages = []
        alphabetBuckets = []

        let span = PerformanceInstrumentation.begin(.libraryGridInitialPage,
                                                     backend: source.backendLabel,
                                                     fields: ["page_size": source.pageSize])
        do {
            async let pageResult = source.fetchPage(0, source.pageSize)
            async let alphabetCounts = source.fetchAlphabetCounts()
            let page = try await pageResult

            if source.awaitAlphabetBeforeInitialLoad {
                let buckets = AlphabetBucket.buckets(from: await alphabetCounts, total: page.total)
                guard isCurrent(), activeIdentity == identity else {
                    span.end(result: "stale")
                    return
                }
                applyInitialPage(page,
                                 alphabetBuckets: buckets,
                                 source: source,
                                 identity: identity)
                span.end(fields: [
                    "item_count": page.items.count,
                    "total_count": page.total,
                    "alphabet_count": buckets.count,
                ])
            } else {
                guard isCurrent(), activeIdentity == identity else {
                    span.end(result: "stale")
                    return
                }
                applyInitialPage(page,
                                 alphabetBuckets: [],
                                 source: source,
                                 identity: identity)
                span.end(fields: [
                    "item_count": page.items.count,
                    "total_count": page.total,
                ])

                let buckets = AlphabetBucket.buckets(from: await alphabetCounts, total: page.total)
                guard isCurrent(), activeIdentity == identity else { return }
                alphabetBuckets = buckets
            }
        } catch {
            guard isCurrent(), activeIdentity == identity else {
                span.end(result: "stale")
                return
            }
            span.end(result: "failure", fields: ["error": performanceErrorLabel(error)])
            loadState = .failed(friendlyMessage(error))
            // Structured `async let` alphabet work is cancelled at scope exit. Do not wait
            // for slow rail probes after the first page fails (#96).
        }
    }

    func prefetch(containing index: Int,
                  source: LibraryPagingSource,
                  isCurrent: @MainActor () -> Bool) async {
        await loadPage(containing: index, source: source, isCurrent: isCurrent)
    }

    func loadPage(containing index: Int,
                  source: LibraryPagingSource,
                  isCurrent: @MainActor () -> Bool) async {
        guard isCurrent(), activeIdentity == source.identity else { return }
        guard slots.indices.contains(index) else { return }

        let window = PagingPageWindow(pageSize: source.pageSize)
        guard let page = window.page(containing: index),
              let start = window.startOffset(forPage: page) else { return }
        guard !loadingPages.contains(page) else { return }
        loadingPages.insert(page)
        defer { loadingPages.remove(page) }

        let span = PerformanceInstrumentation.begin(.libraryGridPage,
                                                     backend: source.backendLabel,
                                                     fields: ["page": page, "page_size": source.pageSize])
        do {
            let pageResult = try await source.fetchPage(start, source.pageSize)
            guard isCurrent(), activeIdentity == source.identity else {
                span.end(result: "stale")
                return
            }
            PagingPageWindow.insert(pageResult.items, into: &slots, at: start)
            span.end(fields: ["item_count": pageResult.items.count])
        } catch {
            guard isCurrent(), activeIdentity == source.identity else {
                span.end(result: "stale")
                return
            }
            span.end(result: "failure", fields: ["error": performanceErrorLabel(error)])
            // Non-fatal: removing the in-flight mark lets the placeholder retry when it reappears.
        }
    }

    private func applyInitialPage(_ page: LibraryPagingPage,
                                  alphabetBuckets: [AlphabetBucket],
                                  source: LibraryPagingSource,
                                  identity: String) {
        total = page.total
        slots = PagingPageWindow.slots(total: page.total, inserting: page.items)
        self.alphabetBuckets = alphabetBuckets
        loadedIdentity = (source.cacheEmptyFirstPage || !page.items.isEmpty) ? identity : nil
        loadState = .loaded
    }

    private func performanceErrorLabel(_ error: Error) -> String {
        if let paging = error as? LibraryPagingError {
            return paging.performanceLabel
        }
        return PerformanceInstrumentation.errorLabel(error)
    }
}
