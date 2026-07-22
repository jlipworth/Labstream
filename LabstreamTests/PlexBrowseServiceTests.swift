import Foundation
import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Plex browse service")
@MainActor
struct PlexBrowseServiceTests {
    @Test func currentSessionResolutionFailsWithTypedMissingSession() throws {
        let model = AppModel(identity: Self.identity())
        #expect(throws: PlexBrowseService.ServiceError.missingSession) {
            _ = try PlexBrowseService(appModel: model)
        }
    }

    @Test func metadataChildrenAndWatchedUseOneInjectedSessionAndNormalizeResponses() async throws {
        let transport = PlexBrowseTransport { request in
            switch request.url?.path {
            case "/root/library/metadata/movie":
                return Self.metadataJSON(ids: ["movie"])
            case "/root/library/metadata/show/children":
                return Self.metadataJSON(ids: ["season-2", "season-1"])
            case "/root/:/scrobble", "/root/:/unscrobble":
                return Data()
            default:
                throw PlexBrowseTestFailure.unexpectedRequest
            }
        }
        let service = try PlexBrowseService(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token",
                                    serverID: "server"),
            identity: Self.identity(),
            send: { try await transport.send($0) })

        #expect(try await service.metadata(ratingKey: "movie").ratingKey == "movie")
        #expect(try await service.children(ratingKey: "show").map(\.ratingKey) == ["season-2", "season-1"])
        try await service.setPlayed(ratingKey: "movie", played: true)
        try await service.setPlayed(ratingKey: "movie", played: false)

        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == [
            "/root/library/metadata/movie", "/root/library/metadata/show/children",
            "/root/:/scrobble", "/root/:/unscrobble",
        ])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Plex-Token") == "token" })
        #expect(requests[2].url?.query?.contains("key=movie") == true)
    }

    @Test func emptyMetadataAndMalformedPayloadHaveStableTypedFailures() async throws {
        let session = BackendSession(kind: .plex,
                                     baseURL: try #require(URL(string: "https://plex.example.test")),
                                     token: "token")
        let empty = try PlexBrowseService(session: session, identity: Self.identity()) { _ in
            Self.metadataJSON(ids: [])
        }
        await #expect(throws: PlexBrowseService.ServiceError.noMetadataItem) {
            _ = try await empty.metadata(ratingKey: "missing")
        }

        let malformed = try PlexBrowseService(session: session, identity: Self.identity()) { _ in
            Data("not-json".utf8)
        }
        await #expect(throws: PlexError.self) {
            _ = try await malformed.children(ratingKey: "show")
        }
    }

    @Test func librariesPagingAndAlphabetPreserveNativePlexShapes() async throws {
        let transport = PlexBrowseTransport { request in
            switch request.url?.path {
            case "/root/library/sections":
                return Data(#"{"MediaContainer":{"Directory":[{"key":"2","title":"TV","type":"show"},{"key":"1","title":"Movies","type":"movie"}]}}"#.utf8)
            case "/root/library/sections/1/all":
                return Data(#"{"MediaContainer":{"totalSize":41,"Metadata":[{"ratingKey":"m20","title":"Twenty","type":"movie"}]}}"#.utf8)
            case "/root/library/sections/1/firstCharacter":
                return Data(#"{"MediaContainer":{"Directory":[{"key":"A","title":"A","size":3},{"key":"B","title":"B","count":2}]}}"#.utf8)
            default:
                throw PlexBrowseTestFailure.unexpectedRequest
            }
        }
        let service = try PlexBrowseService(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token"),
            identity: Self.identity(),
            send: { try await transport.send($0) })

        #expect(try await service.libraries().map(\.key) == ["2", "1"])
        let page = try await service.sectionPage(sectionKey: "1", startIndex: 20, limit: 10,
                                                 sort: "titleSort")
        #expect(page.items.map(\.ratingKey) == ["m20"])
        #expect(page.total == 41)
        let counts = try await service.alphabetCounts(sectionKey: "1")
        #expect(counts.map(\.display) == ["A", "B"])
        #expect(counts.map(\.count) == [3, 2])

        let requests = await transport.requests
        let pagingQuery = requests[1].url?.query ?? ""
        #expect(pagingQuery.contains("X-Plex-Container-Start=20"))
        #expect(pagingQuery.contains("X-Plex-Container-Size=10"))
        #expect(pagingQuery.contains("sort=titleSort"))
    }

    @Test func productionPageDecodeAndNormalizationRunOffMainActor() async throws {
        let observations = TestLockedBox<[(PlexBrowseResponseExecutor.Stage, Bool)]>([])
        let service = try PlexBrowseService(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token"),
            identity: Self.identity(),
            send: { _ in
                Data(#"{"MediaContainer":{"totalSize":9,"Metadata":[{"ratingKey":"mapped","title":"Mapped","type":"movie"}]}}"#.utf8)
            },
            executionWitness: { stage in
                observations.withValue { $0.append((stage, Thread.isMainThread)) }
            }
        )

        let page = try await service.sectionPage(sectionKey: "1", startIndex: 0, limit: 1)

        #expect(page.items.map(\.ratingKey) == ["mapped"])
        #expect(page.total == 9)
        #expect(observations.value.map(\.0) == [.decode, .transform])
        #expect(observations.value.allSatisfy { !$0.1 })
    }

    @Test func artistFallbackNormalizationUsesTheOffMainTransformSeam() async throws {
        let observations = TestLockedBox<[(PlexBrowseResponseExecutor.Stage, Bool)]>([])
        let service = try PlexBrowseService(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token"),
            identity: Self.identity(),
            send: { _ in
                Data(#"{"MediaContainer":{"Metadata":[{"ratingKey":"album","title":"Album","type":"album"},{"ratingKey":"track","title":"Track","type":"track"}]}}"#.utf8)
            },
            executionWitness: { stage in
                observations.withValue { $0.append((stage, Thread.isMainThread)) }
            }
        )
        let artist = Self.mediaItem(id: "artist", type: "artist")

        let content = try await service.artistDetail(artist: artist, libraryID: nil)

        #expect(content.albums.map(\.ratingKey) == ["album"])
        #expect(observations.value.map(\.0) == [.decode, .transform, .transform])
        #expect(observations.value.allSatisfy { !$0.1 })
    }

    @Test func cancellationPassesThroughWithoutDecodeOrMapping() async throws {
        let stages = TestLockedBox<[PlexBrowseResponseExecutor.Stage]>([])
        let service = try PlexBrowseService(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token"),
            identity: Self.identity(),
            send: { _ in throw CancellationError() },
            executionWitness: { stage in stages.withValue { $0.append(stage) } }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await service.libraries()
        }
        #expect(stages.value.isEmpty)
    }

    @Test func cancellationIgnoringTransportCannotDecodeOrPublishLateBytes() async throws {
        let transport = CancellationIgnoringPlexTransport()
        let stages = TestLockedBox<[PlexBrowseResponseExecutor.Stage]>([])
        let service = try PlexBrowseService(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token"),
            identity: Self.identity(),
            send: { _ in await transport.send() },
            executionWitness: { stage in stages.withValue { $0.append(stage) } }
        )
        let request = Task { @MainActor in try await service.libraries() }
        await transport.waitUntilStarted()

        request.cancel()
        await transport.release(
            Data(#"{"MediaContainer":{"Directory":[{"key":"late","title":"Late","type":"movie"}]}}"#.utf8)
        )

        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(stages.value.isEmpty)
    }

    @Test func cancellationDuringDecodeCannotRunProductionTransform() async throws {
        let stages = TestLockedBox<[PlexBrowseResponseExecutor.Stage]>([])
        let snapshot = PlexBrowseExecutionSnapshot(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token"),
            identity: Self.identity()
        )
        let executor = PlexBrowseResponseExecutor(
            snapshot: snapshot,
            send: { _ in Data(#"{"value":"decoded"}"#.utf8) },
            witness: { stage in stages.withValue { $0.append(stage) } }
        )

        let operation = Task { @MainActor in
            try await executor.execute(
                { snapshot in PlexRequest(url: snapshot.session.baseURL, method: "GET") },
                as: SelfCancellingDecodePayload.self
            ) { $0.value }
        }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(stages.value == [.decode])
    }

    @Test func cancellationDuringExecuteNormalizationCannotReturnSuccess() async throws {
        let stages = TestLockedBox<[PlexBrowseResponseExecutor.Stage]>([])
        let snapshot = PlexBrowseExecutionSnapshot(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token"),
            identity: Self.identity()
        )
        let executor = PlexBrowseResponseExecutor(
            snapshot: snapshot,
            send: { _ in Data(#"{"value":"decoded"}"#.utf8) },
            witness: { stage in stages.withValue { $0.append(stage) } }
        )
        let operation = Task { @MainActor in
            try await executor.execute(
                { snapshot in PlexRequest(url: snapshot.session.baseURL, method: "GET") },
                as: PlainDecodePayload.self
            ) { payload in
                withUnsafeCurrentTask { $0?.cancel() }
                return payload.value
            }
        }

        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(stages.value == [.decode, .transform])
    }

    @Test func cancellationDuringTransformOnlyNormalizationCannotReturnSuccess() async throws {
        let stages = TestLockedBox<[PlexBrowseResponseExecutor.Stage]>([])
        let snapshot = PlexBrowseExecutionSnapshot(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token"),
            identity: Self.identity()
        )
        let executor = PlexBrowseResponseExecutor(
            snapshot: snapshot,
            send: { _ in Data() },
            witness: { stage in stages.withValue { $0.append(stage) } }
        )

        let operation = Task { @MainActor in
            try await executor.transform(["album"]) { values in
                withUnsafeCurrentTask { $0?.cancel() }
                return values
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(stages.value == [.transform])
    }

    @Test func hubsSearchOnDeckAndBatchMetadataKeepServerOrdering() async throws {
        let transport = PlexBrowseTransport { request in
            switch request.url?.path {
            case "/root/hubs":
                return Self.hubsJSON(ids: ["home-2", "home-1"])
            case "/root/hubs/search":
                return Self.hubsJSON(ids: ["match-2", "match-1"])
            case "/root/library/onDeck":
                return Self.metadataJSON(ids: ["resume-2", "resume-1"])
            case "/root/library/metadata/a,b":
                return Self.metadataJSON(ids: ["b", "a"])
            default:
                throw PlexBrowseTestFailure.unexpectedRequest
            }
        }
        let service = try PlexBrowseService(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token"),
            identity: Self.identity(),
            send: { try await transport.send($0) })

        #expect(try await service.hubs().flatMap(\.metadata).map(\.ratingKey) == ["home-2", "home-1"])
        #expect(try await service.search(query: "A & B").flatMap(\.metadata).map(\.ratingKey) == ["match-2", "match-1"])
        #expect(try await service.onDeck().map(\.ratingKey) == ["resume-2", "resume-1"])
        #expect(try await service.metadataItems(ratingKeys: "a,b").map(\.ratingKey) == ["b", "a"])

        let requests = await transport.requests
        #expect(requests[1].url?.query?.contains("query=A%20%26%20B") == true)
    }

    @Test func homeRailPagingPreservesServerPathPagingTypeAndReportedTotal() async throws {
        let transport = PlexBrowseTransport { request in
            guard request.url?.path == "/root/hubs/home/recentlyAdded" else {
                throw PlexBrowseTestFailure.unexpectedRequest
            }
            return Data(#"{"MediaContainer":{"totalSize":73,"Metadata":[{"ratingKey":"m21","title":"Twenty One","type":"movie"}]}}"#.utf8)
        }
        let service = try PlexBrowseService(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "rail-token"),
            identity: Self.identity(),
            send: { try await transport.send($0) })

        let page = try await service.homeRailPage(path: "/hubs/home/recentlyAdded", type: 1,
                                                  start: 20, limit: 10)
        #expect(page.items.map(\.ratingKey) == ["m21"])
        #expect(page.total == 73)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "rail-token")
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL,
                                                    resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [
            URLQueryItem(name: "X-Plex-Container-Start", value: "20"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "10"),
            URLQueryItem(name: "type", value: "1"),
        ])
    }

    @Test func railPagingSourceHasNoDirectPlexExecutionRegression() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testsURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Labstream/Shared/Backend/Paging/RailPagingSource.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("appModel.client.send"))
        #expect(!source.contains("PlexRequest("))
        #expect(source.contains("PlexBrowseService(appModel: appModel)"))
        #expect(source.contains("service.homeRailPage"))
    }

    @Test func musicPlaylistCapabilitiesPreserveOrderAndDuplicateEntries() async throws {
        let transport = PlexBrowseTransport { request in
            switch request.url?.path {
            case "/root/playlists":
                return Self.metadataJSON(ids: ["playlist"], type: "playlist")
            case "/root/playlists/playlist/items":
                return Data(#"{"MediaContainer":{"totalSize":203,"Metadata":[{"ratingKey":"track-2","title":"track-2","type":"track"},{"ratingKey":"track-1","title":"track-1","type":"track"},{"ratingKey":"track-2","title":"track-2","type":"track"}]}}"#.utf8)
            default:
                throw PlexBrowseTestFailure.unexpectedRequest
            }
        }
        let service = try PlexBrowseService(
            session: BackendSession(kind: .plex,
                                    baseURL: try #require(URL(string: "https://plex.example.test/root")),
                                    token: "token"),
            identity: Self.identity(),
            send: { try await transport.send($0) })

        #expect(try await service.musicPlaylists().map(\.ratingKey) == ["playlist"])
        let page = try await service.playlistTracksPage(ratingKey: "playlist",
                                                        start: 200,
                                                        size: 100)
        #expect(page.items.map(\.ratingKey) == ["track-2", "track-1", "track-2"])
        #expect(page.reportedTotal == 203)
        let requests = await transport.requests
        let playlistRequest = try #require(requests.last)
        #expect(playlistRequest.url?.query?.contains("X-Plex-Container-Start=200") == true)
        #expect(playlistRequest.url?.query?.contains("X-Plex-Container-Size=100") == true)
    }

    @Test func delayedSearchPinsBothRequestsToAAndRejectsItAfterSessionBWins() async throws {
        let model = AppModel(identity: Self.identity(), activeBackend: .plex)
        model.serverBaseURL = URL(string: "https://plex.example.test/root")!
        model.serverToken = "token-A"
        let transport = DelayedPlexSearchTransport()
        let display = PlexSearchDisplayProbe()

        let sessionA = try #require(model.backendSession(for: .plex))
        let serviceA = try PlexBrowseService(session: sessionA, identity: model.identity,
                                             send: { try await transport.send($0) })
        let keyA = "\(model.activeBrowseSessionKey):query"
        let staleTask = Task { @MainActor in
            let snapshot = try await serviceA.searchWithLibraries(query: "query")
            if SearchRequestAuthority.accepts(
                capturedKey: keyA,
                currentKey: "\(model.activeBrowseSessionKey):query",
                isCancelled: Task.isCancelled
            ) {
                await display.publish(snapshot.hubs.flatMap(\.metadata).map(\.ratingKey))
            }
        }

        await transport.waitForARequestCount(2)
        model.serverToken = "token-B"
        let sessionB = try #require(model.backendSession(for: .plex))
        let serviceB = try PlexBrowseService(session: sessionB, identity: model.identity,
                                             send: { try await transport.send($0) })
        let keyB = "\(model.activeBrowseSessionKey):query"
        let current = try await serviceB.searchWithLibraries(query: "query")
        #expect(SearchRequestAuthority.accepts(capturedKey: keyB,
                                               currentKey: "\(model.activeBrowseSessionKey):query",
                                               isCancelled: false))
        await display.publish(current.hubs.flatMap(\.metadata).map(\.ratingKey))

        await transport.releaseA()
        try await staleTask.value

        #expect(await transport.aRequestTokens == ["token-A", "token-A"])
        #expect(!SearchRequestAuthority.accepts(capturedKey: keyA,
                                                currentKey: "\(model.activeBrowseSessionKey):query",
                                                isCancelled: false))
        #expect(await display.items == ["result-B"])
    }

    @Test func plexSearchOrchestrationKeepsHubsWhenCatalogFails() async throws {
        var searchCalls = 0
        var catalogCalls = 0
        let results = try await PlexSearchOrchestration.results(
            search: {
                searchCalls += 1
                return [Hub(title: "Native", metadata: [Self.searchItem(
                    id: "movie", type: "movie", section: "2")])]
            },
            catalog: {
                catalogCalls += 1
                throw PlexBrowseTestFailure.unexpectedRequest
            }
        )

        #expect(searchCalls == 1)
        #expect(catalogCalls == 1)
        #expect(results.presentationGroups.map(\.libraryID) == ["2"])
        #expect(results.presentationGroups.map(\.title) == ["Library 2"])
    }

    @Test func plexSearchOrchestrationUsesOneNativeOrderCatalogAndKeepsSearchFailureFatal() async throws {
        var catalogCalls = 0
        let hubs = [Hub(title: "Native", metadata: [
            Self.searchItem(id: "video", type: "movie", section: "2"),
            Self.searchItem(id: "music", type: "artist", section: "5"),
        ])]
        let descriptors = [
            LibraryCatalogDescriptor(
                plex: PlexSection(key: "5", title: "Music", type: "artist")),
            LibraryCatalogDescriptor(
                plex: PlexSection(key: "2", title: "Video", type: "movie")),
        ]
        let ordered = try await PlexSearchOrchestration.results(
            search: { hubs },
            catalog: {
                catalogCalls += 1
                return descriptors
            }
        )
        #expect(catalogCalls == 1)
        #expect(ordered.presentationGroups.map(\.libraryID) == ["5", "2"])
        #expect(ordered.presentationGroups.map(\.title) == ["Music", "Video"])

        await #expect(throws: PlexBrowseTestFailure.self) {
            _ = try await PlexSearchOrchestration.results(
                search: { throw PlexBrowseTestFailure.unexpectedRequest },
                catalog: { descriptors }
            )
        }
    }

    nonisolated private static func identity() -> ClientIdentity {
        ClientIdentity(clientIdentifier: "device", product: "Labstream", version: "1", deviceName: "Mac")
    }

    nonisolated private static func metadataJSON(ids: [String], type: String = "movie") -> Data {
        let rows = ids.map { "{\"ratingKey\":\"\($0)\",\"title\":\"\($0)\",\"type\":\"\(type)\"}" }
            .joined(separator: ",")
        return Data("{\"MediaContainer\":{\"size\":\(ids.count),\"Metadata\":[\(rows)]}}".utf8)
    }

    nonisolated private static func hubsJSON(ids: [String]) -> Data {
        let rows = ids.map { "{\"ratingKey\":\"\($0)\",\"title\":\"\($0)\",\"type\":\"movie\"}" }
            .joined(separator: ",")
        return Data("{\"MediaContainer\":{\"Hub\":[{\"title\":\"Hub\",\"Metadata\":[\(rows)]}]}}".utf8)
    }

    nonisolated private static func mediaItem(id: String, type: String) -> MediaItem {
        try! JSONDecoder().decode(
            MediaItem.self,
            from: Data("{\"ratingKey\":\"\(id)\",\"title\":\"\(id)\",\"type\":\"\(type)\"}".utf8)
        )
    }

    nonisolated private static func searchItem(id: String,
                                               type: String,
                                               section: String) -> MediaItem {
        try! JSONDecoder().decode(
            MediaItem.self,
            from: Data("{\"ratingKey\":\"\(id)\",\"title\":\"\(id)\",\"type\":\"\(type)\",\"librarySectionKey\":\"\(section)\"}".utf8)
        )
    }
}

private enum PlexBrowseTestFailure: Error {
    case unexpectedRequest
}

private actor PlexBrowseTransport {
    private(set) var requests: [URLRequest] = []
    private let response: @Sendable (URLRequest) throws -> Data

    init(response: @escaping @Sendable (URLRequest) throws -> Data) {
        self.response = response
    }

    func send(_ request: PlexRequest) throws -> Data {
        let built = request.urlRequest()
        requests.append(built)
        return try response(built)
    }
}

private actor DelayedPlexSearchTransport {
    private(set) var aRequestTokens: [String] = []
    private var heldAContinuation: CheckedContinuation<Data, Never>?

    func send(_ request: PlexRequest) async throws -> Data {
        let built = request.urlRequest()
        let token = built.value(forHTTPHeaderField: "X-Plex-Token") ?? ""
        if token == "token-A" { aRequestTokens.append(token) }

        if token == "token-A", built.url?.path.hasSuffix("/hubs/search") == true {
            return await withCheckedContinuation { heldAContinuation = $0 }
        }
        if built.url?.path.hasSuffix("/hubs/search") == true {
            return Self.hubsJSON(id: "result-B")
        }
        if built.url?.path.hasSuffix("/library/sections") == true {
            return Data(#"{"MediaContainer":{"Directory":[{"key":"1","title":"Movies","type":"movie"}]}}"#.utf8)
        }
        throw PlexBrowseTestFailure.unexpectedRequest
    }

    func waitForARequestCount(_ expected: Int) async {
        while aRequestTokens.count < expected { await Task.yield() }
    }

    func releaseA() {
        heldAContinuation?.resume(returning: Self.hubsJSON(id: "result-A"))
        heldAContinuation = nil
    }

    nonisolated private static func hubsJSON(id: String) -> Data {
        Data("{\"MediaContainer\":{\"Hub\":[{\"title\":\"Hub\",\"Metadata\":[{\"ratingKey\":\"\(id)\",\"title\":\"\(id)\",\"type\":\"movie\"}]}]}}".utf8)
    }
}

private actor CancellationIgnoringPlexTransport {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<Data, Never>?

    func send() async -> Data {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { responseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(_ data: Data) {
        responseContinuation?.resume(returning: data)
        responseContinuation = nil
    }
}

private struct SelfCancellingDecodePayload: Decodable, Sendable {
    let value: String

    private enum CodingKeys: String, CodingKey { case value }

    init(from decoder: Decoder) throws {
        value = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value)
        withUnsafeCurrentTask { $0?.cancel() }
    }
}

private struct PlainDecodePayload: Decodable, Sendable {
    let value: String
}

private actor PlexSearchDisplayProbe {
    private(set) var items: [String] = []
    func publish(_ items: [String]) { self.items = items }
}
