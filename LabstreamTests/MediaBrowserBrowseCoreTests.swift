import Foundation
import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Shared MediaBrowser browse core")
@MainActor
struct MediaBrowserBrowseCoreTests {
    @Test func jellyfinCorePreservesBasePathPagingTotalsAndSyntheticURIs() async throws {
        let transport = BrowseCoreScriptedTransport { request in
            switch request.url?.path {
            case "/root/UserViews":
                return Data(#"{"Items":[{"Id":"lib","Name":"Movies","CollectionType":"movies"}]}"#.utf8)
            case "/root/Items":
                return Data(#"{"Items":[{"Id":"m1","Name":"One","Type":"Movie","ImageTags":{"Primary":"tag"}}],"TotalRecordCount":42}"#.utf8)
            case "/root/Artists/AlbumArtists":
                return Data(#"{"Items":[{"Id":"artist","Name":"Artist","Type":"MusicArtist"}],"TotalRecordCount":7}"#.utf8)
            default:
                throw BrowseCoreTestFailure.unexpectedRequest
            }
        }
        let core = MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(
                server: URL(string: "https://media.example/root")!,
                token: "token",
                userID: "user",
                identity: JellyfinClientIdentity(client: "Labstream", device: "Mac", deviceId: "device", version: "1")
            ),
            adapter: JellyfinBrowseCoreAdapter(),
            send: { try await transport.send($0) }
        )

        let links = try await core.userViewLinks()
        let page = try await core.itemsPage(MediaBrowserItemsQuery(
            parentID: "lib", recursive: true, startIndex: 20, limit: 10,
            searchTerm: "A & B", fields: JellyfinLibrary.fullItemFields
        ))
        let artists = try await core.albumArtistsPage(parentID: "lib", startIndex: 0, limit: 5,
                                                      nameStartsWith: "A", sortBy: "SortName",
                                                      sortOrder: "Ascending")

        #expect(links == [MediaBrowserLibraryLink(id: "lib", title: "Movies", collectionType: "movies")])
        #expect(page.total == 42)
        #expect(page.items.map(\.ratingKey) == ["m1"])
        #expect(page.items.first?.thumb?.hasPrefix("jellyfin://") == true)
        #expect(artists.total == 7)
        #expect(artists.items.map(\.ratingKey) == ["artist"])

        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == ["/root/UserViews", "/root/Items", "/root/Artists/AlbumArtists"])
        #expect(requests[1].url?.query?.contains("startIndex=20") == true)
        #expect(requests[1].url?.query?.contains("searchTerm=A%20%26%20B") == true)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("MediaBrowser ") == true })
    }

    @Test func embyCorePreservesPlaylistOrderAndCommonCapabilityShapes() async throws {
        let transport = BrowseCoreScriptedTransport { request in
            let path = request.url?.path ?? ""
            if path == "/emby/Playlists/playlist/Items" {
                return Self.itemsJSON(ids: ["second", "first"])
            }
            if path.hasSuffix("/Items/Resume") { return Self.itemsJSON(ids: ["resume"]) }
            if path == "/emby/Shows/NextUp" { return Self.itemsJSON(ids: ["next"]) }
            if path.hasSuffix("/Items/Latest") { return Self.arrayJSON(ids: ["latest"]) }
            if path.hasSuffix("/Items/meta") { return Self.itemJSON(id: "meta") }
            if path.hasSuffix("/PlayedItems/meta") { return Data() }
            throw BrowseCoreTestFailure.unexpectedRequest
        }
        let core = MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(
                server: URL(string: "https://media.example/emby")!,
                token: "token",
                userID: "user",
                identity: EmbyClientIdentity(client: "Labstream", device: "Mac", deviceId: "device", version: "1")
            ),
            adapter: EmbyBrowseCoreAdapter(),
            send: { try await transport.send($0) }
        )

        #expect(try await core.playlistItems(playlistID: "playlist").map(\.ratingKey) == ["second", "first"])
        #expect(try await core.resumeItems(limit: 3).map(\.ratingKey) == ["resume"])
        #expect(try await core.nextUp(limit: 3).map(\.ratingKey) == ["next"])
        let latest = try await core.latestItems(parentID: nil, includeItemTypes: "Movie", limit: 3)
        #expect(latest.map(\.ratingKey) == ["latest"])
        #expect(latest.first?.thumb?.hasPrefix("emby://") == true)
        #expect(try await core.metadata(itemID: "meta")?.ratingKey == "meta")
        try await core.setPlayed(itemID: "meta", played: false)

        let requests = await transport.requests
        #expect(requests.last?.httpMethod == "DELETE")
        #expect(requests.allSatisfy { $0.url?.path.hasPrefix("/emby/") == true })
    }

    @Test func corePropagatesTransportAndDecodeErrorsWithoutRewritingThem() async throws {
        let context = MediaBrowserBrowseContext(
            server: URL(string: "https://media.example/root")!, token: "t", userID: "u",
            identity: JellyfinClientIdentity(client: "c", device: "d", deviceId: "id", version: "v")
        )
        let transportFailure = MediaBrowserBrowseCore(
            context: context,
            adapter: JellyfinBrowseCoreAdapter(),
            send: { _ in throw BrowseCoreTestFailure.transport }
        )
        await #expect(throws: BrowseCoreTestFailure.transport) {
            _ = try await transportFailure.userViews()
        }

        let decodeFailure = MediaBrowserBrowseCore(
            context: context,
            adapter: JellyfinBrowseCoreAdapter(),
            send: { _ in Data("not-json".utf8) }
        )
        await #expect(throws: (any Error).self) {
            _ = try await decodeFailure.userViews()
        }
    }

    @Test func searchFanoutPreservesLibraryOrderDespiteReverseCompletionAndOmitsEmptyLibraries() async throws {
        let completion = SearchFanoutProbe()
        let views = [
            MediaBrowserLibraryLink(id: "first", title: "First", collectionType: "movies"),
            MediaBrowserLibraryLink(id: "empty", title: "Empty", collectionType: "tvshows"),
            MediaBrowserLibraryLink(id: "last", title: "Last", collectionType: "homevideos"),
        ]

        let search = Task { @MainActor in
            try await MediaBrowserSearchFanout.search(
                views: views, query: "needle", limitPerLibrary: 9, backendID: .emby
            ) { view, query, limit, itemTypes in
                #expect(query == "needle")
                #expect(limit == 9)
                await completion.recordStarted(view.id)
                await completion.waitForRelease(view.id)
                await completion.recordCompleted(view.id)

                switch view.id {
                case "first":
                    return [Self.mediaItem(id: "one", type: "movie")]
                case "empty":
                    #expect(itemTypes == "Series,Season,Episode")
                    return []
                default:
                    #expect(itemTypes == "Video")
                    return [Self.mediaItem(id: "three", type: "video")]
                }
            }
        }

        await completion.waitUntilStarted(count: views.count)
        for id in ["last", "empty", "first"] {
            await completion.release(id)
            await completion.waitUntilCompleted(id)
        }

        let results = try await search.value
        #expect(await completion.completed == ["last", "empty", "first"])
        #expect(results.groups.map(\.title) == ["First", "Last"])
        #expect(results.groups.map(\.id) == ["emby-library-first", "emby-library-last"])
    }

    @Test func searchFanoutRemainsAllOrErrorOnPartialFailure() async throws {
        let views = [
            MediaBrowserLibraryLink(id: "success", title: "Success", collectionType: "movies"),
            MediaBrowserLibraryLink(id: "failure", title: "Failure", collectionType: "movies"),
        ]

        await #expect(throws: BrowseCoreTestFailure.transport) {
            _ = try await MediaBrowserSearchFanout.search(
                views: views, query: "q", limitPerLibrary: 2, backendID: .jellyfin
            ) { view, _, _, _ in
                if view.id == "failure" { throw BrowseCoreTestFailure.transport }
                return [Self.mediaItem(id: "partial", type: "movie")]
            }
        }
    }

    @Test func cancellingSearchFanoutCancelsInFlightLibraryWork() async throws {
        let probe = SearchFanoutProbe()
        let views = (0..<3).map {
            MediaBrowserLibraryLink(id: "library-\($0)", title: "Library \($0)", collectionType: "movies")
        }
        let task = Task {
            try await MediaBrowserSearchFanout.search(
                views: views, query: "q", limitPerLibrary: 2, backendID: .jellyfin
            ) { view, _, _, _ in
                await probe.recordStarted(view.id)
                do {
                    try await Task.sleep(for: .seconds(30))
                    return []
                } catch {
                    await probe.recordCancelled(view.id)
                    throw error
                }
            }
        }

        while await probe.started.count < views.count {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await probe.cancelled.count == views.count)
    }

    nonisolated private static func itemJSON(id: String) -> Data {
        Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie","ImageTags":{"Primary":"tag"}}"#.utf8)
    }

    nonisolated private static func itemsJSON(ids: [String]) -> Data {
        let rows = ids.map { String(data: itemJSON(id: $0), encoding: .utf8)! }.joined(separator: ",")
        return Data("{\"Items\":[\(rows)],\"TotalRecordCount\":\(ids.count)}".utf8)
    }

    nonisolated private static func arrayJSON(ids: [String]) -> Data {
        let rows = ids.map { String(data: itemJSON(id: $0), encoding: .utf8)! }.joined(separator: ",")
        return Data("[\(rows)]".utf8)
    }

    nonisolated private static func mediaItem(id: String, type: String) -> MediaItem {
        MediaItem(ratingKey: id, key: "/items/\(id)", title: id, type: type)
    }
}

private enum BrowseCoreTestFailure: Error, Equatable {
    case unexpectedRequest
    case transport
}

private actor BrowseCoreScriptedTransport {
    private(set) var requests: [URLRequest] = []
    private let response: @Sendable (URLRequest) throws -> Data

    init(response: @escaping @Sendable (URLRequest) throws -> Data) {
        self.response = response
    }

    func send(_ request: URLRequest) throws -> Data {
        requests.append(request)
        return try response(request)
    }
}

private actor SearchFanoutProbe {
    private(set) var started: [String] = []
    private(set) var completed: [String] = []
    private(set) var cancelled: [String] = []
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []

    func recordStarted(_ id: String) {
        started.append(id)
        let ready = startedWaiters.filter { started.count >= $0.count }
        startedWaiters.removeAll { started.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitUntilStarted(count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func waitForRelease(_ id: String) async {
        if released.remove(id) != nil { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[id] = continuation
        }
    }

    func release(_ id: String) {
        if let continuation = releaseWaiters.removeValue(forKey: id) {
            continuation.resume()
        } else {
            released.insert(id)
        }
    }

    func recordCompleted(_ id: String) {
        completed.append(id)
        completionWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
    }

    func waitUntilCompleted(_ id: String) async {
        guard !completed.contains(id) else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[id, default: []].append(continuation)
        }
    }

    func recordCancelled(_ id: String) { cancelled.append(id) }
}
