import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

enum TestFixtures {
    static let plexServer = URL(string: "https://192.0.2.10:32400")!
    static let plexIdentity = ClientIdentity(clientIdentifier: "CID",
                                             product: "Labstream",
                                             version: "0.1.0",
                                             deviceName: "AVP")

    static let jellyfinServer = URL(string: "https://jellyfin.example.test/base")!
    static let jellyfinImageServer = URL(string: "https://jf.example.test/jellyfin")!
    static let jellyfinIdentity = JellyfinClientIdentity(client: "Labstream",
                                                         device: "Apple Vision Pro",
                                                         deviceId: "device-123",
                                                         version: "0.1.0")

    static let embyServer = URL(string: "https://emby.example.test/emby")!
    static let embyIdentity = EmbyClientIdentity(client: "Labstream",
                                                 device: "Apple Vision Pro",
                                                 deviceId: "device-123",
                                                 version: "0.1.0")
}

func queryMap(_ request: URLRequest) throws -> [String: String] {
    let url = try #require(request.url)
    return try queryMap(url)
}

func queryMap(_ url: URL) throws -> [String: String] {
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

func queryValue(_ items: [URLQueryItem], _ name: String) -> String? {
    items.first { $0.name == name }?.value
}

func queryValue(_ request: PlexRequest, _ name: String) -> String? {
    queryValue(request.queryItems, name)
}

func queryValue(_ request: URLRequest, _ name: String) throws -> String? {
    try queryMap(request)[name]
}

func assertHeaderTokenNotInURL(_ request: URLRequest,
                               header: String,
                               token: String,
                               sourceLocation: SourceLocation = #_sourceLocation) throws {
    let url = try #require(request.url, sourceLocation: sourceLocation)
    #expect(request.value(forHTTPHeaderField: header) == token, sourceLocation: sourceLocation)
    #expect(!url.absoluteString.contains(token), sourceLocation: sourceLocation)
}

func assertAuthHeaderContainsTokenNotInURL(_ request: URLRequest,
                                           token: String,
                                           sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
    let url = try #require(request.url, sourceLocation: sourceLocation)
    let auth = try #require(request.value(forHTTPHeaderField: "Authorization"), sourceLocation: sourceLocation)
    #expect(auth.contains(token), sourceLocation: sourceLocation)
    #expect(!url.absoluteString.contains(token), sourceLocation: sourceLocation)
    return auth
}
