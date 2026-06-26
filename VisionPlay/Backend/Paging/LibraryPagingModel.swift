import Foundation
import Observation
import PMSKit

@MainActor
@Observable
final class LibraryPagingModel {
    private(set) var slots: [MediaItem?] = []
    private(set) var alphabetBuckets: [AlphabetBucket] = []
    private(set) var loadState: BrowseLoadState = .idle
    private(set) var total = 0
    private(set) var pageSize = LibraryPagingSource.defaultPageSize

    @ObservationIgnored private var loadingPages: Set<Int> = []
    @ObservationIgnored private var loadedIdentity: String?
    @ObservationIgnored private var activeIdentity: String?
    @ObservationIgnored private var activeLoadGeneration = 0
    /// Movie-version de-dup state (#108), present only when the source opts in
    /// (`collapsesMovieVersions`). An append-only accumulator of all loaded pages; the grid
    /// renders its dense, complete `collapsedItems()` directly. `nil` for sources that show
    /// items verbatim (Plex, TV, etc.), which keep the lazy sparse-window paging below.
    @ObservationIgnored private var collapser: MovieVersionCollapser?

    func load(source: LibraryPagingSource,
              force: Bool = false,
              isCurrent: @MainActor () -> Bool) async {
        let identity = source.identity
        if !force, loadedIdentity == identity, case .loaded = loadState { return }

        activeIdentity = identity
        activeLoadGeneration += 1
        let generation = activeLoadGeneration
        pageSize = source.pageSize
        loadState = .loading
        slots = []
        total = 0
        loadingPages = []
        alphabetBuckets = []
        collapser = source.collapsesMovieVersions ? MovieVersionCollapser() : nil

        if source.collapsesMovieVersions {
            await loadAllCollapsing(source: source, identity: identity, generation: generation, isCurrent: isCurrent)
        } else {
            await loadLazy(source: source, identity: identity, generation: generation, isCurrent: isCurrent)
        }
    }

    // MARK: - Non-collapsing (lazy, sparse-window) path — unchanged behavior

    /// The original lazy-paged load: fetch page 0 + alphabet counts, pre-size a sparse
    /// `slots` array to the server total, and let scroll-prefetch fill the rest. Used by
    /// Plex, TV libraries, and every non-collapsing source. Untouched by #108.
    private func loadLazy(source: LibraryPagingSource,
                          identity: String,
                          generation: Int,
                          isCurrent: @MainActor () -> Bool) async {
        let span = PerformanceInstrumentation.begin(.libraryGridInitialPage,
                                                     backend: source.backendLabel,
                                                     fields: ["page_size": source.pageSize])
        do {
            async let pageResult = source.fetchPage(0, source.pageSize)
            async let alphabetCounts = source.fetchAlphabetCounts()
            let page = try await pageResult

            if source.awaitAlphabetBeforeInitialLoad {
                let buckets = AlphabetBucket.buckets(from: await alphabetCounts, total: page.total)
                guard isCurrent(), activeIdentity == identity, activeLoadGeneration == generation else {
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
                guard isCurrent(), activeIdentity == identity, activeLoadGeneration == generation else {
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
                guard isCurrent(), activeIdentity == identity, activeLoadGeneration == generation else { return }
                alphabetBuckets = buckets
            }
        } catch {
            guard isCurrent(), activeIdentity == identity, activeLoadGeneration == generation else {
                span.end(result: "stale")
                return
            }
            span.end(result: "failure", fields: ["error": performanceErrorLabel(error)])
            loadState = .failed(friendlyMessage(error))
            // Structured `async let` alphabet work is cancelled at scope exit. Do not wait
            // for slow rail probes after the first page fails (#96).
        }
    }

    // MARK: - Collapsing (load-all, incremental dedup) path — #108

    /// Load EVERY page of a collapsing movie source up front, ingesting each into the
    /// collapser and re-projecting the dense deduped `slots` after every page so movies
    /// appear progressively. `total` only ever grows (it tracks the distinct movies known so
    /// far); there are no placeholder holes; scroll-prefetch is disabled. Once the full load
    /// finishes, the alphabet rail is built from the final collapsed list's own positions.
    ///
    /// Structurally fixes F1/F2/F3: the grid renders the dense collapsed list directly, so
    /// there is no server-offset translation (F2), no shrinking estimated total (F3), and the
    /// rail offsets index into that same list (F1).
    private func loadAllCollapsing(source: LibraryPagingSource,
                                   identity: String,
                                   generation: Int,
                                   isCurrent: @MainActor () -> Bool) async {
        let span = PerformanceInstrumentation.begin(.libraryGridInitialPage,
                                                     backend: source.backendLabel,
                                                     fields: ["page_size": source.pageSize])
        do {
            let first = try await source.fetchPage(0, source.pageSize)
            guard isCurrent(), activeIdentity == identity, activeLoadGeneration == generation else {
                span.end(result: "stale")
                return
            }
            collapser?.ingest(first.items)
            projectCollapsed()
            // Show the grid immediately after the first page; keep loading the rest below.
            loadedIdentity = (source.cacheEmptyFirstPage || !first.items.isEmpty) ? identity : nil
            loadState = .loaded

            var loadedPages = 1
            var start = source.pageSize
            var serverTotal = first.total
            var lastPageWasEmpty = first.items.isEmpty
            // Keep paging until we've covered the reported total (or hit an empty page).
            while !lastPageWasEmpty, start < serverTotal {
                let page = try await source.fetchPage(start, source.pageSize)
                guard isCurrent(), activeIdentity == identity, activeLoadGeneration == generation else {
                    span.end(result: "stale")
                    return
                }
                collapser?.ingest(page.items)
                projectCollapsed()
                loadedPages += 1
                lastPageWasEmpty = page.items.isEmpty
                // The server total can only be trusted to grow; never let a later page's
                // smaller `total` cut the loop short before all items are fetched.
                serverTotal = max(serverTotal, page.total)
                start += source.pageSize
            }

            // Full load complete → build the rail from the final collapsed list's positions
            // (F1 fix). Until now `alphabetBuckets` stayed empty (rail hidden during load).
            let collapsed = collapser?.collapsedItems() ?? []
            alphabetBuckets = AlphabetBucket.buckets(fromTitles: collapsed.map(\.title))
            span.end(fields: [
                "item_count": collapsed.count,
                "total_count": serverTotal,
                "page_count": loadedPages,
                "alphabet_count": alphabetBuckets.count,
            ])
        } catch {
            guard isCurrent(), activeIdentity == identity, activeLoadGeneration == generation else {
                span.end(result: "stale")
                return
            }
            // If we already showed the first page, keep what we have rather than wiping the
            // grid to an error; otherwise surface the failure.
            if case .loaded = loadState {
                span.end(result: "partial", fields: ["error": performanceErrorLabel(error)])
            } else {
                span.end(result: "failure", fields: ["error": performanceErrorLabel(error)])
                loadState = .failed(friendlyMessage(error))
            }
        }
    }

    /// Re-derive the displayed `slots`/`total` from the collapser's complete deduped list
    /// (#108). Dense — there are NO `nil` placeholders, so a tile never lingers as permanent
    /// shimmer (F2) and `total` reflects exactly the distinct movies known so far, growing
    /// monotonically as pages load (F3).
    private func projectCollapsed() {
        guard let collapser else { return }
        slots = collapser.collapsedItems().map(Optional.init)
        total = slots.count
    }

    func prefetch(containing index: Int,
                  source: LibraryPagingSource,
                  isCurrent: @MainActor () -> Bool) async {
        await loadPage(containing: index, source: source, isCurrent: isCurrent)
    }

    func loadPage(containing index: Int,
                  source: LibraryPagingSource,
                  isCurrent: @MainActor () -> Bool) async {
        // Collapsing sources load every page up front (#108): everything is already in
        // `slots`, there are no placeholders to fill, and the projected index is NOT a server
        // offset — so scroll-prefetch and rail-jump page loads are no-ops here. This removes
        // the serverOffset translation path entirely (and with it the F2 hole bug).
        guard collapser == nil else { return }

        guard isCurrent(), activeIdentity == source.identity else { return }
        let generation = activeLoadGeneration
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
            guard isCurrent(), activeIdentity == source.identity, activeLoadGeneration == generation else {
                span.end(result: "stale")
                return
            }
            PagingPageWindow.insert(pageResult.items, into: &slots, at: start)
            span.end(fields: ["item_count": pageResult.items.count])
        } catch {
            guard isCurrent(), activeIdentity == source.identity, activeLoadGeneration == generation else {
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
