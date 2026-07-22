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
                return Self.metadataJSON(ids: ["track-2", "track-1", "track-2"], type: "track")
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
        #expect(try await service.playlistTracks(ratingKey: "playlist").map(\.ratingKey)
                == ["track-2", "track-1", "track-2"])
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

private actor PlexSearchDisplayProbe {
    private(set) var items: [String] = []
    func publish(_ items: [String]) { self.items = items }
}
