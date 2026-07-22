import Foundation
import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Playlist paging model")
@MainActor
struct PlaylistPagingModelTests {
    @Test func moreThanTwoHundredRowsAndCrossPageDuplicatesPreserveEveryPosition() async {
        var expected = (0..<251).map { Self.item("track-\($0)") }
        expected[99] = Self.item("repeat")
        expected[100] = Self.item("repeat")
        expected[200] = Self.item("repeat")
        var requests: [(Int, Int)] = []
        let source = PlaylistPagingSource(identity: "playlist-A", pageSize: 100) { start, limit in
            requests.append((start, limit))
            let end = min(start + limit, expected.count)
            return PlaylistPage(items: Array(expected[start..<end]),
                                reportedTotal: expected.count)
        }
        let model = PlaylistPagingModel()

        await model.loadInitial(source: source)
        await model.loadRemaining(source: source)

        #expect(requests.map(\.0) == [0, 100, 200])
        #expect(requests.allSatisfy { $0.1 == 100 })
        #expect(model.items.map(\.ratingKey) == expected.map(\.ratingKey))
        #expect(model.items.enumerated().filter { $0.element.ratingKey == "repeat" }.map { $0.offset }
                == [99, 100, 200])
        #expect(model.reportedTotal == 251)
        #expect(model.isComplete)
    }

    @Test func missingTotalUsesShortPageTerminationWithoutDeduplication() async {
        let expected = [Self.item("a"), Self.item("a"), Self.item("b"), Self.item("a"), Self.item("c")]
        var starts: [Int] = []
        let source = PlaylistPagingSource(identity: "unknown-total", pageSize: 3) { start, limit in
            starts.append(start)
            let end = min(start + limit, expected.count)
            return PlaylistPage(items: Array(expected[start..<end]), reportedTotal: nil)
        }
        let model = PlaylistPagingModel()

        await model.loadInitial(source: source)
        await model.loadRemaining(source: source)

        #expect(starts == [0, 3])
        #expect(model.items.map(\.ratingKey) == ["a", "a", "b", "a", "c"])
        #expect(model.isComplete)
    }

    @Test func reportedTotalSurvivesServerPageSizeClamp() async {
        let expected = (0..<251).map { Self.item("clamped-\($0)") }
        var starts: [Int] = []
        let source = PlaylistPagingSource(identity: "clamped", pageSize: 100) { start, _ in
            starts.append(start)
            let end = min(start + 50, expected.count)
            return PlaylistPage(items: Array(expected[start..<end]),
                                reportedTotal: expected.count)
        }
        let model = PlaylistPagingModel()

        await model.loadInitial(source: source)
        await model.loadRemaining(source: source)

        #expect(starts == [0, 50, 100, 150, 200, 250])
        #expect(model.items.map(\.ratingKey) == expected.map(\.ratingKey))
        #expect(model.isComplete)
    }

    @Test func laterPageFailureRetainsOrderedPrefixAndRetriesExactOffset() async {
        struct PageFailure: LocalizedError {
            var errorDescription: String? { "Page unavailable." }
        }
        var starts: [Int] = []
        var shouldFail = true
        let source = PlaylistPagingSource(identity: "retry", pageSize: 2) { start, _ in
            starts.append(start)
            if start == 0 {
                return PlaylistPage(items: [Self.item("duplicate"), Self.item("duplicate")],
                                    reportedTotal: 4)
            }
            if shouldFail {
                shouldFail = false
                throw PageFailure()
            }
            return PlaylistPage(items: [Self.item("third"), Self.item("duplicate")], reportedTotal: 4)
        }
        let model = PlaylistPagingModel()

        await model.loadInitial(source: source)
        await model.loadRemaining(source: source)
        #expect(model.items.map(\.ratingKey) == ["duplicate", "duplicate"])
        #expect(model.nextError != nil)
        #expect(!model.isComplete)

        await model.retryNext(source: source)
        await model.loadRemaining(source: source)
        #expect(starts == [0, 2, 2])
        #expect(model.items.map(\.ratingKey) == ["duplicate", "duplicate", "third", "duplicate"])
        #expect(model.nextError == nil)
        #expect(model.isComplete)
    }

    @Test func authorityRetirementRejectsTransportThatIgnoresCancellation() async {
        let probe = SuspendedPlaylistPage()
        let authority = PlaylistAuthorityFlag()
        let source = PlaylistPagingSource(identity: "retired", pageSize: 2,
                                          isCurrent: { authority.isCurrent }) { _, _ in
            await probe.fetch()
        }
        let model = PlaylistPagingModel()
        let task = Task { await model.loadInitial(source: source) }
        await probe.waitUntilStarted()

        authority.isCurrent = false
        task.cancel()
        await probe.release(PlaylistPage(items: [Self.item("stale"), Self.item("stale")],
                                         reportedTotal: 2))
        await task.value

        #expect(model.items.isEmpty)
        #expect(model.loadState != .loaded)
    }

    @Test func laterPageCancellationClearsFlightAndSameIdentityReentryRetries() async {
        let probe = SuspendedPlaylistPage()
        var laterAttempts = 0
        let source = PlaylistPagingSource(identity: "cancel-reentry", pageSize: 2) { start, _ in
            if start == 0 {
                return PlaylistPage(items: [Self.item("first"), Self.item("second")],
                                    reportedTotal: 4)
            }
            laterAttempts += 1
            if laterAttempts == 1 { return await probe.fetch() }
            return PlaylistPage(items: [Self.item("third"), Self.item("fourth")],
                                reportedTotal: 4)
        }
        let model = PlaylistPagingModel()
        await model.loadInitial(source: source)

        let cancelledLoad = Task { await model.loadRemaining(source: source) }
        await probe.waitUntilStarted()
        cancelledLoad.cancel()
        await probe.release(PlaylistPage(items: [Self.item("stale-third"), Self.item("stale-fourth")],
                                         reportedTotal: 4))
        await cancelledLoad.value

        #expect(model.items.map(\.ratingKey) == ["first", "second"])
        #expect(!model.isLoadingNext)
        #expect(model.canLoadMore)

        await model.loadInitial(source: source)
        await model.loadRemaining(source: source)
        #expect(laterAttempts == 2)
        #expect(model.items.map(\.ratingKey) == ["first", "second", "third", "fourth"])
        #expect(model.isComplete)
    }

    @Test func clientIdentityReplacementRetiresProductionSourceAuthority() {
        let appModel = AppModel(
            identity: ClientIdentity(clientIdentifier: "device-A",
                                     product: "Labstream", version: "1", deviceName: "Mac"),
            activeBackend: .plex
        )
        appModel.serverBaseURL = URL(string: "https://plex.example.test")!
        appModel.serverToken = "token"
        let playlist = Self.item("playlist")
        let oldSessionKey = appModel.activeBrowseSessionKey
        let oldSource = PlaylistPagingSource(playlist: playlist, appModel: appModel)

        appModel.identity = ClientIdentity(clientIdentifier: "device-B",
                                           product: "Labstream", version: "2", deviceName: "Mac")
        let newSource = PlaylistPagingSource(playlist: playlist, appModel: appModel)

        #expect(appModel.activeBrowseSessionKey == oldSessionKey)
        #expect(!oldSource.isCurrent())
        #expect(oldSource.identity != newSource.identity)
        #expect(newSource.isCurrent())
    }

    @Test func forcedReplacementFencesLateOldGeneration() async {
        let probe = SuspendedPlaylistPage()
        let old = PlaylistPagingSource(identity: "old", pageSize: 2) { _, _ in
            await probe.fetch()
        }
        let replacement = PlaylistPagingSource(identity: "new", pageSize: 2) { _, _ in
            PlaylistPage(items: [Self.item("new")], reportedTotal: 1)
        }
        let model = PlaylistPagingModel()
        let oldTask = Task { await model.loadInitial(source: old) }
        await probe.waitUntilStarted()

        await model.loadInitial(source: replacement, force: true)
        await probe.release(PlaylistPage(items: [Self.item("old-1"), Self.item("old-2")], reportedTotal: 2))
        await oldTask.value

        #expect(model.items.map(\.ratingKey) == ["new"])
        #expect(model.reportedTotal == 1)
        #expect(model.isComplete)
    }

    private static func item(_ id: String) -> MediaItem {
        MediaItem(ratingKey: id, title: id, type: "track")
    }
}

@MainActor
private final class PlaylistAuthorityFlag {
    var isCurrent = true
}

private actor SuspendedPlaylistPage {
    private var continuation: CheckedContinuation<PlaylistPage, Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func fetch() async -> PlaylistPage {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(_ page: PlaylistPage) {
        continuation?.resume(returning: page)
        continuation = nil
    }
}
