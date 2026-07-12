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
        try self.init(session: session, identity: appModel.identity, client: appModel.client)
    }

    init(session: BackendSession,
         identity: ClientIdentity,
         client: PlexClient) throws {
        try self.init(session: session, identity: identity) { request in
            try await client.send(request)
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
        guard let item = try await metadataItems(ratingKeys: ratingKey).first else {
            throw ServiceError.noMetadataItem
        }
        return item
    }

    func metadataItems(ratingKeys: String) async throws -> [MediaItem] {
        let request = BrowseAPI.metadata(server: session.baseURL,
                                         token: session.token,
                                         identity: identity,
                                         ratingKey: ratingKeys)
        let response: MetadataResponse = try await execute(request)
        return response.mediaContainer.metadata
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

    func hubs() async throws -> [Hub] {
        let request = BrowseAPI.hubs(server: session.baseURL,
                                     token: session.token,
                                     identity: identity)
        let response: HubsResponse = try await execute(request)
        return response.mediaContainer.hub
    }

    func search(query: String) async throws -> [Hub] {
        let request = BrowseAPI.search(server: session.baseURL,
                                       token: session.token,
                                       identity: identity,
                                       query: query)
        let response: HubsResponse = try await execute(request)
        return response.mediaContainer.hub
    }

    func onDeck() async throws -> [MediaItem] {
        let request = BrowseAPI.onDeck(server: session.baseURL,
                                       token: session.token,
                                       identity: identity)
        let response: MetadataResponse = try await execute(request)
        return response.mediaContainer.metadata
    }

    func musicArtists(libraryID: String, sort: String, start: Int, size: Int) async throws -> MusicPage {
        let request = MusicRequest.artists(server: session.baseURL, token: session.token,
                                           identity: identity, sectionKey: libraryID, sort: sort,
                                           containerStart: start, containerSize: size)
        return try await musicPage(request)
    }

    func musicAlbums(libraryID: String, sort: String, start: Int, size: Int) async throws -> MusicPage {
        let request = MusicRequest.albums(server: session.baseURL, token: session.token,
                                          identity: identity, sectionKey: libraryID, sort: sort,
                                          containerStart: start, containerSize: size)
        return try await musicPage(request)
    }

    func discographyTracks(artistRatingKey: String) async throws -> [MediaItem] {
        let request = MusicRequest.allLeaves(server: session.baseURL, token: session.token,
                                             identity: identity, ratingKey: artistRatingKey)
        let response: MetadataResponse = try await execute(request)
        return response.mediaContainer.metadata.filter { $0.kind == .track }
    }

    func musicPlaylists() async throws -> [MediaItem] {
        let request = PlaylistRequest.audioPlaylists(server: session.baseURL,
                                                     token: session.token,
                                                     identity: identity)
        let response: MetadataResponse = try await execute(request)
        return response.mediaContainer.metadata.filter { $0.kind == .playlist }
    }

    func playlistTracks(ratingKey: String) async throws -> [MediaItem] {
        let request = PlaylistRequest.items(server: session.baseURL, token: session.token,
                                            identity: identity, ratingKey: ratingKey)
        let response: MetadataResponse = try await execute(request)
        // Playlist order and duplicate rows are native server semantics; never sort or dedupe.
        return response.mediaContainer.metadata.filter { $0.kind == .track }
    }

    func artistDetail(artist: MediaItem, libraryID: String?) async throws -> ArtistDetailContent {
        guard let libraryID else {
            let albums = try await children(ratingKey: artist.ratingKey)
            return ArtistDetailContent(albums: albums.filter { $0.kind == .album })
        }

        async let related: HubsResponse? = try? execute(
            MusicRequest.relatedHubs(server: session.baseURL, token: session.token,
                                     identity: identity, ratingKey: artist.ratingKey))
        async let appears: MetadataResponse? = try? execute(
            MusicRequest.appearsOnAlbums(server: session.baseURL, token: session.token,
                                         identity: identity, sectionKey: libraryID,
                                         artistTitle: artist.title))
        async let popular: MetadataResponse? = try? execute(
            MusicRequest.popularTracks(server: session.baseURL, token: session.token,
                                       identity: identity, sectionKey: libraryID,
                                       artistRatingKey: artist.ratingKey))

        let ownRequest = MusicRequest.artistAlbums(server: session.baseURL, token: session.token,
                                                   identity: identity, sectionKey: libraryID,
                                                   artistRatingKey: artist.ratingKey)
        let ownResponse: MetadataResponse = try await execute(ownRequest)
        let own = ownResponse.mediaContainer.metadata

        let hubs = (await related)?.mediaContainer.hub ?? []
        let categorized: [ArtistShelf] = hubs.compactMap { hub in
            guard (hub.hubIdentifier ?? "").hasPrefix("artist.albums.") else { return nil }
            let items = hub.metadata.filter { $0.kind == .album }
            guard !items.isEmpty else { return nil }
            return ArtistShelf(id: hub.hubIdentifier ?? hub.title, title: hub.title, items: items)
        }
        let similar = hubs.first { ($0.hubIdentifier ?? "").hasPrefix("artist.similar") }?
            .metadata.filter { $0.kind == .artist } ?? []
        let categorizedKeys = Set(categorized.flatMap(\.items).map(\.ratingKey))
        let albums = own.filter { !categorizedKeys.contains($0.ratingKey) }
        let ownKeys = Set(own.map(\.ratingKey))
        let appearsOn = ((await appears)?.mediaContainer.metadata ?? [])
            .filter { $0.kind == .album && !ownKeys.contains($0.ratingKey) }
        let popularTracks = (await popular)?.mediaContainer.metadata.filter { $0.kind == .track } ?? []
        return ArtistDetailContent(albums: albums, popular: popularTracks,
                                   categorized: categorized, appearsOn: appearsOn, similar: similar)
    }

    func musicSectionHubs(sectionKey: String) async throws -> [Hub] {
        let request = MusicRequest.sectionHubs(server: session.baseURL, token: session.token,
                                               identity: identity, sectionKey: sectionKey)
        let response: HubsResponse = try await execute(request)
        return response.mediaContainer.hub
    }

    func playHistory(librarySectionID: String, count: Int) async throws -> [MediaItem] {
        let request = MusicRequest.playHistory(server: session.baseURL, token: session.token,
                                               identity: identity,
                                               librarySectionID: librarySectionID,
                                               count: count)
        let response: MetadataResponse = try await execute(request)
        return response.mediaContainer.metadata
    }

    func recentlyAddedAlbums(sectionKey: String) async throws -> [MediaItem] {
        let request = MusicRequest.recentlyAddedAlbums(server: session.baseURL,
                                                       token: session.token,
                                                       identity: identity,
                                                       sectionKey: sectionKey)
        let response: MetadataResponse = try await execute(request)
        return response.mediaContainer.metadata
    }

    func randomTracks(sectionKey: String) async throws -> [MediaItem] {
        let request = MusicRequest.randomTracks(server: session.baseURL, token: session.token,
                                                identity: identity, sectionKey: sectionKey)
        let response: MetadataResponse = try await execute(request)
        return response.mediaContainer.metadata.filter { $0.kind == .track }
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

    private func musicPage(_ request: PlexRequest) async throws -> MusicPage {
        let response: MetadataResponse = try await execute(request)
        let items = response.mediaContainer.metadata
        return MusicPage(items: items,
                         total: max(response.mediaContainer.totalSize ?? items.count, items.count))
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
