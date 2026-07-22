import Foundation
import PMSKit

struct PlexBrowsePage: Sendable {
    let items: [MediaItem]
    let total: Int?
}

struct PlexSearchSnapshot: Sendable {
    let hubs: [Hub]
    let libraries: [PlexSection]
}

/// Immutable authentication and request-identity values captured when a Plex browse service is
/// created. Mutable `AppModel` state must never cross the browse execution boundary.
struct PlexBrowseExecutionSnapshot: Sendable {
    let session: BackendSession
    let identity: ClientIdentity
}

/// Nonisolated execution/decode/map seam for Plex browse responses.
///
/// `PlexBrowseService` remains a MainActor facade because its callers resolve mutable app state
/// there. Once the facade has captured `snapshot`, this Sendable executor builds requests from that
/// immutable state and performs response decoding and normalization on Swift's generic executor.
/// The injected witness is test-only observability: production leaves it nil.
struct PlexBrowseResponseExecutor: Sendable {
    enum Stage: Sendable, Equatable {
        case decode
        case transform
    }

    // Preserve the facade's pre-refactor transport isolation exactly. Only immutable request
    // construction plus response decode/map cross the boundary in this slice.
    typealias Send = @MainActor @Sendable (PlexRequest) async throws -> Data
    typealias Witness = @Sendable (Stage) -> Void

    let snapshot: PlexBrowseExecutionSnapshot
    private let send: Send
    private let witness: Witness?

    init(snapshot: PlexBrowseExecutionSnapshot,
         send: @escaping Send,
         witness: Witness? = nil) {
        self.snapshot = snapshot
        self.send = send
        self.witness = witness
    }

    @discardableResult
    func execute(_ build: @Sendable (PlexBrowseExecutionSnapshot) -> PlexRequest) async throws -> Data {
        try await send(build(snapshot))
    }

    func execute<Value: Decodable & Sendable, Output: Sendable>(
        _ build: @Sendable (PlexBrowseExecutionSnapshot) -> PlexRequest,
        as type: Value.Type,
        transform: @escaping @Sendable (Value) throws -> Output
    ) async throws -> Output {
        let data = try await send(build(snapshot))
        // A transport can legally return buffered bytes after its waiter was cancelled. Do not
        // spend CPU decoding them or let a cancelled browse publish a successful value.
        try Task.checkCancellation()
        let value: Value
        do {
            witness?(.decode)
            value = try JSONDecoder().decode(type, from: data)
        } catch {
            throw PlexError.decoding(error)
        }
        // Decoding is synchronous, so cancellation may arrive while a large payload is being
        // decoded. Fence the production normalization step independently.
        try Task.checkCancellation()
        witness?(.transform)
        let output = try transform(value)
        try Task.checkCancellation()
        return output
    }

    func transform<Input: Sendable, Output: Sendable>(
        _ input: Input,
        using operation: @escaping @Sendable (Input) -> Output
    ) async throws -> Output {
        try Task.checkCancellation()
        witness?(.transform)
        let output = operation(input)
        try Task.checkCancellation()
        return output
    }
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

    typealias Send = PlexBrowseResponseExecutor.Send

    let executionSnapshot: PlexBrowseExecutionSnapshot
    private let executor: PlexBrowseResponseExecutor

    var session: BackendSession { executionSnapshot.session }
    var identity: ClientIdentity { executionSnapshot.identity }

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
         send: @escaping Send,
         executionWitness: PlexBrowseResponseExecutor.Witness? = nil) throws {
        guard session.kind == .plex else { throw ServiceError.wrongBackend }
        let snapshot = PlexBrowseExecutionSnapshot(session: session, identity: identity)
        self.executionSnapshot = snapshot
        self.executor = PlexBrowseResponseExecutor(snapshot: snapshot,
                                                   send: send,
                                                   witness: executionWitness)
    }

    func metadata(ratingKey: String) async throws -> MediaItem {
        guard let item = try await metadataItems(ratingKeys: ratingKey).first else {
            throw ServiceError.noMetadataItem
        }
        return item
    }

    func metadataItems(ratingKeys: String) async throws -> [MediaItem] {
        try await executor.execute({ snapshot in
            BrowseAPI.metadata(server: snapshot.session.baseURL,
                               token: snapshot.session.token,
                               identity: snapshot.identity,
                               ratingKey: ratingKeys)
        }, as: MetadataResponse.self) { response in
            response.mediaContainer.metadata
        }
    }

    func children(ratingKey: String) async throws -> [MediaItem] {
        try await executor.execute({ snapshot in
            BrowseAPI.children(server: snapshot.session.baseURL,
                               token: snapshot.session.token,
                               identity: snapshot.identity,
                               ratingKey: ratingKey)
        }, as: MetadataResponse.self) { response in
            response.mediaContainer.metadata
        }
    }

    func libraries() async throws -> [PlexSection] {
        try await executor.execute({ snapshot in
            BrowseAPI.sections(server: snapshot.session.baseURL,
                               token: snapshot.session.token,
                               identity: snapshot.identity)
        }, as: SectionsResponse.self) { response in
            response.mediaContainer.directory
        }
    }

    func sectionPage(sectionKey: String,
                     startIndex: Int? = nil,
                     limit: Int? = nil,
                     sort: String? = nil,
                     firstCharacter: String? = nil,
                     browseQuery: LibraryBrowseQuery = .default) async throws -> PlexBrowsePage {
        try await executor.execute({ snapshot in
            BrowseAPI.sectionItems(server: snapshot.session.baseURL,
                                   token: snapshot.session.token,
                                   identity: snapshot.identity,
                                   sectionKey: sectionKey,
                                   containerStart: startIndex,
                                   containerSize: limit,
                                   sort: sort,
                                   firstCharacter: firstCharacter,
                                   browseQuery: browseQuery)
        }, as: MetadataResponse.self) { response in
            PlexBrowsePage(items: response.mediaContainer.metadata,
                           total: response.mediaContainer.totalSize)
        }
    }

    func alphabetCounts(sectionKey: String,
                        type: Int? = nil) async throws -> [(display: String, count: Int)] {
        try await executor.execute({ snapshot in
            BrowseAPI.firstCharacters(server: snapshot.session.baseURL,
                                      token: snapshot.session.token,
                                      identity: snapshot.identity,
                                      sectionKey: sectionKey,
                                      type: type)
        }, as: PlexFirstCharacterResponse.self) { response in
            response.libraryCounts()
        }
    }

    func hubs() async throws -> [Hub] {
        try await executor.execute({ snapshot in
            BrowseAPI.hubs(server: snapshot.session.baseURL,
                           token: snapshot.session.token,
                           identity: snapshot.identity)
        }, as: HubsResponse.self) { response in
            response.mediaContainer.hub
        }
    }

    func search(query: String) async throws -> [Hub] {
        try await executor.execute({ snapshot in
            BrowseAPI.search(server: snapshot.session.baseURL,
                             token: snapshot.session.token,
                             identity: snapshot.identity,
                             query: query)
        }, as: HubsResponse.self) { response in
            response.mediaContainer.hub
        }
    }

    /// Search hits are primary while section titles are best-effort, matching the prior UI
    /// behavior. Both requests are pinned to this service's immutable session and identity.
    func searchWithLibraries(query: String) async throws -> PlexSearchSnapshot {
        async let hubs = search(query: query)
        async let libraries = try? libraries()
        return try await PlexSearchSnapshot(hubs: hubs, libraries: libraries ?? [])
    }

    func onDeck() async throws -> [MediaItem] {
        try await executor.execute({ snapshot in
            BrowseAPI.onDeck(server: snapshot.session.baseURL,
                             token: snapshot.session.token,
                             identity: snapshot.identity)
        }, as: MetadataResponse.self) { response in
            response.mediaContainer.metadata
        }
    }

    /// Pages a server-provided native Home rail path without moving execution back into UI/paging.
    /// The path and query shape intentionally match the former `RailPagingSource` request exactly.
    func homeRailPage(path: String, type: Int?, start: Int, limit: Int) async throws -> PlexBrowsePage {
        try await executor.execute({ snapshot in
            PlexRequest(
                url: snapshot.session.baseURL.appendingPathComponent(path),
                method: "GET",
                queryItems: [
                    .init(name: "X-Plex-Container-Start", value: String(start)),
                    .init(name: "X-Plex-Container-Size", value: String(limit)),
                ] + (type.map { [.init(name: "type", value: String($0))] } ?? []),
                headers: PlexHeaders.standard(identity: snapshot.identity,
                                              token: snapshot.session.token)
            )
        }, as: MetadataResponse.self) { response in
            PlexBrowsePage(items: response.mediaContainer.metadata,
                           total: response.mediaContainer.totalSize)
        }
    }

    func musicArtists(libraryID: String, sort: String, start: Int, size: Int) async throws -> MusicPage {
        try await musicPage { snapshot in
            MusicRequest.artists(server: snapshot.session.baseURL,
                                 token: snapshot.session.token,
                                 identity: snapshot.identity,
                                 sectionKey: libraryID, sort: sort,
                                 containerStart: start, containerSize: size)
        }
    }

    func musicAlbums(libraryID: String, sort: String, start: Int, size: Int) async throws -> MusicPage {
        try await musicPage { snapshot in
            MusicRequest.albums(server: snapshot.session.baseURL,
                                token: snapshot.session.token,
                                identity: snapshot.identity,
                                sectionKey: libraryID, sort: sort,
                                containerStart: start, containerSize: size)
        }
    }

    func discographyTracks(artistRatingKey: String) async throws -> [MediaItem] {
        try await executor.execute({ snapshot in
            MusicRequest.allLeaves(server: snapshot.session.baseURL,
                                   token: snapshot.session.token,
                                   identity: snapshot.identity,
                                   ratingKey: artistRatingKey)
        }, as: MetadataResponse.self) { response in
            response.mediaContainer.metadata.filter { $0.kind == .track }
        }
    }

    func musicPlaylists() async throws -> [MediaItem] {
        try await executor.execute({ snapshot in
            PlaylistRequest.audioPlaylists(server: snapshot.session.baseURL,
                                           token: snapshot.session.token,
                                           identity: snapshot.identity)
        }, as: MetadataResponse.self) { response in
            response.mediaContainer.metadata.filter { $0.kind == .playlist }
        }
    }

    func playlistTracks(ratingKey: String) async throws -> [MediaItem] {
        try await playlistTracksPage(ratingKey: ratingKey, start: nil, size: nil).items
    }

    func playlistTracksPage(ratingKey: String,
                            start: Int?,
                            size: Int?) async throws -> PlaylistPage {
        try await executor.execute({ snapshot in
            PlaylistRequest.items(server: snapshot.session.baseURL,
                                  token: snapshot.session.token,
                                  identity: snapshot.identity,
                                  ratingKey: ratingKey,
                                  containerStart: start,
                                  containerSize: size)
        }, as: MetadataResponse.self) { response in
            // Playlist order and duplicate rows are native server semantics; never sort or dedupe.
            PlaylistPage(items: response.mediaContainer.metadata.filter { $0.kind == .track },
                         reportedTotal: response.mediaContainer.totalSize)
        }
    }

    func artistDetail(artist: MediaItem, libraryID: String?) async throws -> ArtistDetailContent {
        guard let libraryID else {
            let albums = try await children(ratingKey: artist.ratingKey)
            return try await executor.transform(albums) { values in
                ArtistDetailContent(albums: values.filter { $0.kind == .album })
            }
        }

        async let related: [Hub]? = try? executor.execute({ snapshot in
            MusicRequest.relatedHubs(server: snapshot.session.baseURL,
                                     token: snapshot.session.token,
                                     identity: snapshot.identity,
                                     ratingKey: artist.ratingKey)
        }, as: HubsResponse.self) { $0.mediaContainer.hub }
        async let appears: [MediaItem]? = try? executor.execute({ snapshot in
            MusicRequest.appearsOnAlbums(server: snapshot.session.baseURL,
                                         token: snapshot.session.token,
                                         identity: snapshot.identity,
                                         sectionKey: libraryID,
                                         artistTitle: artist.title)
        }, as: MetadataResponse.self) { $0.mediaContainer.metadata }
        async let popular: [MediaItem]? = try? executor.execute({ snapshot in
            MusicRequest.popularTracks(server: snapshot.session.baseURL,
                                       token: snapshot.session.token,
                                       identity: snapshot.identity,
                                       sectionKey: libraryID,
                                       artistRatingKey: artist.ratingKey)
        }, as: MetadataResponse.self) { $0.mediaContainer.metadata }

        let own: [MediaItem] = try await executor.execute({ snapshot in
            MusicRequest.artistAlbums(server: snapshot.session.baseURL,
                                      token: snapshot.session.token,
                                      identity: snapshot.identity,
                                      sectionKey: libraryID,
                                      artistRatingKey: artist.ratingKey)
        }, as: MetadataResponse.self) { $0.mediaContainer.metadata }

        let input = PlexArtistDetailMappingInput(
            own: own,
            hubs: await related ?? [],
            appears: await appears ?? [],
            popular: await popular ?? []
        )
        return try await executor.transform(input) { $0.content() }
    }

    func musicSectionHubs(sectionKey: String) async throws -> [Hub] {
        try await executor.execute({ snapshot in
            MusicRequest.sectionHubs(server: snapshot.session.baseURL,
                                     token: snapshot.session.token,
                                     identity: snapshot.identity,
                                     sectionKey: sectionKey)
        }, as: HubsResponse.self) { $0.mediaContainer.hub }
    }

    func playHistory(librarySectionID: String, count: Int) async throws -> [MediaItem] {
        try await executor.execute({ snapshot in
            MusicRequest.playHistory(server: snapshot.session.baseURL,
                                     token: snapshot.session.token,
                                     identity: snapshot.identity,
                                     librarySectionID: librarySectionID,
                                     count: count)
        }, as: MetadataResponse.self) { $0.mediaContainer.metadata }
    }

    func recentlyAddedAlbums(sectionKey: String) async throws -> [MediaItem] {
        try await executor.execute({ snapshot in
            MusicRequest.recentlyAddedAlbums(server: snapshot.session.baseURL,
                                             token: snapshot.session.token,
                                             identity: snapshot.identity,
                                             sectionKey: sectionKey)
        }, as: MetadataResponse.self) { $0.mediaContainer.metadata }
    }

    func randomTracks(sectionKey: String) async throws -> [MediaItem] {
        try await executor.execute({ snapshot in
            MusicRequest.randomTracks(server: snapshot.session.baseURL,
                                      token: snapshot.session.token,
                                      identity: snapshot.identity,
                                      sectionKey: sectionKey)
        }, as: MetadataResponse.self) { response in
            response.mediaContainer.metadata.filter { $0.kind == .track }
        }
    }

    func setPlayed(ratingKey: String, played: Bool) async throws {
        _ = try await executor.execute { snapshot in
            played
                ? TimelineRequest.scrobble(server: snapshot.session.baseURL,
                                           token: snapshot.session.token,
                                           identity: snapshot.identity,
                                           ratingKey: ratingKey)
                : TimelineRequest.unscrobble(server: snapshot.session.baseURL,
                                             token: snapshot.session.token,
                                             identity: snapshot.identity,
                                             ratingKey: ratingKey)
        }
    }

    private func musicPage(
        _ build: @escaping @Sendable (PlexBrowseExecutionSnapshot) -> PlexRequest
    ) async throws -> MusicPage {
        try await executor.execute(build, as: MetadataResponse.self) { response in
            let items = response.mediaContainer.metadata
            return MusicPage(items: items,
                             total: max(response.mediaContainer.totalSize ?? items.count,
                                        items.count))
        }
    }
}

private struct PlexArtistDetailMappingInput: Sendable {
    let own: [MediaItem]
    let hubs: [Hub]
    let appears: [MediaItem]
    let popular: [MediaItem]

    func content() -> ArtistDetailContent {
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
        let appearsOn = appears.filter { $0.kind == .album && !ownKeys.contains($0.ratingKey) }
        let popularTracks = popular.filter { $0.kind == .track }
        return ArtistDetailContent(albums: albums, popular: popularTracks,
                                   categorized: categorized, appearsOn: appearsOn, similar: similar)
    }
}

private struct PlexFirstCharacterResponse: Decodable, Sendable {
    let mediaContainer: Container
    enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }

    struct Container: Decodable, Sendable {
        let directory: [Entry]
        enum CodingKeys: String, CodingKey { case directory = "Directory" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            directory = try container.decodeIfPresent([Entry].self, forKey: .directory) ?? []
        }
    }

    struct Entry: Decodable, Sendable {
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
