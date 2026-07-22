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

    @ObservationIgnored private var pageFlights: [Int: PageFlight] = [:]
    @ObservationIgnored private var loadedIdentity: String?
    @ObservationIgnored private var activeIdentity: String?
    @ObservationIgnored private var activeLoadGeneration = 0
    /// Movie-version de-dup state (#108), present only when the source opts in
    /// (`collapsesMovieVersions`). It incrementally groups new page items and maintains a dense
    /// first-seen projection; `nil` for sources that show items verbatim (Plex, TV, etc.), which
    /// keep the lazy sparse-window paging below.
    @ObservationIgnored private var collapser: MovieVersionCollapser?

    /// One model-owned task per sparse page. Callers register as independent waiters, so cancelling
    /// a prefetching cell cannot cancel a rail jump (or another cell) awaiting the same fetch.
    private struct PageWaiter {
        let continuation: CheckedContinuation<Void, Never>
        let requestsRetryIfSlotRemainsEmpty: Bool
        let requestedIndex: Int
    }

    private struct PageFlight {
        let id: UUID
        var task: Task<Void, Never>
        var waiters: [UUID: PageWaiter] = [:]
    }

    private enum PageFlightAttemptOutcome {
        case success(LibraryPagingPage)
        case failure(Error)
    }

    func load(source: LibraryPagingSource,
              force: Bool = false,
              isCurrent: @MainActor () -> Bool) async {
        let identity = source.identity
        if !force, loadedIdentity == identity, case .loaded = loadState { return }

        activeIdentity = identity
        activeLoadGeneration += 1
        let generation = activeLoadGeneration
        cancelPageFlights()
        pageSize = source.pageSize
        loadState = .loading
        slots = []
        total = 0
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
            ingestCollapsed(first.items)
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
                ingestCollapsed(page.items)
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
            // Bucket offsets index into the collapsed list, which is only meaningful when it
            // is alphabetically ordered and unfiltered — hide the rail otherwise.
            alphabetBuckets = source.supportsAlphabetRail
                ? AlphabetBucket.buckets(fromTitles: collapsed.map(\.title))
                : []
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

    /// Apply only the projection positions changed by the newly fetched page. The collapser
    /// owns stable first-seen indices, so existing representatives update in place and new
    /// representatives append densely. `total` therefore grows monotonically and no page
    /// re-collapses or re-publishes unrelated history.
    private func ingestCollapsed(_ items: [MediaItem]) {
        // Mutate the optional's wrapped value in place. Copying it to a local before mutation
        // would trigger copy-on-write of the accumulated groups and recreate the per-page
        // history cost this path is designed to remove.
        guard let delta = collapser?.ingest(items) else { return }

        if slots.count < delta.count {
            slots.append(contentsOf: repeatElement(nil, count: delta.count - slots.count))
        }
        for update in delta.updates {
            slots[update.index] = update.item
        }
        total = delta.count
    }

    func prefetch(containing index: Int,
                  source: LibraryPagingSource,
                  isCurrent: @escaping @MainActor () -> Bool) async {
        await loadPage(containing: index, source: source, isCurrent: isCurrent)
    }

    /// Whether the displayed slot already has its item. Alphabet jumps use this to stay
    /// purely local for loaded pages instead of re-fetching up to `pageSize` unchanged items.
    func isLoaded(at index: Int) -> Bool {
        slots.indices.contains(index) && slots[index] != nil
    }

    func loadPage(containing index: Int,
                  source: LibraryPagingSource,
                  isCurrent: @escaping @MainActor () -> Bool) async {
        // Collapsing sources load every page up front (#108): everything is already in
        // `slots`, there are no placeholders to fill, and the projected index is NOT a server
        // offset — so scroll-prefetch and rail-jump page loads are no-ops here. This removes
        // the serverOffset translation path entirely (and with it the F2 hole bug).
        guard collapser == nil else { return }

        guard !Task.isCancelled, isCurrent(), activeIdentity == source.identity else { return }
        let generation = activeLoadGeneration
        guard slots.indices.contains(index) else { return }

        // The first page and previously visited pages are already authoritative. In particular,
        // most A-Z taps land inside page 0; fetching that whole page again made a local jump wait
        // on the network and republished every slot, restarting visible artwork work.
        guard slots[index] == nil else { return }

        let window = PagingPageWindow(pageSize: source.pageSize)
        guard let page = window.page(containing: index),
              let start = window.startOffset(forPage: page) else { return }

        if let flight = pageFlights[page] {
            await waitForPageFlight(page: page,
                                    flightID: flight.id,
                                    requestsRetryIfSlotRemainsEmpty: true,
                                    requestedIndex: index)
            return
        }

        let flightID = UUID()
        let task = makePageFlightTask(page: page,
                                      start: start,
                                      flightID: flightID,
                                      attempt: 0,
                                      source: source,
                                      identity: source.identity,
                                      generation: generation,
                                      isCurrent: isCurrent)
        pageFlights[page] = PageFlight(id: flightID, task: task)
        await waitForPageFlight(page: page,
                                flightID: flightID,
                                requestsRetryIfSlotRemainsEmpty: false,
                                requestedIndex: index)
    }

    /// The fetch task weakly captures the model and does not promote that reference until after
    /// the transport returns. Removing the last waiter can therefore cancel/drop the flight
    /// without a model -> task -> model retain cycle, even if the transport ignores cancellation.
    private func makePageFlightTask(
        page: Int,
        start: Int,
        flightID: UUID,
        attempt: Int,
        source: LibraryPagingSource,
        identity: String,
        generation: Int,
        isCurrent: @escaping @MainActor () -> Bool
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            let span = PerformanceInstrumentation.begin(
                .libraryGridPage,
                backend: source.backendLabel,
                fields: ["page": page, "page_size": source.pageSize, "attempt": attempt + 1]
            )
            let outcome: PageFlightAttemptOutcome
            do {
                outcome = .success(try await source.fetchPage(start, source.pageSize))
            } catch {
                outcome = .failure(error)
            }

            let wasCancelled = Task.isCancelled
            guard let self else {
                span.end(result: wasCancelled ? "cancelled" : "orphaned")
                return
            }
            self.completePageFlightAttempt(outcome,
                                           wasCancelled: wasCancelled,
                                           span: span,
                                           page: page,
                                           start: start,
                                           flightID: flightID,
                                           attempt: attempt,
                                           source: source,
                                           identity: identity,
                                           generation: generation,
                                           isCurrent: isCurrent)
        }
    }

    private func completePageFlightAttempt(
        _ outcome: PageFlightAttemptOutcome,
        wasCancelled: Bool,
        span: PerformanceSpan,
        page: Int,
        start: Int,
        flightID: UUID,
        attempt: Int,
        source: LibraryPagingSource,
        identity: String,
        generation: Int,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        guard let flight = pageFlights[page], flight.id == flightID else {
            span.end(result: wasCancelled ? "cancelled" : "stale")
            return
        }
        guard !wasCancelled else {
            span.end(result: "cancelled")
            finishPageFlight(page: page, flightID: flightID)
            return
        }
        guard isCurrent(), activeIdentity == identity, activeLoadGeneration == generation else {
            span.end(result: "stale")
            finishPageFlight(page: page, flightID: flightID)
            return
        }

        switch outcome {
        case .success(let pageResult):
            PagingPageWindow.insert(pageResult.items, into: &slots, at: start)
            span.end(fields: ["item_count": pageResult.items.count])
            if retryPageFlightIfNeeded(flight: flight,
                                        page: page,
                                        start: start,
                                        flightID: flightID,
                                        attempt: attempt,
                                        source: source,
                                        identity: identity,
                                        generation: generation,
                                        isCurrent: isCurrent) {
                return
            }
            finishPageFlight(page: page, flightID: flightID)

        case .failure(let error):
            span.end(result: "failure", fields: ["error": performanceErrorLabel(error)])

            if retryPageFlightIfNeeded(flight: flight,
                                        page: page,
                                        start: start,
                                        flightID: flightID,
                                        attempt: attempt,
                                        source: source,
                                        identity: identity,
                                        generation: generation,
                                        isCurrent: isCurrent) {
                return
            }
            finishPageFlight(page: page, flightID: flightID)
        }
    }

    /// Preserve the old rail-jump contract: a caller that joined a prefetching page gets one
    /// immediate retry while its requested slot is still empty. This applies to fetch failures
    /// and short successful pages. Keeping the retry inside the same flight makes any number of
    /// joiners collectively request at most one retry without a post-completion creation race.
    private func retryPageFlightIfNeeded(
        flight: PageFlight,
        page: Int,
        start: Int,
        flightID: UUID,
        attempt: Int,
        source: LibraryPagingSource,
        identity: String,
        generation: Int,
        isCurrent: @escaping @MainActor () -> Bool
    ) -> Bool {
        let hasStrandedJoiner = flight.waiters.values.contains { waiter in
            waiter.requestsRetryIfSlotRemainsEmpty
                && slots.indices.contains(waiter.requestedIndex)
                && slots[waiter.requestedIndex] == nil
        }
        guard attempt == 0,
              hasStrandedJoiner,
              var current = pageFlights[page],
              current.id == flightID else { return false }

        current.task = makePageFlightTask(page: page,
                                          start: start,
                                          flightID: flightID,
                                          attempt: attempt + 1,
                                          source: source,
                                          identity: identity,
                                          generation: generation,
                                          isCurrent: isCurrent)
        pageFlights[page] = current
        return true
    }

    /// Await one shared flight without transferring cancellation ownership to the caller. A
    /// cancelled waiter resumes immediately; the model-owned task continues for other waiters.
    private func waitForPageFlight(
        page: Int,
        flightID: UUID,
        requestsRetryIfSlotRemainsEmpty: Bool,
        requestedIndex: Int
    ) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      var flight = pageFlights[page],
                      flight.id == flightID else {
                    continuation.resume()
                    return
                }
                flight.waiters[waiterID] = PageWaiter(
                    continuation: continuation,
                    requestsRetryIfSlotRemainsEmpty: requestsRetryIfSlotRemainsEmpty,
                    requestedIndex: requestedIndex
                )
                pageFlights[page] = flight
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPageWaiter(page: page, flightID: flightID, waiterID: waiterID)
            }
        }
    }

    private func cancelPageWaiter(page: Int, flightID: UUID, waiterID: UUID) {
        guard var flight = pageFlights[page], flight.id == flightID,
              let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume()

        if flight.waiters.isEmpty {
            // Remove before cancelling so a transport that ignores cancellation cannot commit
            // into, or delete, a replacement flight for the same page.
            pageFlights.removeValue(forKey: page)
            flight.task.cancel()
        } else {
            pageFlights[page] = flight
        }
    }

    private func finishPageFlight(page: Int, flightID: UUID) {
        guard let flight = pageFlights[page], flight.id == flightID else { return }
        pageFlights.removeValue(forKey: page)
        for waiter in flight.waiters.values { waiter.continuation.resume() }
    }

    private func cancelPageFlights() {
        let flights = Array(pageFlights.values)
        pageFlights.removeAll()
        for flight in flights {
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.continuation.resume() }
        }
    }

#if DEBUG
    /// Deterministic hosted-test seam for awaiting a reset flight after its waiter has detached.
    func pageFlightTaskForTesting(page: Int) -> Task<Void, Never>? {
        pageFlights[page]?.task
    }
#endif

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
