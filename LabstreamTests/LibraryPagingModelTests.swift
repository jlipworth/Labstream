import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Library paging model")
@MainActor
struct LibraryPagingModelTests {
    @Test func initialPageDoesNotWaitForAlphabetRail() async {
        let gate = AlphabetGate()
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "plex:test:nonblocking-alphabet",
            backendLabel: "Plex",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            awaitAlphabetBeforeInitialLoad: false,
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

        gate.release()
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
            awaitAlphabetBeforeInitialLoad: true,
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
            awaitAlphabetBeforeInitialLoad: false,
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
        await probe.waitUntilStarted(start: 4)
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

    @Test func collapsingLaterPageFailurePreservesPublishedPrefix() async {
        struct PageFailure: Error {}
        let source = LibraryPagingSource(
            title: "Movies",
            identity: "collapse-partial-failure",
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            awaitAlphabetBeforeInitialLoad: false,
            collapsesMovieVersions: true,
            fetchPage: { start, _ in
                guard start == 0 else { throw PageFailure() }
                return LibraryPagingPage(
                    items: [Self.movie("alpha", title: "Alpha", year: 2020),
                            Self.movie("bravo", title: "Bravo", year: 2021)],
                    reportedTotal: 4
                )
            },
            fetchAlphabetCounts: { [] }
        )
        let model = LibraryPagingModel()

        await model.load(source: source) { true }

        #expect(model.loadState == .loaded)
        #expect(model.slots.compactMap { $0 }.map(\.ratingKey) == ["alpha", "bravo"])
        #expect(model.total == 2)
        // The final list is unknown, so the final-offset rail must remain unpublished.
        #expect(model.alphabetBuckets.isEmpty)
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
            awaitAlphabetBeforeInitialLoad: false,
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
            awaitAlphabetBeforeInitialLoad: false,
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

    private func collapsingSource(identity: String,
                                  probe: ControlledCollapsingFetch) -> LibraryPagingSource {
        LibraryPagingSource(
            title: "Movies",
            identity: identity,
            backendLabel: "Test",
            pageSize: 2,
            cacheEmptyFirstPage: true,
            awaitAlphabetBeforeInitialLoad: false,
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
    private final class AlphabetGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
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
