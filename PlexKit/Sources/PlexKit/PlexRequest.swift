import Foundation

public struct PlexRequest: Sendable, Equatable {
    public let url: URL
    public let method: String
    public var queryItems: [URLQueryItem] = []
    public var headers: [String: String] = [:]
    public var body: Data? = nil
    public init(url: URL, method: String, queryItems: [URLQueryItem] = [],
                headers: [String: String] = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.queryItems = queryItems
        self.headers = headers; self.body = body
    }
}
