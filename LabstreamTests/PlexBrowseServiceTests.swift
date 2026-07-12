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

    nonisolated private static func identity() -> ClientIdentity {
        ClientIdentity(clientIdentifier: "device", product: "Labstream", version: "1", deviceName: "Mac")
    }

    nonisolated private static func metadataJSON(ids: [String]) -> Data {
        let rows = ids.map { "{\"ratingKey\":\"\($0)\",\"title\":\"\($0)\",\"type\":\"movie\"}" }
            .joined(separator: ",")
        return Data("{\"MediaContainer\":{\"size\":\(ids.count),\"Metadata\":[\(rows)]}}".utf8)
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
