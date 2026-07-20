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

    private static func item(_ id: String) -> MediaItem {
        MediaItem(ratingKey: id, title: id.uppercased(), type: "movie")
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
}
