import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Shared low-level helpers for the Emby/Jellyfin (forked-API) backends. These return
// optionals rather than throwing so each backend keeps its own error type at the call
// site (EmbyServerURLError/JellyfinServerURLError, EmbyPlaybackError/JellyfinPlaybackError),
// which existing tests assert on.

public enum MediaBrowserURL {
    /// Validate and normalize a user-entered server address. Returns nil if the input is
    /// empty or does not resolve to an http/https URL with a host.
    ///
    /// The user-entered base path (for example Emby's `/emby`) is PRESERVED verbatim:
    /// relative stream URLs returned by PlaybackInfo are joined onto `server.path`, so the
    /// normalizer must not strip it. Default ports are a caller/UX concern.
    public static func normalizedServerURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    /// Join a server-relative path (or same-origin absolute URL) onto the server base
    /// URL, PRESERVING the server's base path (for example `/emby`). Returns nil if a URL
    /// cannot be constructed or if an absolute URL is not same-origin with `server`.
    public static func join(server: URL, pathOrURLString: String) -> URL? {
        joinTrustedServerURL(server: server, pathOrURLString: pathOrURLString)
    }

    /// Join a backend-provided media URL that will be fetched with MediaBrowser credentials.
    ///
    /// Relative paths are resolved against the configured server while preserving its base path.
    /// Absolute URLs are accepted only when they match the server's effective origin: same
    /// http(s) scheme, case-insensitive host, and effective port (implicit 443/80 default ports
    /// are treated the same as explicit ones).
    public static func joinTrustedServerURL(server: URL, pathOrURLString: String) -> URL? {
        if let absolute = URL(string: pathOrURLString), absolute.scheme != nil {
            return isSameOrigin(absolute, server: server) ? absolute : nil
        }
        return joinRelative(server: server, pathOrURLString: pathOrURLString)
    }

    public static func isSameOrigin(_ url: URL, server: URL) -> Bool {
        guard let lhs = origin(for: url),
              let rhs = origin(for: server) else {
            return false
        }
        return lhs.scheme == rhs.scheme &&
            lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame &&
            lhs.port == rhs.port
    }

    private static func joinRelative(server: URL, pathOrURLString: String) -> URL? {
        guard var comps = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath: String
        let query: String?
        if let qIndex = pathOrURLString.firstIndex(of: "?") {
            relativePath = String(pathOrURLString[..<qIndex])
            query = String(pathOrURLString[pathOrURLString.index(after: qIndex)...])
        } else {
            relativePath = pathOrURLString
            query = nil
        }
        let cleanRelative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comps.percentEncodedPath = "/" + [basePath, cleanRelative].filter { !$0.isEmpty }.joined(separator: "/")
        comps.percentEncodedQuery = query
        return comps.url
    }

    private static func origin(for url: URL) -> (scheme: String, host: String, port: Int)? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host,
              !host.isEmpty,
              let port = effectivePort(for: scheme, explicitPort: comps.port) else {
            return nil
        }
        return (scheme, host, port)
    }

    private static func effectivePort(for scheme: String, explicitPort: Int?) -> Int? {
        if let explicitPort { return explicitPort }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

public enum MediaBrowserAuth {
    /// Escape a value for embedding in a quoted authorization-header parameter.
    public static func quote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Build a MediaBrowser-family authorization header from ordered, already semantic
    /// parameters. Empty/nil values are omitted so callers keep the Jellyfin/Emby token
    /// and user-id dialect differences explicit while sharing the fragile quoting rules.
    public static func headerValue(scheme: String, parameters: [(name: String, value: String?)]) -> String {
        let encoded = parameters.compactMap { parameter -> String? in
            guard let value = parameter.value, !value.isEmpty else { return nil }
            return "\(parameter.name)=\"\(quote(value))\""
        }
        return scheme + " " + encoded.joined(separator: ", ")
    }
}

public enum MediaBrowserLibraryFields {
    /// Parent/series image tags drive episode/season artwork fallback (#86). People,
    /// Studios, and CriticRating drive cast/critic metadata (#76). Keep these canonical
    /// field strings shared so Jellyfin and Emby browse requests cannot drift silently.
    public static let gridItem = "Overview,PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating,ProviderIds,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesPrimaryImageTag"
    public static let fullItem = "Overview,Genres,MediaSources,People,Studios,ProviderIds,ParentId,PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating,CriticRating,Taglines,Chapters,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesPrimaryImageTag"
}

public enum MediaBrowserLibraryQueryName: Sendable {
    case userId
    case includeExternalContent
    case parentId
    case recursive
    case startIndex
    case limit
    case searchTerm
    case nameStartsWith
    case albumArtistIds
    case artistIds
    case includeItemTypes
    case filters
    case sortBy
    case sortOrder
    case fields
    case enableUserData
    case enableImages
    case excludeActiveSessions
    case enableResumable
    case groupItems
}

public enum MediaBrowserLibraryPath: Sendable, Equatable {
    case userViews(userId: String)
    case items(userId: String)
}

public enum MediaBrowserLibraryQueryDialect: Sendable, Equatable {
    case jellyfin
    case emby

    public func path(_ path: MediaBrowserLibraryPath) -> String {
        switch (self, path) {
        case (.jellyfin, .userViews):
            return "/UserViews"
        case (.jellyfin, .items):
            return "/Items"
        case (.emby, .userViews(let userId)):
            return "/Users/\(userId)/Views"
        case (.emby, .items(let userId)):
            return "/Users/\(userId)/Items"
        }
    }

    public func queryName(_ name: MediaBrowserLibraryQueryName) -> String {
        switch self {
        case .jellyfin:
            switch name {
            case .userId: return "userId"
            case .includeExternalContent: return "includeExternalContent"
            case .parentId: return "parentId"
            case .recursive: return "recursive"
            case .startIndex: return "startIndex"
            case .limit: return "limit"
            case .searchTerm: return "searchTerm"
            case .nameStartsWith: return "nameStartsWith"
            case .albumArtistIds: return "albumArtistIds"
            case .artistIds: return "artistIds"
            case .includeItemTypes: return "includeItemTypes"
            case .filters: return "filters"
            case .sortBy: return "sortBy"
            case .sortOrder: return "sortOrder"
            case .fields: return "fields"
            case .enableUserData: return "enableUserData"
            case .enableImages: return "enableImages"
            case .excludeActiveSessions: return "excludeActiveSessions"
            case .enableResumable: return "enableResumable"
            case .groupItems: return "groupItems"
            }
        case .emby:
            switch name {
            case .userId: return "UserId"
            case .includeExternalContent: return "IncludeExternalContent"
            case .parentId: return "ParentId"
            case .recursive: return "Recursive"
            case .startIndex: return "StartIndex"
            case .limit: return "Limit"
            case .searchTerm: return "SearchTerm"
            case .nameStartsWith: return "NameStartsWith"
            case .albumArtistIds: return "AlbumArtistIds"
            case .artistIds: return "ArtistIds"
            case .includeItemTypes: return "IncludeItemTypes"
            case .filters: return "Filters"
            case .sortBy: return "SortBy"
            case .sortOrder: return "SortOrder"
            case .fields: return "Fields"
            case .enableUserData: return "EnableUserData"
            case .enableImages: return "EnableImages"
            case .excludeActiveSessions: return "ExcludeActiveSessions"
            case .enableResumable: return "EnableResumable"
            case .groupItems: return "GroupItems"
            }
        }
    }

    public func queryItem(_ name: MediaBrowserLibraryQueryName, value: String) -> URLQueryItem {
        URLQueryItem(name: queryName(name), value: value)
    }
}

public struct MediaBrowserRequest: Sendable {
    public let urlRequest: URLRequest

    public init(_ urlRequest: URLRequest) {
        self.urlRequest = urlRequest
    }
}

public enum MediaBrowserRequestError: Error, Equatable, LocalizedError {
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status): return "MediaBrowser server error (HTTP \(status))."
        }
    }
}

public struct MediaBrowserRequestExecutor: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    public init(transport: @escaping Transport) {
        self.transport = transport
    }

    public init(session: URLSession = .shared) {
        self.init { request in
            try await session.data(for: request)
        }
    }

    @discardableResult
    public func send(_ request: MediaBrowserRequest) async throws -> Data {
        try await send(request.urlRequest)
    }

    @discardableResult
    public func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MediaBrowserRequestError.httpStatus(http.statusCode)
        }
        return data
    }

    public func send<T: Decodable>(_ request: MediaBrowserRequest,
                                   as type: T.Type,
                                   decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        try await send(request.urlRequest, as: type, decoder: decoder)
    }

    public func send<T: Decodable>(_ request: URLRequest,
                                   as type: T.Type,
                                   decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let data = try await send(request)
        return try Self.decode(data, as: type, decoder: decoder)
    }

    public static func decode<T: Decodable>(_ data: Data,
                                            as type: T.Type,
                                            decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: data)
    }
}
