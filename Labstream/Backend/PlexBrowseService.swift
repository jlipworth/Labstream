import Foundation
import PMSKit

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
