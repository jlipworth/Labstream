#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// PR #505 review regressions in the completed-row side-asset repair: the Plex source refresh
/// must not fetch chapter images from its raw chapter list (#504), and Pause All must keep launch
/// from restoring an inactive session that only side assets need, leaving it to Resume All (#494).
/// A session-scoped `URLProtocol` that runs its handler on a global queue, so one request whose
/// response the test holds does not block the other requests of the same session.
private final class AsyncAnsweringURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let routeHeader = "X-Labstream-Async-Test-Route"
    private static let handlers = TestLockedBox<[String: Handler]>([:])

    final class Stub: @unchecked Sendable {
        let configuration: URLSessionConfiguration
        private let identifier = UUID().uuidString
        init(handler: @escaping Handler) {
            let identifier = identifier
            AsyncAnsweringURLProtocol.handlers.withValue { $0[identifier] = handler }
            configuration = .ephemeral
            configuration.protocolClasses = [AsyncAnsweringURLProtocol.self]
            configuration.httpAdditionalHeaders = [AsyncAnsweringURLProtocol.routeHeader: identifier]
        }
        deinit {
            let identifier = identifier
            AsyncAnsweringURLProtocol.handlers.withValue { $0.removeValue(forKey: identifier) }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: routeHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard let identifier = request.value(forHTTPHeaderField: Self.routeHeader),
              let handler = Self.handlers.value[identifier] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        DispatchQueue.global().async { [self] in
            do {
                var routed = request
                routed.setValue(nil, forHTTPHeaderField: Self.routeHeader)
                let (response, data) = try handler(routed)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

@Suite("Side-asset refresh review regressions", .downloadTestFiles, .serialized)
@MainActor
struct SideAssetRefreshReviewTests {
    nonisolated private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    /// The saved list is [A@0 (cached), B@10s (missing)]. The saved-list worker's fetch of B
    /// fails and the worker exits; only then does the Plex refresh answer, with a rescanned list
    /// [A@0, X@5s]. Before the fix the refresh started a chapter worker from that raw list, which
    /// fetched X and published it as chapter 1, saved chapter B's index.
    @Test func plexRefreshNeverPublishesARawListChapterUnderASavedIndex() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        try #require(await p6AwaitTask(f.manager.completedSideAssetInventoryWorker))
        f.manager.setQueuePausedForTesting(false)
        let model = f.manager.appModel
        let server = URL(string: "https://plex.example.invalid:32400")!
        model.serverBaseURL = server
        model.serverToken = "fixture-token"
        let cached = f.store.chapterImageDestinationURL(ratingKey: f.key.ratingKey, index: 0)
        let slotB = f.store.chapterImageDestinationURL(ratingKey: f.key.ratingKey, index: 1)
        try Self.png.write(to: cached)
        _ = await f.store.updateMetadataAsync(for: f.key) {
            $0.backendKind = .plex
            $0.chapters = [OfflineChapter(tag: "A", startTimeOffset: 0, thumb: "/a"),
                           OfflineChapter(tag: "B", startTimeOffset: 10_000, thumb: "/b")]
            $0.chapterImageRelativePaths = [0: cached.lastPathComponent]
        }
        let row = try #require(f.store.record(for: f.key))

        let metadataEntered = P6Acknowledgement<Bool>()
        let releaseMetadata = DispatchSemaphore(value: 0)
        let images = TestLockedBox<[String]>([])
        let body = Data(#"""
            {"MediaContainer":{"Metadata":[{"ratingKey":"fixture","title":"Fixture","type":"movie",
            "Chapter":[{"tag":"A","startTimeOffset":0,"thumb":"/a"},
                       {"tag":"X","startTimeOffset":5000,"thumb":"/x"}]}]}}
            """#.utf8)
        // `TestURLProtocolStub` answers inside `startLoading`, so a held metadata response would
        // also hold the chapter requests behind it. This stub answers off the loading thread.
        let stub = AsyncAnsweringURLProtocol.Stub { request in
            let url = request.url!
            if url.path.contains("/library/metadata/") {
                metadataEntered.signal(true)
                _ = releaseMetadata.wait(timeout: .now() + 15)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!, body)
            }
            let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value ?? url.path
            images.withValue { $0.append(source) }
            if source.hasPrefix("/b") { throw URLError(.notConnectedToInternet) }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.png)
        }
        let transport = URLSession(configuration: stub.configuration)
        defer { releaseMetadata.signal(); transport.invalidateAndCancel() }
        f.manager.optionalSideAssetSessionForTesting = transport

        #expect(f.manager.rehydrateMissingOptionalSideAssets(
            record: row, attemptKey: f.key, kinds: [.chapterImages, .textSubtitles], reason: "test"))
        #expect(await metadataEntered.wait(seconds: 10) == true)
        // The saved-list worker has failed B and exited before the refresh answers.
        try #require(await p6AwaitTask(Task {
            await f.manager.downloadWorkRegistry.waitForWork(
                for: f.key, kind: .sideCache(.chapterImages))
        }))
        #expect(images.value.contains { $0.hasPrefix("/b") })
        releaseMetadata.signal()
        try #require(await p6AwaitTask(Task {
            await f.manager.downloadWorkRegistry.waitForSideCacheForTesting(for: f.key)
        }))
        await f.manager.drainManagerOperationsForTesting()

        #expect(!images.value.contains { $0.hasPrefix("/x") }, "the raw refreshed list was fetched")
        #expect(!FileManager.default.fileExists(atPath: slotB.path),
                "another chapter's image was published under saved chapter B's index")
        let saved = try #require(f.store.record(for: f.key)?.metadata)
        #expect(saved.chapters?.map(\.tag) == ["A", "B"], "the saved timeline was replaced")
        #expect(saved.chapters?.map(\.startTimeOffset) == [0, 10_000])
        #expect(saved.chapterImageRelativePaths?[1] == nil)
        await f.finish()
    }

    @Test func thumbnailLearnedDuringChapterRepairIsPublishedInThisPass() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        try #require(await p6AwaitTask(f.manager.completedSideAssetInventoryWorker))
        f.manager.setQueuePausedForTesting(false)
        _ = await f.store.updateMetadataAsync(for: f.key) {
            $0.backendKind = .plex
            $0.chapters = [OfflineChapter(tag: "A", startTimeOffset: 0, thumb: "/a"),
                           OfflineChapter(tag: "B", startTimeOffset: 10000)]
        }
        let metadata = try #require(f.store.record(for: f.key)?.metadata)
        let server = URL(string: "https://example.invalid")!
        let entered = P6Acknowledgement<Bool>()
        let release = DispatchSemaphore(value: 0)
        let stub = AsyncAnsweringURLProtocol.Stub { request in
            let url = request.url!
            let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value ?? url.path
            if source.hasPrefix("/a") {
                entered.signal(true)
                _ = release.wait(timeout: .now() + 15)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.png)
        }
        let transport = URLSession(configuration: stub.configuration)
        defer { release.signal(); transport.invalidateAndCancel() }
        f.manager.optionalSideAssetSessionForTesting = transport
        f.manager.cacheChapterImages(for: f.key, item: metadata.makeMediaItem(), backend: .plex,
                                     server: server, token: "fixture")
        try #require(await entered.wait(seconds: 10) == true)
        let refreshed = MediaItem(ratingKey: metadata.ratingKey, title: "Fixture", type: "movie",
                                  chapters: [Chapter(startTimeOffset: 0, thumb: "/a"),
                                             Chapter(startTimeOffset: 10000, thumb: "/b")])
        let adoption = Task {
            await f.manager.adoptRefreshedChapterImages(for: f.key, metadata: metadata,
                currentItem: refreshed, backend: .plex, server: server, token: "fixture")
        }
        for _ in 0..<500 {
            if f.store.record(for: f.key)?.metadata?.chapters?.last?.thumb == "/b" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(f.store.record(for: f.key)?.metadata?.chapters?.last?.thumb == "/b")
        release.signal()
        await adoption.value
        try #require(await p6AwaitTask(Task { await f.manager.downloadWorkRegistry.waitForSideCacheForTesting(for: f.key) }))
        #expect(f.store.record(for: f.key)?.metadata?.chapterImageRelativePaths?[1] != nil)
        await f.finish()
    }

    enum DroppedEdge: CaseIterable { case busy, timeout, stale }

    @Test("S5 repair retries each lost observation", arguments: DroppedEdge.allCases)
    func droppedRepairEdge(_ edge: DroppedEdge) async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        try #require(await p6AwaitTask(f.manager.completedSideAssetInventoryWorker))
        f.manager.setQueuePausedForTesting(false)
        f.manager.completedSideAssetInventories = [:]
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        if edge == .timeout {
            f.manager.sideAssetInventoryWillReadForTesting = { _ = release.wait(timeout: .now() + 10) }
            f.manager.sideAssetInventoryDeadlineForTesting = .after(0)
        }
        var observations = 0
        f.manager.sideAssetInventoryDidObserveForTesting = {
            observations += 1
            guard observations == 1 else { return }
            switch edge {
            case .busy:
                f.manager.rehydrateMissingOptionalSideAssetsForCompletedRows(reason: "foreground")
            case .timeout:
                release.signal()
                f.manager.sideAssetInventoryWillReadForTesting = nil
                f.manager.sideAssetInventoryDeadlineForTesting = nil
            case .stale:
                _ = await f.store.updateMetadataAsync(for: f.key) { $0.thumb = "/new" }
            }
        }
        f.manager.rehydrateMissingOptionalSideAssetsForCompletedRows(reason: "launch")
        try #require(await p6AwaitTask(f.manager.completedSideAssetInventoryWorker))
        try #require(observations >= 1)
        if edge != .busy && observations == 1 {
            #expect(f.manager.completedSideAssetInventories[f.key] == nil)
        }
        await withKnownIssue("S5 (#493) dropped repair after \(edge)") {
            for _ in 0..<50 where observations == 1 { try? await Task.sleep(for: .milliseconds(10)) }
            #expect(observations >= 2)
        }
        f.manager.sideAssetInventoryDidObserveForTesting = nil
        await f.finish()
    }

    /// Under Pause All launch asks for no side-asset-only backend (and so restores no inactive
    /// session, with its network discovery). Resume All's pass hydrates the owed backend from its
    /// own inventory; an ordinary edge afterwards hydrates nothing.
    @Test func pauseAllDefersSideAssetHydrationToResumeAll() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        try #require(await p6AwaitTask(f.manager.completedSideAssetInventoryWorker))
        #expect(f.manager.appModel.activeBackend == .plex)
        // A completed Jellyfin row (the backend that is not selected) misses its poster.
        _ = await f.store.updateMetadataAsync(for: f.key) {
            $0.backendKind = .jellyfin
            $0.thumb = "jellyfin://item/fixture/Primary"
        }
        f.manager.refreshRecords()
        let hydrated = TestLockedBox<[DownloadBackendKind]>([])
        f.manager.completedSideAssetSessionHydrator = { backend in
            hydrated.withValue { $0.append(backend) }
        }
        f.manager.setQueuePausedForTesting(false)
        #expect(await f.manager.backendsOwingCompletedSideAssets() == [.jellyfin],
                "fixture: the row owes a side asset on the inactive backend")

        f.manager.setQueuePausedForTesting(true)
        #expect(await f.manager.backendsOwingCompletedSideAssets().isEmpty,
                "launch under Pause All must not hydrate a backend for side assets alone")
        f.manager.rehydrateMissingOptionalSideAssetsForCompletedRows(reason: "session_restored")
        try #require(await p6AwaitTask(f.manager.completedSideAssetInventoryWorker))
        #expect(hydrated.value.isEmpty)

        f.manager.resumeQueue()
        try #require(await p6AwaitTask(f.manager.completedSideAssetInventoryWorker))
        #expect(hydrated.value == [.jellyfin], "Resume All must hydrate the owed backend")
        #expect(!f.manager.completedSideAssetHydrationOwed)

        // An ordinary repair edge does not restore inactive sessions.
        f.manager.rehydrateMissingOptionalSideAssetsForCompletedRows(reason: "foreground")
        try #require(await p6AwaitTask(f.manager.completedSideAssetInventoryWorker))
        #expect(hydrated.value == [.jellyfin])
        f.manager.completedSideAssetSessionHydrator = nil
        await f.finish()
    }
}
#endif
