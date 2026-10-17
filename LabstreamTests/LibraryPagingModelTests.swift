import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Library paging model")
@MainActor
struct LibraryPagingModelTests {
    @Test func initialPagePublishesBeforeAlphabetRailCompletes() async {
        let gate = MainActorSignal()
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "plex:test:nonblocking-alphabet",
            backendLabel: "Plex",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            fetchPage: { _, _ in
                LibraryPagingPage(items: [Self.item("a"), Self.item("b")], reportedTotal: 4)
            },
            fetchAlphabetCounts: {
                await gate.wait()
                return [("A", 2), ("C", 2)]
            }
        )
        let model = LibraryPagingModel()

        let loadTask = Task {
            await model.load(source: source) { true }
        }
        for _ in 0..<20 {
            if case .loaded = model.loadState { break }
            await Task.yield()
        }

        #expect(model.slots.compactMap { $0 }.count == 2)
        #expect(model.alphabetBuckets.isEmpty)

        gate.signal()
        await loadTask.value
        #expect(model.alphabetBuckets.map(\.display) == ["A", "C"])
    }

    @Test func loadedAlphabetTargetDoesNotRefetchItsPage() async {
        var starts: [Int] = []
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "plex:test:movies",
            backendLabel: "Plex",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            fetchPage: { start, _ in
                starts.append(start)
                let items = start == 0
                    ? [Self.item("a"), Self.item("b")]
                    : [Self.item("c"), Self.item("d")]
                return LibraryPagingPage(items: items, reportedTotal: 4)
            },
            fetchAlphabetCounts: { [("A", 2), ("C", 2)] }
        )
        let model = LibraryPagingModel()

        await model.load(source: source) { true }
        #expect(starts == [0])
        #expect(model.isLoaded(at: 1))

        await model.loadPage(containing: 1, source: source) { true }
        #expect(starts == [0])

        await model.loadPage(containing: 2, source: source) { true }
        #expect(starts == [0, 2])
        #expect(model.isLoaded(at: 2))

        await model.loadPage(containing: 3, source: source) { true }
        #expect(starts == [0, 2])
    }

    @Test func duplicatePageCallersAwaitOneFetchAndOnePublishedPage() async {
        let probe = ControlledPageFetch()
        let source = source(identity: "coalesced", probe: probe)
        let model = LibraryPagingModel()
        await model.load(source: source) { true }

        let prefetch = Task { await model.loadPage(containing: 2, source: source) { true } }
        let railJump = Task { await model.loadPage(containing: 3, source: source) { true } }
        await probe.waitUntilStarted(count: 1)
        #expect(await probe.startedCount == 1)

        await probe.succeed(attempt: 0, items: [Self.item("c"), Self.item("d")], total: 4)
        await prefetch.value
        await railJump.value

        #expect(await probe.startedCount == 1)
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["a", "b", "c", "d"])
    }

    @Test func joinedCallerRetriesSharedFailureOnlyOnce() async {
        let probe = ControlledPageFetch()
        let source = source(identity: "coalesced-retry", probe: probe)
        let model = LibraryPagingModel()
        await model.load(source: source) { true }

        let prefetch = Task { await model.loadPage(containing: 2, source: source) { true } }
        await probe.waitUntilStarted(count: 1)

        // `isCurrent` runs synchronously before the joiner registers. Once this signal's waiter
        // resumes, the rail-jump task has continued to its next suspension and joined flight 1.
        let railJumpJoined = MainActorSignal()
        let railJump = Task {
            await model.loadPage(containing: 3, source: source) {
                railJumpJoined.signal()
                return true
            }
        }
        await railJumpJoined.wait()

        await probe.fail(attempt: 0)
        await probe.waitUntilStarted(count: 2)
        #expect(await probe.startedCount == 2)
        await probe.fail(attempt: 1)
        await prefetch.value
        await railJump.value

        #expect(await probe.startedCount == 2)
        #expect(model.slots[2] == nil)
        #expect(model.slots[3] == nil)
    }

    @Test func joinedCallerRetriesWhenSharedSuccessLeavesItsSlotEmpty() async {
        let probe = ControlledPageFetch()
        let source = source(identity: "coalesced-short-page", probe: probe)
        let model = LibraryPagingModel()
        await model.load(source: source) { true }

        let prefetch = Task { await model.loadPage(containing: 2, source: source) { true } }
        await probe.waitUntilStarted(count: 1)

        let railJumpJoined = MainActorSignal()
        let railJump = Task {
            await model.loadPage(containing: 3, source: source) {
                railJumpJoined.signal()
                return true
            }
        }
        await railJumpJoined.wait()

        // The shared page technically succeeds but omits the rail jump's slot. Match the old
        // coalescing behavior by retrying that page once rather than stranding the placeholder.
        await probe.succeed(attempt: 0, items: [Self.item("c")], total: 4)
        await probe.waitUntilStarted(count: 2)
        await probe.succeed(attempt: 1, items: [Self.item("c"), Self.item("d")], total: 4)
        await prefetch.value
        await railJump.value

        #expect(await probe.startedCount == 2)
        #expect(model.slots[2]?.ratingKey == "c")
        #expect(model.slots[3]?.ratingKey == "d")
    }

    @Test func cancelledWaiterDoesNotCancelSharedPageFlight() async {
        let probe = ControlledPageFetch()
        let source = source(identity: "waiter-cancellation", probe: probe)
        let model = LibraryPagingModel()
        await model.load(source: source) { true }

        let cancelledWaiter = Task {
            await model.loadPage(containing: 2, source: source) { true }
        }
        let survivingWaiter = Task {
            await model.loadPage(containing: 3, source: source) { true }
        }
        await probe.waitUntilStarted(count: 1)

        cancelledWaiter.cancel()
        await cancelledWaiter.value
        #expect(await probe.cancelledAttempts.isEmpty)
        #expect(await probe.startedCount == 1)

        await probe.succeed(attempt: 0, items: [Self.item("c"), Self.item("d")], total: 4)
        await survivingWaiter.value
        #expect(model.slots[2]?.ratingKey == "c")
        #expect(model.slots[3]?.ratingKey == "d")
    }

    @Test func cancellingLastWaiterDropsFlightAndDoesNotRetainModel() async throws {
        let probe = ControlledPageFetch()
        let source = source(identity: "last-waiter-cancellation", probe: probe)
        var model: LibraryPagingModel? = LibraryPagingModel()
        await model?.load(source: source) { true }
        weak var weakModel = model

        let enteredLoadPage = MainActorSignal()
        let waiter = Task { @MainActor [weak model] in
            await model?.loadPage(containing: 2, source: source) {
                enteredLoadPage.signal()
                return true
            }
        }
        await enteredLoadPage.wait()
        await probe.waitUntilStarted(count: 1)
        let abandonedFlight = try #require(model?.pageFlightTaskForTesting(page: 1))

        waiter.cancel()
        await waiter.value
        await probe.waitUntilCancelled(count: 1)
        #expect(model?.pageFlightTaskForTesting(page: 1) == nil)

        // The transport deliberately remains suspended after observing cancellation. The model
        // must still deallocate because the abandoned task only holds a weak reference to it.
        model = nil
        #expect(weakModel == nil)

        await probe.succeed(attempt: 0, items: [Self.item("stale-c")], total: 4)
        await abandonedFlight.value
    }

    @Test func forceResetCancelsAndFencesOldPageFlight() async throws {
        let probe = ControlledPageFetch()
        let source = source(identity: "reset", probe: probe)
        let model = LibraryPagingModel()
        await model.load(source: source) { true }

        let oldWaiter = Task { await model.loadPage(containing: 2, source: source) { true } }
        await probe.waitUntilStarted(count: 1)
        let oldFlight = try #require(model.pageFlightTaskForTesting(page: 1))

        let resetSource = LibraryPagingSource(
            title: "Movies",
            identity: "reset",
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            fetchPage: { start, _ in
                #expect(start == 0)
                return LibraryPagingPage(items: [Self.item("new-a"), Self.item("new-b")],
                                         reportedTotal: 2)
            },
            fetchAlphabetCounts: { [] }
        )
        await model.load(source: resetSource, force: true) { true }
        await oldWaiter.value
        await probe.waitUntilCancelled(count: 1)

        // Simulate a transport that ignores cancellation and eventually returns stale bytes.
        await probe.succeed(attempt: 0, items: [Self.item("old-c"), Self.item("old-d")], total: 4)
        await oldFlight.value

        #expect(await probe.cancelledAttempts == [0])
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["new-a", "new-b"])
        #expect(model.total == 2)
    }

    @Test func failedPageFlightIsRemovedAndNextCallerRetries() async {
        let probe = ControlledPageFetch()
        let source = source(identity: "retry", probe: probe)
        let model = LibraryPagingModel()
        await model.load(source: source) { true }

        let first = Task { await model.loadPage(containing: 2, source: source) { true } }
        await probe.waitUntilStarted(count: 1)
        await probe.fail(attempt: 0)
        await first.value
        #expect(model.slots[2] == nil)

        let retry = Task { await model.loadPage(containing: 2, source: source) { true } }
        await probe.waitUntilStarted(count: 2)
        #expect(await probe.startedCount == 2)
        await probe.succeed(attempt: 1, items: [Self.item("c"), Self.item("d")], total: 4)
        await retry.value

        #expect(model.slots[2]?.ratingKey == "c")
        #expect(model.slots[3]?.ratingKey == "d")
    }

    @Test func collapsingLoadPublishesDensePageDeltasAndBuildsFinalAlphabetOffsets() async {
        let probe = ControlledCollapsingFetch(
            first: LibraryPagingPage(
                items: [Self.movie("alpha-4k", title: "Alpha", year: 2020),
                        Self.movie("bravo", title: "Bravo", year: 2021)],
                reportedTotal: 6
            )
        )
        let source = collapsingSource(identity: "collapse-progressive", probe: probe)
        let model = LibraryPagingModel()
        let load = Task { await model.load(source: source) { true } }

        await probe.waitUntilStarted(start: 2)
        #expect(model.slots.count == 2)
        #expect(model.slots.allSatisfy { $0 != nil })
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["alpha-4k", "bravo"])
        #expect(model.total == 2)
        #expect(model.alphabetBuckets.isEmpty)

        await probe.succeed(
            start: 2,
            page: LibraryPagingPage(
                items: [Self.movie("alpha-hd", title: "Alpha", year: 2020),
                        Self.movie("charlie", title: "Charlie", year: 2022)],
                reportedTotal: 6
            )
        )
        // Later pages are requested through a window, so page 4 may already be in flight;
        // wait for page 2's publication itself rather than for page 4's request.
        await probe.waitUntilStarted(start: 4)
        await Self.waitUntil { model.total == 3 }
        #expect(model.slots.count == 3)
        #expect(model.slots.allSatisfy { $0 != nil })
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["alpha-4k", "bravo", "charlie"])
        #expect(model.slots[0]?.versions?.map(\.ratingKey) == ["alpha-4k", "alpha-hd"])
        #expect(model.total == 3)
        #expect(model.alphabetBuckets.isEmpty)

        await probe.succeed(
            start: 4,
            page: LibraryPagingPage(
                items: [Self.movie("charlie-hd", title: "Charlie", year: 2022),
                        Self.movie("delta", title: "Delta", year: 2023)],
                reportedTotal: 6
            )
        )
        await load.value

        #expect(model.slots.allSatisfy { $0 != nil })
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey)
            == ["alpha-4k", "bravo", "charlie", "delta"])
        #expect(model.slots[2]?.versions?.map(\.ratingKey) == ["charlie", "charlie-hd"])
        #expect(model.total == 4)
        #expect(model.alphabetBuckets.map(\.display) == ["A", "B", "C", "D"])
        #expect(model.alphabetBuckets.map(\.offset) == [0, 1, 2, 3])
    }

    @Test func collapsingReloadAfterLaterPageFailureCompletesFullSet() async {
        struct PageFailure: Error {}
        var failLaterPages = true
        var laterPageAttempts = 0
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "collapse-heal-after-error",
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            collapsesMovieVersions: true,
            fetchPage: { start, _ in
                if start == 0 {
                    return LibraryPagingPage(
                        items: [Self.movie("alpha", title: "Alpha", year: 2020),
                                Self.movie("bravo", title: "Bravo", year: 2021)],
                        reportedTotal: 4
                    )
                }
                laterPageAttempts += 1
                if failLaterPages { throw PageFailure() }
                return LibraryPagingPage(
                    items: [Self.movie("charlie", title: "Charlie", year: 2022),
                            Self.movie("delta", title: "Delta", year: 2023)],
                    reportedTotal: 4
                )
            },
            fetchAlphabetCounts: { [] }
        )
        let model = LibraryPagingModel()

        // First load stalls after page 0: partial prefix kept, identity NOT latched.
        await model.load(source: source) { true }
        #expect(model.loadState == .loaded)
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["alpha", "bravo"])
        #expect(model.total == 2)
        // The final list is unknown, so the final-offset rail must remain unpublished.
        #expect(model.alphabetBuckets.isEmpty)
        #expect(laterPageAttempts == 1)

        // The truncation is NOT terminal: because the interrupted load never latched
        // `loadedIdentity`, a same-identity re-entry re-runs the load (re-attempting the failing
        // page) instead of short-circuiting the partial grid. While the source keeps failing,
        // the grid stays partial and the rail stays unpublished.
        await model.load(source: source) { true }
        #expect(laterPageAttempts == 2)
        #expect(model.loadState == .loaded)
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["alpha", "bravo"])
        #expect(model.alphabetBuckets.isEmpty)

        // Transient error clears; same-identity re-entry completes the full item set and builds
        // the final-offset rail instead of freezing the partial grid.
        failLaterPages = false
        await model.load(source: source) { true }
        #expect(model.loadState == .loaded)
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey)
            == ["alpha", "bravo", "charlie", "delta"])
        #expect(model.total == 4)
        #expect(model.alphabetBuckets.map(\.display) == ["A", "B", "C", "D"])
        #expect(model.alphabetBuckets.map(\.offset) == [0, 1, 2, 3])
    }

    @Test func collapsingReloadAfterCancellationCompletesFullSet() async {
        let laterPageEntered = MainActorSignal()
        var cancelPhase = true
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "collapse-heal-after-cancel",
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            collapsesMovieVersions: true,
            fetchPage: { start, _ in
                if start == 0 {
                    return LibraryPagingPage(
                        items: [Self.movie("alpha", title: "Alpha", year: 2020),
                                Self.movie("bravo", title: "Bravo", year: 2021)],
                        reportedTotal: 4
                    )
                }
                if cancelPhase {
                    // Suspend the later page until the load task is cancelled; the sleep then
                    // throws CancellationError, mirroring a navigation push tearing down the
                    // grid's `.task(id:)` mid-load.
                    laterPageEntered.signal()
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                }
                return LibraryPagingPage(
                    items: [Self.movie("charlie", title: "Charlie", year: 2022),
                            Self.movie("delta", title: "Delta", year: 2023)],
                    reportedTotal: 4
                )
            },
            fetchAlphabetCounts: { [] }
        )
        let model = LibraryPagingModel()

        let load = Task { await model.load(source: source) { true } }
        await laterPageEntered.wait()
        load.cancel()
        await load.value

        #expect(model.loadState == .loaded)
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["alpha", "bravo"])
        #expect(model.total == 2)
        #expect(model.alphabetBuckets.isEmpty)

        // Same-identity re-entry after the cancellation-truncated load completes the full set.
        cancelPhase = false
        await model.load(source: source) { true }
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey)
            == ["alpha", "bravo", "charlie", "delta"])
        #expect(model.total == 4)
        #expect(model.alphabetBuckets.map(\.display) == ["A", "B", "C", "D"])
    }

    @Test func fullyLoadedCollapsingShortCircuitsReentryButForceRefetches() async {
        var pageFetches = 0
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "collapse-shortcircuit",
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            collapsesMovieVersions: true,
            fetchPage: { start, _ in
                pageFetches += 1
                if start == 0 {
                    return LibraryPagingPage(
                        items: [Self.movie("alpha", title: "Alpha", year: 2020),
                                Self.movie("bravo", title: "Bravo", year: 2021)],
                        reportedTotal: 4
                    )
                }
                return LibraryPagingPage(
                    items: [Self.movie("charlie", title: "Charlie", year: 2022),
                            Self.movie("delta", title: "Delta", year: 2023)],
                    reportedTotal: 4
                )
            },
            fetchAlphabetCounts: { [] }
        )
        let model = LibraryPagingModel()

        await model.load(source: source) { true }
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey)
            == ["alpha", "bravo", "charlie", "delta"])
        let fetchesAfterFullLoad = pageFetches // page 0 + page 2

        // A completed collapsing load latches the identity: same-identity re-entry short-circuits.
        await model.load(source: source) { true }
        #expect(pageFetches == fetchesAfterFullLoad)

        // Force still re-runs the whole collapsing load.
        await model.load(source: source, force: true) { true }
        #expect(pageFetches == fetchesAfterFullLoad * 2)
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey)
            == ["alpha", "bravo", "charlie", "delta"])
    }

    @Test func lazyLoadShortCircuitsSameIdentityReentry() async {
        var starts: [Int] = []
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "lazy-shortcircuit",
            backendLabel: "Plex",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            fetchPage: { start, _ in
                starts.append(start)
                return LibraryPagingPage(items: [Self.item("a"), Self.item("b")],
                                         reportedTotal: 4)
            },
            fetchAlphabetCounts: { [("A", 2), ("C", 2)] }
        )
        let model = LibraryPagingModel()

        await model.load(source: source) { true }
        #expect(starts == [0])

        // The lazy path is unaffected: page-0-loaded is still "complete", so same-identity
        // re-entry short-circuits without refetching page 0.
        await model.load(source: source) { true }
        #expect(starts == [0])

        // Force still re-runs it.
        await model.load(source: source, force: true) { true }
        #expect(starts == [0, 0])
    }

    @Test func forceResetFencesSuspendedCollapsingSourceCompletion() async {
        let oldProbe = ControlledCollapsingFetch(
            first: LibraryPagingPage(
                items: [Self.movie("old-alpha", title: "Alpha", year: 2020),
                        Self.movie("old-bravo", title: "Bravo", year: 2021)],
                reportedTotal: 4
            )
        )
        let oldSource = collapsingSource(identity: "old-collapse", probe: oldProbe)
        let model = LibraryPagingModel()
        let oldLoad = Task { await model.load(source: oldSource) { true } }
        await oldProbe.waitUntilStarted(start: 2)

        let replacement = LibraryPagingSource(
            title: "Movies",
            identity: "new-collapse",
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            collapsesMovieVersions: true,
            fetchPage: { start, _ in
                #expect(start == 0)
                return LibraryPagingPage(
                    items: [Self.movie("new-charlie", title: "Charlie", year: 2022)],
                    reportedTotal: 1
                )
            },
            fetchAlphabetCounts: { [] }
        )
        await model.load(source: replacement, force: true) { true }

        // The old transport ignores the logical reset and completes later. Its generation and
        // source identity must prevent it from mutating the replacement's collapser/projection.
        await oldProbe.succeed(
            start: 2,
            page: LibraryPagingPage(
                items: [Self.movie("old-charlie", title: "Charlie", year: 2022),
                        Self.movie("old-delta", title: "Delta", year: 2023)],
                reportedTotal: 4
            )
        )
        await oldLoad.value

        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["new-charlie"])
        #expect(model.total == 1)
        #expect(model.alphabetBuckets.map(\.display) == ["C"])
    }

    private func source(identity: String, probe: ControlledPageFetch) -> LibraryPagingSource {
        LibraryPagingSource(
            title: "Movies",
            identity: identity,
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            fetchPage: { start, _ in
                if start == 0 {
                    return LibraryPagingPage(items: [Self.item("a"), Self.item("b")],
                                             reportedTotal: 4)
                }
                return try await probe.fetch()
            },
            fetchAlphabetCounts: { [] }
        )
    }

    @Test func collapsingLaterPagesOverlapInBoundedWindowAndIngestInOrder() async {
        // 1 + 10 pages of distinct movies, each later page taking 50 ms. A serial walk costs
        // about 10 × 50 ms; the window overlaps the round trips without exceeding its bound.
        let pageSize = 2
        let laterPages = 10
        var inFlight = 0
        var maxInFlight = 0
        func page(_ start: Int) -> LibraryPagingPage {
            LibraryPagingPage(
                items: (start..<(start + pageSize)).map {
                    Self.movie("m\($0)", title: String(format: "Title %03d", $0), year: 2000)
                },
                reportedTotal: pageSize * (laterPages + 1))
        }
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "collapse-window",
            backendLabel: "Test",
            pageSize: pageSize,
            cacheEmptyFirstPage: true,
            collapsesMovieVersions: true,
            fetchPage: { start, _ in
                if start == 0 { return page(0) }
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
                defer { inFlight -= 1 }
                // Later offsets answer faster, so completion order differs from offset order.
                try await Task.sleep(for: .milliseconds(50 - start))
                return page(start)
            },
            fetchAlphabetCounts: { [] }
        )
        let model = LibraryPagingModel()
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await model.load(source: source) { true } }
        print("perf.collapsing_window elapsed_ms=\(elapsed.components.attoseconds / 1_000_000_000_000_000 + elapsed.components.seconds * 1000) later_pages=\(laterPages) max_in_flight=\(maxInFlight)")

        #expect(maxInFlight == LibraryPagingModel.collapsingPageWindow)
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey)
            == (0..<(pageSize * (laterPages + 1))).map { "m\($0)" })
        #expect(model.alphabetBuckets.map(\.display) == ["T"])
    }

    @Test func collapsingEmptyLaterPageStopsIngestionAtThatPage() async {
        var requested: [Int] = []
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "collapse-empty-stop",
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            collapsesMovieVersions: true,
            fetchPage: { start, _ in
                requested.append(start)
                switch start {
                case 0:
                    return LibraryPagingPage(
                        items: [Self.movie("alpha", title: "Alpha", year: 2020),
                                Self.movie("bravo", title: "Bravo", year: 2021)],
                        reportedTotal: 10)
                case 2:
                    return LibraryPagingPage(items: [], reportedTotal: 10)
                default:
                    // Pages past the empty one may be requested by the window but must never
                    // be ingested.
                    return LibraryPagingPage(
                        items: [Self.movie("late-\(start)", title: "Zulu \(start)", year: 2022)],
                        reportedTotal: 10)
                }
            },
            fetchAlphabetCounts: { [] }
        )
        let model = LibraryPagingModel()
        await model.load(source: source) { true }
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["alpha", "bravo"])
        #expect(model.alphabetBuckets.map(\.display) == ["A", "B"])
        #expect(requested.count <= 1 + LibraryPagingModel.collapsingPageWindow)
    }

    @Test func collapsingFailurePastEmptyPageIsIgnoredLikeASerialWalk() async {
        // Page 4 fails before page 2 answers empty. A serial walk stops at the empty page and
        // never asks for page 4, so the load must still complete (rail published).
        struct PageFailure: Error {}
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "collapse-failure-past-empty",
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            collapsesMovieVersions: true,
            fetchPage: { start, _ in
                switch start {
                case 0:
                    return LibraryPagingPage(
                        items: [Self.movie("alpha", title: "Alpha", year: 2020),
                                Self.movie("bravo", title: "Bravo", year: 2021)],
                        reportedTotal: 10)
                case 2:
                    try await Task.sleep(for: .milliseconds(30))
                    return LibraryPagingPage(items: [], reportedTotal: 10)
                default:
                    throw PageFailure()
                }
            },
            fetchAlphabetCounts: { [] }
        )
        let model = LibraryPagingModel()
        await model.load(source: source) { true }
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["alpha", "bravo"])
        #expect(model.alphabetBuckets.map(\.display) == ["A", "B"])
    }

    @Test func collapsingFastLaterFailureStillIngestsEarlierPages() async {
        // Page 4 fails immediately while page 2 is still in flight. Page 2 must be ingested
        // before the failure ends the load, as in a serial walk; the load stays incomplete.
        struct PageFailure: Error {}
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "collapse-fast-later-failure",
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            collapsesMovieVersions: true,
            fetchPage: { start, _ in
                switch start {
                case 0:
                    return LibraryPagingPage(
                        items: [Self.movie("alpha", title: "Alpha", year: 2020),
                                Self.movie("bravo", title: "Bravo", year: 2021)],
                        reportedTotal: 6)
                case 2:
                    try await Task.sleep(for: .milliseconds(30))
                    return LibraryPagingPage(
                        items: [Self.movie("charlie", title: "Charlie", year: 2022),
                                Self.movie("delta", title: "Delta", year: 2023)],
                        reportedTotal: 6)
                default:
                    throw PageFailure()
                }
            },
            fetchAlphabetCounts: { [] }
        )
        let model = LibraryPagingModel()
        await model.load(source: source) { true }
        #expect(model.loadState == .loaded)
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["alpha", "bravo", "charlie", "delta"])
        #expect(model.alphabetBuckets.isEmpty)
    }

    @Test func collapsingLoadSupersededWhileDrainingDoesNotPublishCompletion() async {
        // Load A stops at an empty page 2 but must wait for its cancelled page-4 fetch, which
        // ignores cancellation. Load B starts during that wait. When A finally resumes it
        // must not publish a completed rail built from B's partial state.
        let probeA = ControlledCollapsingFetch(
            first: LibraryPagingPage(
                items: [Self.movie("alpha", title: "Alpha", year: 2020),
                        Self.movie("bravo", title: "Bravo", year: 2021)],
                reportedTotal: 6))
        let probeB = ControlledCollapsingFetch(
            first: LibraryPagingPage(
                items: [Self.movie("charlie", title: "Charlie", year: 2022),
                        Self.movie("delta", title: "Delta", year: 2023)],
                reportedTotal: 4))
        let model = LibraryPagingModel()
        let loadA = Task { await model.load(source: collapsingSource(identity: "drain-a", probe: probeA)) { true } }
        await probeA.waitUntilStarted(start: 2)
        await probeA.waitUntilStarted(start: 4)
        await probeA.succeed(start: 2, page: LibraryPagingPage(items: [], reportedTotal: 6))
        for _ in 0..<200 { await Task.yield() }

        let loadB = Task { await model.load(source: collapsingSource(identity: "drain-b", probe: probeB)) { true } }
        await probeB.waitUntilStarted(start: 2)
        await probeA.succeed(start: 4, page: LibraryPagingPage(items: [], reportedTotal: 6))
        await loadA.value
        #expect(model.alphabetBuckets.isEmpty)
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["charlie", "delta"])

        await probeB.succeed(
            start: 2,
            page: LibraryPagingPage(
                items: [Self.movie("echo", title: "Echo", year: 2024),
                        Self.movie("foxtrot", title: "Foxtrot", year: 2025)],
                reportedTotal: 4))
        await loadB.value
        #expect(model.alphabetBuckets.map(\.display) == ["C", "D", "E", "F"])
    }

    /// Yields until `condition` holds, bounded so a regression fails instead of hanging.
    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
        #expect(condition())
    }

    private func collapsingSource(identity: String,
                                  probe: ControlledCollapsingFetch) -> LibraryPagingSource {
        LibraryPagingSource(
            title: "Movies",
            identity: identity,
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            collapsesMovieVersions: true,
            fetchPage: { start, _ in try await probe.fetch(start: start) },
            fetchAlphabetCounts: { [] }
        )
    }

    private static func item(_ id: String) -> MediaItem {
        MediaItem(ratingKey: id, title: id.uppercased(), type: "movie")
    }

    private static func movie(_ id: String, title: String, year: Int) -> MediaItem {
        MediaItem(ratingKey: id, title: title, type: "movie", year: year)
    }

    @MainActor
    private final class MainActorSignal {
        private var continuation: CheckedContinuation<Void, Never>?
        private var signalled = false

        func wait() async {
            guard !signalled else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func signal() {
            guard !signalled else { return }
            signalled = true
            continuation?.resume()
            continuation = nil
        }
    }
}

private actor ControlledCollapsingFetch {
    private let first: LibraryPagingPage
    private var continuations: [Int: CheckedContinuation<LibraryPagingPage, Error>] = [:]
    private var started: Set<Int> = []
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(first: LibraryPagingPage) {
        self.first = first
    }

    func fetch(start: Int) async throws -> LibraryPagingPage {
        if start == 0 { return first }
        started.insert(start)
        for waiter in startWaiters.removeValue(forKey: start) ?? [] {
            waiter.resume()
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[start] = continuation
        }
    }

    func waitUntilStarted(start: Int) async {
        guard !started.contains(start) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[start, default: []].append(continuation)
        }
    }

    func succeed(start: Int, page: LibraryPagingPage) {
        continuations.removeValue(forKey: start)?.resume(returning: page)
    }
}

private actor ControlledPageFetch {
    private struct FetchFailure: Error {}

    private var continuations: [Int: CheckedContinuation<LibraryPagingPage, Error>] = [:]
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var startedCount = 0
    private(set) var cancelledAttempts: [Int] = []

    func fetch() async throws -> LibraryPagingPage {
        let attempt = startedCount
        startedCount += 1
        resumeStartWaiters()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[attempt] = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation(attempt) }
        }
    }

    func succeed(attempt: Int, items: [MediaItem], total: Int) {
        continuations.removeValue(forKey: attempt)?.resume(
            returning: LibraryPagingPage(items: items, reportedTotal: total)
        )
    }

    func fail(attempt: Int) {
        continuations.removeValue(forKey: attempt)?.resume(throwing: FetchFailure())
    }

    func waitUntilStarted(count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func waitUntilCancelled(count: Int) async {
        guard cancelledAttempts.count < count else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append((count, continuation))
        }
    }

    private func recordCancellation(_ attempt: Int) {
        cancelledAttempts.append(attempt)
        let ready = cancellationWaiters.filter { cancelledAttempts.count >= $0.count }
        cancellationWaiters.removeAll { cancelledAttempts.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { startedCount >= $0.count }
        startWaiters.removeAll { startedCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}
