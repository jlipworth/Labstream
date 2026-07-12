import Foundation
import PMSKit

struct PlexBrowsePage: Sendable {
    let items: [MediaItem]
    let total: Int?
}

/// App execution boundary for native Plex browse capabilities.
///
/// Pure request construction remains in PMSKit/`BrowseAPI`; this service owns one immutable Plex
/// session, execution, decoding, and response normalization. Auth flows, downloads, debug probes,
/// live probes, and playback stream negotiation deliberately remain outside this boundary.
@MainActor
struct PlexBrowseService {
    enum ServiceError: Error, LocalizedError, Equatable {
        case missingSession
        case wrongBackend
        case noMetadataItem

        var errorDescription: String? {
            switch self {
            case .missingSession: return "No Plex server selected."
            case .wrongBackend: return "The browse session is not a Plex session."
            case .noMetadataItem: return "Plex did not return metadata for this item."
            }
        }
    }

    typealias Send = @MainActor @Sendable (PlexRequest) async throws -> Data

    let session: BackendSession
    let identity: ClientIdentity
    private let send: Send
    private let decoder = JSONDecoder()

    init(appModel: AppModel) throws {
        guard let session = appModel.backendSession(for: .plex) else {
            throw ServiceError.missingSession
        }
        try self.init(session: session, identity: appModel.identity) { request in
            try await appModel.client.send(request)
        }
    }

    init(session: BackendSession,
         identity: ClientIdentity,
         send: @escaping Send) throws {
        guard session.kind == .plex else { throw ServiceError.wrongBackend }
        self.session = session
        self.identity = identity
        self.send = send
    }

    func metadata(ratingKey: String) async throws -> MediaItem {
        let request = BrowseAPI.metadata(server: session.baseURL,
                                         token: session.token,
                                         identity: identity,
                                         ratingKey: ratingKey)
        let response: MetadataResponse = try await execute(request)
        guard let item = response.mediaContainer.metadata.first else {
            throw ServiceError.noMetadataItem
        }
        return item
    }

    func children(ratingKey: String) async throws -> [MediaItem] {
        let request = BrowseAPI.children(server: session.baseURL,
                                         token: session.token,
                                         identity: identity,
                                         ratingKey: ratingKey)
        let response: MetadataResponse = try await execute(request)
        return response.mediaContainer.metadata
    }

    func libraries() async throws -> [PlexSection] {
        let request = BrowseAPI.sections(server: session.baseURL,
                                         token: session.token,
                                         identity: identity)
        let response: SectionsResponse = try await execute(request)
        return response.mediaContainer.directory
    }

    func sectionPage(sectionKey: String,
                     startIndex: Int? = nil,
                     limit: Int? = nil,
                     sort: String? = nil,
                     firstCharacter: String? = nil) async throws -> PlexBrowsePage {
        let request = BrowseAPI.sectionItems(server: session.baseURL,
                                             token: session.token,
                                             identity: identity,
                                             sectionKey: sectionKey,
                                             containerStart: startIndex,
                                             containerSize: limit,
                                             sort: sort,
                                             firstCharacter: firstCharacter)
        let response: MetadataResponse = try await execute(request)
        return PlexBrowsePage(items: response.mediaContainer.metadata,
                              total: response.mediaContainer.totalSize)
    }

    func alphabetCounts(sectionKey: String,
                        type: Int? = nil) async throws -> [(display: String, count: Int)] {
        let request = BrowseAPI.firstCharacters(server: session.baseURL,
                                                token: session.token,
                                                identity: identity,
                                                sectionKey: sectionKey,
                                                type: type)
        let response: PlexFirstCharacterResponse = try await execute(request)
        return response.libraryCounts()
    }

    func setPlayed(ratingKey: String, played: Bool) async throws {
        let request = played
            ? TimelineRequest.scrobble(server: session.baseURL,
                                       token: session.token,
                                       identity: identity,
                                       ratingKey: ratingKey)
            : TimelineRequest.unscrobble(server: session.baseURL,
                                         token: session.token,
                                         identity: identity,
                                         ratingKey: ratingKey)
        _ = try await send(request)
    }

    private func execute<Value: Decodable>(_ request: PlexRequest) async throws -> Value {
        let data = try await send(request)
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw PlexError.decoding(error)
        }
    }
}

private struct PlexFirstCharacterResponse: Decodable {
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    struct Container: Decodable {
        let directory: [Entry]
        enum CodingKeys: String, CodingKey { case directory = "Directory" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            directory = try container.decodeIfPresent([Entry].self, forKey: .directory) ?? []
        }
    }

    struct Entry: Decodable {
        let key: String?
        let title: String?
        let count: Int

        enum CodingKeys: String, CodingKey { case key, title, size, count }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decodeIfPresent(String.self, forKey: .key)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            count = (try? container.decodePlexLossyIntIfPresent(forKey: .size))
                ?? (try? container.decodePlexLossyIntIfPresent(forKey: .count))
                ?? 0
        }
    }

    func libraryCounts() -> [(display: String, count: Int)] {
        mediaContainer.directory.map {
            (display: $0.title ?? $0.key ?? "", count: $0.count)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodePlexLossyIntIfPresent(forKey key: Key) throws -> Int? {
        if let int = try decodeIfPresent(Int.self, forKey: key) { return int }
        if let string = try decodeIfPresent(String.self, forKey: key) { return Int(string) }
        return nil
    }
}
