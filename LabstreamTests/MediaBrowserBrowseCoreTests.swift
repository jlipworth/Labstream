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

        let playlistPage = try await core.playlistItemsPage(playlistID: "playlist",
                                                            startIndex: 200,
                                                            limit: 100)
        #expect(playlistPage.items.map(\.ratingKey) == ["second", "first"])
        #expect(playlistPage.total == 2)
        #expect(try await core.resumeItems(limit: 3).map(\.ratingKey) == ["resume"])
        #expect(try await core.nextUp(limit: 3).map(\.ratingKey) == ["next"])
        let latest = try await core.latestItems(parentID: nil, includeItemTypes: "Movie", limit: 3)
        #expect(latest.map(\.ratingKey) == ["latest"])
        #expect(latest.first?.thumb?.hasPrefix("emby://") == true)
        #expect(try await core.metadata(itemID: "meta")?.ratingKey == "meta")
        try await core.setPlayed(itemID: "meta", played: false)

        let requests = await transport.requests
        #expect(requests.first?.url?.query?.contains("StartIndex=200") == true)
        #expect(requests.first?.url?.query?.contains("Limit=100") == true)
        #expect(requests.last?.httpMethod == "DELETE")
        #expect(requests.allSatisfy { $0.url?.path.hasPrefix("/emby/") == true })
    }

    @Test func latestItemsRoutesHomeAndMusicProfilesByIntent() async throws {
        let recordedProfiles = TestLockedBox<[MediaBrowserMetadataFieldProfile]>([])
        let core = MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(
                server: URL(string: "https://media.example/root")!, token: "t", userID: "u",
                identity: JellyfinClientIdentity(client: "c", device: "d", deviceId: "id", version: "v")
            ),
            adapter: MetadataProfileProbeBrowseAdapter(recordedProfiles: recordedProfiles),
            send: { _ in Self.arrayJSON(ids: []) }
        )

        _ = try await core.latestItems(parentID: "video", includeItemTypes: "Movie", limit: 1)
        _ = try await core.latestItems(
            parentID: "music",
            includeItemTypes: "Audio",
            limit: 1,
            metadataProfile: MediaBrowserMetadataFieldProfiles.music
        )

        #expect(recordedProfiles.value.map(\.purpose) == [.home, .music])
        #expect(recordedProfiles.value.map(\.fields) == [
            MediaBrowserLibraryFields.fullItem,
            MediaBrowserLibraryFields.fullItem,
        ])
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

    @Test func sharedExecutionRunsTransportAndDecodeOffMainThread() async throws {
        let transportRanOnMain = TestLockedBox<Bool?>(nil)
        let core = MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(
                server: URL(string: "https://media.example/root")!, token: "t", userID: "u",
                identity: JellyfinClientIdentity(client: "c", device: "d", deviceId: "id", version: "v")
            ),
            adapter: JellyfinBrowseCoreAdapter(),
            send: { _ in
                transportRanOnMain.withValue { $0 = Thread.isMainThread }
                return Data(#"{"value":"decoded"}"#.utf8)
            }
        )
        let request = URLRequest(url: URL(string: "https://media.example/root/probe")!)

        let observation = try await core.execute(
            request,
            as: ExecutionProbePayload.self
        ) { payload in
            ExecutionProbeObservation(value: payload.value,
                                      decodeRanOnMain: payload.decodeRanOnMain,
                                      transformRanOnMain: Thread.isMainThread)
        }

        #expect(transportRanOnMain.value == false)
        #expect(observation.value == "decoded")
        #expect(!observation.decodeRanOnMain)
        #expect(!observation.transformRanOnMain)
    }

    @Test func productionItemsPageMapsDTOsOffMainThread() async throws {
        ExecutionProbeFlavor.mapRanOnMain.withValue { $0 = nil }
        let core = MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(
                server: URL(string: "https://media.example/root")!, token: "t", userID: "u",
                identity: JellyfinClientIdentity(client: "c", device: "d", deviceId: "id", version: "v")
            ),
            adapter: ExecutionProbeBrowseAdapter(),
            send: { _ in Self.itemsJSON(ids: ["mapped"]) }
        )

        let page = try await core.itemsPage(MediaBrowserItemsQuery(
            parentID: "library", limit: 1, fields: MediaBrowserLibraryFields.gridItem
        ))

        #expect(page.items.map(\.ratingKey) == ["mapped"])
        #expect(ExecutionProbeFlavor.mapRanOnMain.value == false)
    }

    @Test func jellyfinFacadeCoreKeepsImmutableAuthenticatedContext() async throws {
        let requests = TestLockedBox<[URLRequest]>([])
        let stub = TestURLProtocolStub { request in
            requests.withValue { $0.append(request) }
            return (Self.httpResponse(for: request), Self.itemsJSON(ids: ["snapshot"]))
        }
        let session = URLSession(configuration: stub.configuration)
        defer { session.invalidateAndCancel() }
        let model = AppModel(identity: Self.clientIdentity(), activeBackend: .jellyfin)
        model.jellyfinServerBaseURL = URL(string: "https://jellyfin-a.example/root")!
        model.jellyfinAccessToken = "token-A"
        model.jellyfinUserID = "user-A"
        let core = try JellyfinBrowseService(appModel: model, session: session).browseCore()

        model.jellyfinServerBaseURL = URL(string: "https://jellyfin-b.example/replacement")!
        model.jellyfinAccessToken = "token-B"
        model.jellyfinUserID = "user-B"
        model.identity = ClientIdentity(clientIdentifier: "replacement-device",
                                        product: "Replacement", version: "2",
                                        deviceName: "Replacement Mac")

        let page = try await core.itemsPage(MediaBrowserItemsQuery(
            parentID: "library", limit: 1, fields: MediaBrowserLibraryFields.gridItem
        ))

        #expect(page.items.map(\.ratingKey) == ["snapshot"])
        let request = try #require(requests.value.first)
        #expect(request.url?.host == "jellyfin-a.example")
        #expect(request.url?.path == "/root/Items")
        #expect(request.url?.query?.contains("userId=user-A") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?
            .contains("Token=\"token-A\"") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?
            .contains("DeviceId=\"device\"") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?
            .contains("replacement-device") == false)
    }

    @Test func embyFacadeCoreKeepsImmutableAuthenticatedContext() async throws {
        let requests = TestLockedBox<[URLRequest]>([])
        let stub = TestURLProtocolStub { request in
            requests.withValue { $0.append(request) }
            return (Self.httpResponse(for: request), Self.itemsJSON(ids: ["snapshot"]))
        }
        let session = URLSession(configuration: stub.configuration)
        defer { session.invalidateAndCancel() }
        let model = AppModel(identity: Self.clientIdentity(), activeBackend: .emby)
        model.embyServerBaseURL = URL(string: "https://emby-a.example/root")!
        model.embyAccessToken = "token-A"
        model.embyUserID = "user-A"
        let core = try EmbyBrowseService(appModel: model, session: session).browseCore()

        model.embyServerBaseURL = URL(string: "https://emby-b.example/replacement")!
        model.embyAccessToken = "token-B"
        model.embyUserID = "user-B"
        model.identity = ClientIdentity(clientIdentifier: "replacement-device",
                                        product: "Replacement", version: "2",
                                        deviceName: "Replacement Mac")

        let page = try await core.itemsPage(MediaBrowserItemsQuery(
            parentID: "library", limit: 1, fields: MediaBrowserLibraryFields.gridItem
        ))

        #expect(page.items.map(\.ratingKey) == ["snapshot"])
        let request = try #require(requests.value.first)
        #expect(request.url?.host == "emby-a.example")
        #expect(request.url?.path == "/root/Users/user-A/Items")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-A")
        #expect(request.value(forHTTPHeaderField: "Authorization")?
            .contains("DeviceId=\"device\"") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?
            .contains("replacement-device") == false)
    }

    @Test func facadeCorePreservesHTTPErrorMapping() async throws {
        let jellyfinStub = TestURLProtocolStub { request in
            (Self.httpResponse(for: request, status: 503), Data())
        }
        let jellyfinSession = URLSession(configuration: jellyfinStub.configuration)
        defer { jellyfinSession.invalidateAndCancel() }
        let jellyfinModel = AppModel(identity: Self.clientIdentity(), activeBackend: .jellyfin)
        jellyfinModel.jellyfinServerBaseURL = URL(string: "https://jellyfin.example/root")!
        jellyfinModel.jellyfinAccessToken = "token"
        jellyfinModel.jellyfinUserID = "user"
        let jellyfinCore = try JellyfinBrowseService(
            appModel: jellyfinModel, session: jellyfinSession
        ).browseCore()

        do {
            _ = try await jellyfinCore.userViews()
            Issue.record("Expected Jellyfin HTTP status error")
        } catch JellyfinBrowseService.ServiceError.http(let status) {
            #expect(status == 503)
        } catch {
            Issue.record("Unexpected Jellyfin error: \(error)")
        }

        let embyStub = TestURLProtocolStub { request in
            (Self.httpResponse(for: request, status: 429), Data())
        }
        let embySession = URLSession(configuration: embyStub.configuration)
        defer { embySession.invalidateAndCancel() }
        let embyModel = AppModel(identity: Self.clientIdentity(), activeBackend: .emby)
        embyModel.embyServerBaseURL = URL(string: "https://emby.example/root")!
        embyModel.embyAccessToken = "token"
        embyModel.embyUserID = "user"
        let embyCore = try EmbyBrowseService(appModel: embyModel, session: embySession).browseCore()

        do {
            _ = try await embyCore.userViews()
            Issue.record("Expected Emby HTTP status error")
        } catch EmbyBrowseService.ServiceError.http(let status) {
            #expect(status == 429)
        } catch {
            Issue.record("Unexpected Emby error: \(error)")
        }
    }

    @Test func facadeCoreDoesNotRewriteCancellationOrNonHTTPTransportErrors() async throws {
        let cancellationStub = TestURLProtocolStub { _ in throw CancellationError() }
        let cancellationSession = URLSession(configuration: cancellationStub.configuration)
        defer { cancellationSession.invalidateAndCancel() }
        let jellyfinModel = AppModel(identity: Self.clientIdentity(), activeBackend: .jellyfin)
        jellyfinModel.jellyfinServerBaseURL = URL(string: "https://jellyfin.example/root")!
        jellyfinModel.jellyfinAccessToken = "token"
        jellyfinModel.jellyfinUserID = "user"
        let jellyfinCore = try JellyfinBrowseService(
            appModel: jellyfinModel, session: cancellationSession
        ).browseCore()

        let expectedCancellation = CancellationError() as NSError
        do {
            _ = try await jellyfinCore.userViews()
            Issue.record("Expected cancellation error")
        } catch {
            // URLSession bridges URLProtocol failures through NSError and adds task metadata.
            // The domain/code still prove that the facade closure did not rewrite the error.
            let observed = error as NSError
            #expect(observed.domain == expectedCancellation.domain)
            #expect(observed.code == expectedCancellation.code)
            #expect(!(error is JellyfinBrowseService.ServiceError))
        }

        let transportStub = TestURLProtocolStub { _ in throw BrowseCoreTestFailure.transport }
        let transportSession = URLSession(configuration: transportStub.configuration)
        defer { transportSession.invalidateAndCancel() }
        let embyModel = AppModel(identity: Self.clientIdentity(), activeBackend: .emby)
        embyModel.embyServerBaseURL = URL(string: "https://emby.example/root")!
        embyModel.embyAccessToken = "token"
        embyModel.embyUserID = "user"
        let embyCore = try EmbyBrowseService(
            appModel: embyModel, session: transportSession
        ).browseCore()

        let expectedTransport = BrowseCoreTestFailure.transport as NSError
        do {
            _ = try await embyCore.userViews()
            Issue.record("Expected non-HTTP transport error")
        } catch {
            let observed = error as NSError
            #expect(observed.domain == expectedTransport.domain)
            #expect(observed.code == expectedTransport.code)
            #expect(!(error is EmbyBrowseService.ServiceError))
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

    @Test func searchWithSuppliedCatalogNeverEnumeratesUserViewsAgain() async throws {
        let transport = BrowseCoreScriptedTransport { request in
            guard request.url?.path == "/root/Items" else {
                throw BrowseCoreTestFailure.unexpectedRequest
            }
            let parentID = URLComponents(url: try #require(request.url),
                                         resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name.lowercased() == "parentid" }?.value ?? "missing"
            return Self.itemsJSON(ids: ["result-\(parentID)"])
        }
        let core = MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(
                server: URL(string: "https://media.example/root")!,
                token: "token",
                userID: "user",
                identity: JellyfinClientIdentity(client: "Labstream", device: "Mac",
                                                  deviceId: "device", version: "1")
            ),
            adapter: JellyfinBrowseCoreAdapter(),
            send: { try await transport.send($0) }
        )
        let views = [
            MediaBrowserLibraryLink(id: "second", title: "Second", collectionType: "movies"),
            MediaBrowserLibraryLink(id: "first", title: "First", collectionType: "movies"),
        ]

        let results = try await core.searchResults(query: "needle",
                                                   limitPerLibrary: 5,
                                                   views: views)

        #expect(results.groups.map(\.title) == ["Second", "First"])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/root/Items" })
        #expect(!requests.contains { $0.url?.path == "/root/UserViews" })
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

    @Test func searchFanoutBoundsPeakConcurrencyAndStillReturnsLibraryOrder() async throws {
        let probe = SearchFanoutProbe()
        let views = (0..<8).map {
            MediaBrowserLibraryLink(id: "library-\($0)", title: "Library \($0)", collectionType: "movies")
        }
        let task = Task { @MainActor in
            try await MediaBrowserSearchFanout.search(
                views: views, query: "q", limitPerLibrary: 2, backendID: .jellyfin
            ) { view, _, _, _ in
                await probe.recordStarted(view.id)
                await probe.waitForRelease(view.id)
                return [Self.mediaItem(id: view.id, type: "movie")]
            }
        }

        await probe.waitUntilStarted(count: MediaBrowserSearchFanout.maximumConcurrentTasks)
        #expect(await probe.started.count == MediaBrowserSearchFanout.maximumConcurrentTasks)

        for index in 0..<views.count {
            await probe.release("library-\(index)")
            if index + MediaBrowserSearchFanout.maximumConcurrentTasks < views.count {
                await probe.waitUntilStarted(
                    count: index + MediaBrowserSearchFanout.maximumConcurrentTasks + 1
                )
            }
        }

        let results = try await task.value
        #expect(results.groups.map(\.libraryID) == views.map(\.id))
    }

    @Test func cancellingSearchFanoutCancelsInFlightLibraryWork() async throws {
        let probe = SearchFanoutProbe()
        let views = (0..<8).map {
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

        await probe.waitUntilStarted(count: MediaBrowserSearchFanout.maximumConcurrentTasks)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await probe.started.count == MediaBrowserSearchFanout.maximumConcurrentTasks)
        #expect(await probe.cancelled.count == MediaBrowserSearchFanout.maximumConcurrentTasks)
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

    nonisolated private static func clientIdentity() -> ClientIdentity {
        ClientIdentity(clientIdentifier: "device", product: "Labstream", version: "1",
                       deviceName: "Mac")
    }

    nonisolated private static func httpResponse(
        for request: URLRequest,
        status: Int = 200
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
    }
}

private struct ExecutionProbePayload: Decodable, Sendable {
    let value: String
    let decodeRanOnMain: Bool

    private enum CodingKeys: String, CodingKey { case value }

    init(from decoder: Decoder) throws {
        decodeRanOnMain = Thread.isMainThread
        value = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value)
    }
}

private struct ExecutionProbeObservation: Sendable {
    let value: String
    let decodeRanOnMain: Bool
    let transformRanOnMain: Bool
}

private enum ExecutionProbeFlavor: MediaBrowserFlavor {
    static let mapRanOnMain = TestLockedBox<Bool?>(nil)

    static var syntheticScheme: String {
        mapRanOnMain.withValue { $0 = Thread.isMainThread }
        return "execution-probe"
    }
}

private struct ExecutionProbeBrowseAdapter: MediaBrowserBrowseCoreAdapter {
    typealias Flavor = ExecutionProbeFlavor
    typealias Identity = JellyfinClientIdentity

    private let base = JellyfinBrowseCoreAdapter()
    var backendID: MediaBackendID { base.backendID }

    func userViewsRequest(_ context: MediaBrowserBrowseContext<Identity>) throws -> URLRequest {
        try base.userViewsRequest(context)
    }

    func itemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                      query: MediaBrowserItemsQuery) throws -> URLRequest {
        try base.itemsRequest(context, query: query)
    }

    func albumArtistsRequest(_ context: MediaBrowserBrowseContext<Identity>, parentID: String?,
                             startIndex: Int?, limit: Int?, nameStartsWith: String?,
                             sortBy: String, sortOrder: String) throws -> URLRequest {
        try base.albumArtistsRequest(context, parentID: parentID, startIndex: startIndex,
                                     limit: limit, nameStartsWith: nameStartsWith,
                                     sortBy: sortBy, sortOrder: sortOrder)
    }

    func playlistItemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                              playlistID: String,
                              startIndex: Int?,
                              limit: Int?) throws -> URLRequest {
        try base.playlistItemsRequest(context, playlistID: playlistID,
                                      startIndex: startIndex, limit: limit)
    }

    func resumeItemsRequest(_ context: MediaBrowserBrowseContext<Identity>, parentID: String?,
                            startIndex: Int?, limit: Int) throws -> URLRequest {
        try base.resumeItemsRequest(context, parentID: parentID, startIndex: startIndex,
                                    limit: limit)
    }

    func nextUpRequest(_ context: MediaBrowserBrowseContext<Identity>, parentID: String?,
                       startIndex: Int?, limit: Int) throws -> URLRequest {
        try base.nextUpRequest(context, parentID: parentID, startIndex: startIndex, limit: limit)
    }

    func latestItemsRequest(_ context: MediaBrowserBrowseContext<Identity>, parentID: String?,
                            includeItemTypes: String, limit: Int,
                            metadataProfile: MediaBrowserMetadataFieldProfile) throws -> URLRequest {
        try base.latestItemsRequest(context, parentID: parentID,
                                    includeItemTypes: includeItemTypes, limit: limit,
                                    metadataProfile: metadataProfile)
    }

    func metadataRequest(_ context: MediaBrowserBrowseContext<Identity>,
                         itemID: String) throws -> URLRequest {
        try base.metadataRequest(context, itemID: itemID)
    }

    func setPlayedRequest(_ context: MediaBrowserBrowseContext<Identity>, itemID: String,
                          played: Bool) throws -> URLRequest {
        try base.setPlayedRequest(context, itemID: itemID, played: played)
    }
}

private struct MetadataProfileProbeBrowseAdapter: MediaBrowserBrowseCoreAdapter {
    typealias Flavor = JellyfinFlavor
    typealias Identity = JellyfinClientIdentity

    let backendID: MediaBackendID = .jellyfin
    let recordedProfiles: TestLockedBox<[MediaBrowserMetadataFieldProfile]>
    private let base = JellyfinBrowseCoreAdapter()

    func userViewsRequest(_ context: MediaBrowserBrowseContext<Identity>) throws -> URLRequest {
        try base.userViewsRequest(context)
    }

    func itemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                      query: MediaBrowserItemsQuery) throws -> URLRequest {
        try base.itemsRequest(context, query: query)
    }

    func albumArtistsRequest(_ context: MediaBrowserBrowseContext<Identity>, parentID: String?,
                             startIndex: Int?, limit: Int?, nameStartsWith: String?,
                             sortBy: String, sortOrder: String) throws -> URLRequest {
        try base.albumArtistsRequest(context, parentID: parentID, startIndex: startIndex,
                                     limit: limit, nameStartsWith: nameStartsWith,
                                     sortBy: sortBy, sortOrder: sortOrder)
    }

    func playlistItemsRequest(_ context: MediaBrowserBrowseContext<Identity>,
                              playlistID: String,
                              startIndex: Int?,
                              limit: Int?) throws -> URLRequest {
        try base.playlistItemsRequest(context, playlistID: playlistID,
                                      startIndex: startIndex, limit: limit)
    }

    func resumeItemsRequest(_ context: MediaBrowserBrowseContext<Identity>, parentID: String?,
                            startIndex: Int?, limit: Int) throws -> URLRequest {
        try base.resumeItemsRequest(context, parentID: parentID, startIndex: startIndex, limit: limit)
    }

    func nextUpRequest(_ context: MediaBrowserBrowseContext<Identity>, parentID: String?,
                       startIndex: Int?, limit: Int) throws -> URLRequest {
        try base.nextUpRequest(context, parentID: parentID, startIndex: startIndex, limit: limit)
    }

    func latestItemsRequest(_ context: MediaBrowserBrowseContext<Identity>, parentID: String?,
                            includeItemTypes: String, limit: Int,
                            metadataProfile: MediaBrowserMetadataFieldProfile) throws -> URLRequest {
        recordedProfiles.withValue { $0.append(metadataProfile) }
        return try base.latestItemsRequest(
            context,
            parentID: parentID,
            includeItemTypes: includeItemTypes,
            limit: limit,
            metadataProfile: metadataProfile
        )
    }

    func metadataRequest(_ context: MediaBrowserBrowseContext<Identity>,
                         itemID: String) throws -> URLRequest {
        try base.metadataRequest(context, itemID: itemID)
    }

    func setPlayedRequest(_ context: MediaBrowserBrowseContext<Identity>, itemID: String,
                          played: Bool) throws -> URLRequest {
        try base.setPlayedRequest(context, itemID: itemID, played: played)
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
