import Foundation
import PMSKit

@MainActor
struct JellyfinBrowseService {
    let appModel: AppModel
    var session: URLSession = .shared

    enum ServiceError: Error, LocalizedError {
        case notAuthenticated
        case noPlayableItem
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "No active Jellyfin session."
            case .noPlayableItem: return "Jellyfin did not return a playable item."
            case .http(let status): return "Jellyfin server error (HTTP \(status))."
            }
        }
    }

    var jellyfinIdentity: JellyfinClientIdentity {
        appModel.identity.jellyfin
    }

    func userViews() async throws -> [JellyfinBaseItemDto] {
        let context = try context()
        let req = try JellyfinLibrary.userViewsRequest(server: context.server,
                                                       token: context.token,
                                                       identity: jellyfinIdentity,
                                                       userId: context.userID)
        let response = try await send(req, as: JellyfinUserViewsResponse.self)
        return response.items
    }

    func userViewLinks() async throws -> [JellyfinLibraryLink] {
        try await userViews().map {
            JellyfinLibraryLink(id: $0.id, title: $0.name, collectionType: $0.collectionType)
        }
    }

    func items(parentId: String?,
               recursive: Bool = false,
               startIndex: Int? = nil,
               limit: Int? = nil,
               searchTerm: String? = nil,
               nameStartsWith: String? = nil,
               sortBy: String = "SortName",
               sortOrder: String = "Ascending",
               includeItemTypes: String = "Movie,Series,Season,Episode,Video",
               fields: String = JellyfinLibrary.fullItemFields,
               filters: [String] = []) async throws -> [MediaItem] {
        let page = try await itemsPage(parentId: parentId,
                                       recursive: recursive,
                                       startIndex: startIndex,
                                       limit: limit,
                                       searchTerm: searchTerm,
                                       nameStartsWith: nameStartsWith,
                                       sortBy: sortBy,
                                       sortOrder: sortOrder,
                                       includeItemTypes: includeItemTypes,
                                       fields: fields,
                                       filters: filters)
        return page.items
    }

    func itemsPage(parentId: String?,
                   recursive: Bool = false,
                   startIndex: Int? = nil,
                   limit: Int? = nil,
                   searchTerm: String? = nil,
                   nameStartsWith: String? = nil,
                   sortBy: String = "SortName",
                   sortOrder: String = "Ascending",
                   includeItemTypes: String = "Movie,Series,Season,Episode,Video",
                   fields: String = JellyfinLibrary.fullItemFields,
                   albumArtistIds: String? = nil,
                   artistIds: String? = nil,
                   filters: [String] = []) async throws -> (items: [MediaItem], total: Int?) {
        let context = try context()
        let req = try JellyfinLibrary.itemsRequest(server: context.server,
                                                   token: context.token,
                                                   identity: jellyfinIdentity,
                                                   userId: context.userID,
                                                   parentId: parentId,
                                                   recursive: recursive,
                                                   startIndex: startIndex,
                                                   limit: limit,
                                                   searchTerm: searchTerm,
                                                   nameStartsWith: nameStartsWith,
                                                   sortBy: sortBy,
                                                   sortOrder: sortOrder,
                                                   includeItemTypes: includeItemTypes,
                                                   fields: fields,
                                                   albumArtistIds: albumArtistIds,
                                                   artistIds: artistIds,
                                                   filters: filters)
        let response = try await send(req, as: JellyfinItemsResponse.self)
        return (response.items.compactMap { $0.toMediaItem() }, response.totalRecordCount)
    }

    /// Tag-aggregated album artists for a music library (#111), via `/Artists/AlbumArtists`.
    func albumArtistsPage(parentId: String?,
                          startIndex: Int? = nil,
                          limit: Int? = nil,
                          nameStartsWith: String? = nil,
                          sortBy: String = "SortName",
                          sortOrder: String = "Ascending") async throws -> (items: [MediaItem], total: Int?) {
        let context = try context()
        let req = try JellyfinLibrary.albumArtistsRequest(server: context.server,
                                                          token: context.token,
                                                          identity: jellyfinIdentity,
                                                          userId: context.userID,
                                                          parentId: parentId,
                                                          startIndex: startIndex,
                                                          limit: limit,
                                                          nameStartsWith: nameStartsWith,
                                                          sortBy: sortBy,
                                                          sortOrder: sortOrder)
        let response = try await send(req, as: JellyfinItemsResponse.self)
        return (response.items.compactMap { $0.toMediaItem() }, response.totalRecordCount)
    }

    /// Ordered tracks of an audio playlist (#111), via `/Playlists/{id}/Items` — playlist
    /// order is preserved by the endpoint, so the caller must not re-sort.
    func playlistItems(playlistId: String) async throws -> [MediaItem] {
        let context = try context()
        let req = try JellyfinLibrary.playlistItemsRequest(server: context.server,
                                                           token: context.token,
                                                           identity: jellyfinIdentity,
                                                           userId: context.userID,
                                                           playlistId: playlistId)
        let response = try await send(req, as: JellyfinItemsResponse.self)
        return response.items.compactMap { $0.toMediaItem() }
    }

    func searchResults(query: String, limitPerLibrary: Int = 50) async throws -> SearchResults {
        _ = try context()
        let views = try await userViewLinks()
        let groupsByIndex = try await withThrowingTaskGroup(
            of: (Int, SearchResultGroup?).self,
            returning: [Int: SearchResultGroup].self
        ) { taskGroup in
            for (index, view) in views.enumerated() {
                taskGroup.addTask {
                    let items = try await self.items(parentId: view.id,
                                                     recursive: true,
                                                     limit: limitPerLibrary,
                                                     searchTerm: query,
                                                     sortBy: "SortName",
                                                     sortOrder: "Ascending",
                                                     includeItemTypes: mediaBrowserSearchItemTypes(forCollectionType: view.collectionType))
                    let group = SearchResultGroup.mediaBrowserLibrary(backendID: "jellyfin",
                                                                      libraryID: view.id,
                                                                      title: view.title,
                                                                      items: items)
                    return (index, group)
                }
            }

            var groupsByIndex: [Int: SearchResultGroup] = [:]
            for try await (index, group) in taskGroup {
                if let group { groupsByIndex[index] = group }
            }
            return groupsByIndex
        }

        let groups = views.indices.compactMap { groupsByIndex[$0] }
        return SearchResults(groups: groups)
    }

    func resumeItems(parentId: String? = nil, limit: Int = 20) async throws -> [MediaItem] {
        let context = try context()
        let req = try JellyfinLibrary.resumeItemsRequest(server: context.server,
                                                         token: context.token,
                                                         identity: jellyfinIdentity,
                                                         userId: context.userID,
                                                         parentId: parentId,
                                                         limit: limit)
        let response = try await send(req, as: JellyfinItemsResponse.self)
        return response.items.compactMap { $0.toMediaItem() }
    }

    func nextUp(parentId: String? = nil, limit: Int = 20) async throws -> [MediaItem] {
        let context = try context()
        let req = try JellyfinLibrary.nextUpRequest(server: context.server,
                                                    token: context.token,
                                                    identity: jellyfinIdentity,
                                                    userId: context.userID,
                                                    parentId: parentId,
                                                    limit: limit)
        let response = try await send(req, as: JellyfinItemsResponse.self)
        return response.items.compactMap { $0.toMediaItem() }
    }

    func latestItems(parentId: String?,
                     includeItemTypes: String = "Movie,Episode,Video",
                     limit: Int = 20) async throws -> [MediaItem] {
        let context = try context()
        let req = try JellyfinLibrary.latestItemsRequest(server: context.server,
                                                         token: context.token,
                                                         identity: jellyfinIdentity,
                                                         userId: context.userID,
                                                         parentId: parentId,
                                                         includeItemTypes: includeItemTypes,
                                                         limit: limit)
        let response = try await send(req, as: [JellyfinBaseItemDto].self)
        return response.compactMap { $0.toMediaItem() }
    }

    func metadata(itemId: String) async throws -> MediaItem {
        let context = try context()
        let req = try JellyfinLibrary.itemRequest(server: context.server,
                                                  token: context.token,
                                                  identity: jellyfinIdentity,
                                                  userId: context.userID,
                                                  itemId: itemId)
        let dto = try await send(req, as: JellyfinBaseItemDto.self)
        guard let item = dto.toMediaItem() else { throw ServiceError.noPlayableItem }
        return item
    }

    func playbackOpen(item: MediaItem,
                      maxVideoBitrateKbps: Int,
                      resumeOffsetMs: Int? = nil,
                      audioStreamIndex: Int? = nil,
                      subtitleStreamIndex: Int? = nil) async throws -> JellyfinPlaybackOpenResult {
        let context = try context()
        let qualityPolicy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: maxVideoBitrateKbps)
        let startTicks = MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: resumeOffsetMs ?? item.viewOffset)
        let req = try JellyfinPlayback.playbackInfoRequest(server: context.server,
                                                           token: context.token,
                                                           identity: jellyfinIdentity,
                                                           itemId: item.ratingKey,
                                                           userId: context.userID,
                                                           startTimeTicks: startTicks,
                                                           maxStreamingBitrate: qualityPolicy.maxStreamingBitrateBps,
                                                           audioStreamIndex: audioStreamIndex,
                                                           subtitleStreamIndex: subtitleStreamIndex)
        let info = try await send(req, as: JellyfinPlaybackInfoResponse.self)
        return try JellyfinPlayback.resolveStream(response: info,
                                                  server: context.server,
                                                  identity: jellyfinIdentity,
                                                  token: context.token,
                                                  itemId: item.ratingKey,
                                                  startTimeTicks: startTicks,
                                                  maxVideoBitrate: qualityPolicy.maxStreamingBitrateBps,
                                                  maxWidth: qualityPolicy.maxWidth,
                                                  maxHeight: qualityPolicy.maxHeight,
                                                  audioBitrate: qualityPolicy.audioBitrateBps,
                                                  audioStreamIndex: audioStreamIndex,
                                                  subtitleStreamIndex: subtitleStreamIndex)
    }



    func setPlayed(itemId: String, played: Bool) async throws {
        let context = try context()
        let req = try JellyfinLibrary.markPlayedRequest(server: context.server,
                                                        token: context.token,
                                                        identity: jellyfinIdentity,
                                                        userId: context.userID,
                                                        itemId: itemId,
                                                        played: played)
        _ = try await send(req)
    }

    func downloadRequest(itemId: String,
                         mediaSourceId: String?,
                         container: String?) throws -> URLRequest {
        let context = try context()
        return try JellyfinLibrary.downloadRequest(server: context.server,
                                                   token: context.token,
                                                   identity: jellyfinIdentity,
                                                   itemId: itemId,
                                                   mediaSourceId: mediaSourceId,
                                                   container: container)
    }

    func transcodedDownloadRequest(itemId: String,
                                   mediaSourceId: String?,
                                   maxVideoBitrate: Int,
                                   maxWidth: Int?,
                                   maxHeight: Int?) throws -> URLRequest {
        let context = try context()
        return try JellyfinLibrary.transcodedDownloadRequest(server: context.server,
                                                             token: context.token,
                                                             identity: jellyfinIdentity,
                                                             itemId: itemId,
                                                             mediaSourceId: mediaSourceId,
                                                             maxVideoBitrate: maxVideoBitrate,
                                                             maxWidth: maxWidth,
                                                             maxHeight: maxHeight)
    }

    /// Returns whether the encoder is confirmed gone. `true` on a 2xx, and also when the
    /// server answers that there is nothing to stop (404/400) — either way the FFmpeg job is
    /// no longer live. `false` only when we could not reach/authenticate the server, so the
    /// caller (#84 launch sweep) keeps the persisted PlaySessionId for a later retry.
    /// Convenience for playback teardown, which always runs on the live (active) lane.
    /// Download teardown uses the explicit-`session` overload so it targets the job's OWN
    /// backend even after a switch.
    @discardableResult
    func stopActiveEncoding(playSessionId: String) async -> Bool {
        guard let ctx = try? context() else { return false }
        let session = BackendSession(kind: .jellyfin, baseURL: ctx.server, token: ctx.token, userID: ctx.userID)
        return await stopActiveEncoding(playSessionId: playSessionId, session: session)
    }

    @discardableResult
    func stopActiveEncoding(playSessionId: String, session: BackendSession) async -> Bool {
        guard !playSessionId.isEmpty else { return false }
        // Authenticate against the EXPLICIT session the caller resolved/validated for this job's
        // backend — never re-read the live `context()` lane, which may have been re-pointed at a
        // different server since (the #84 launch sweep validates the server match before calling;
        // `releaseInFlight` passes the job's own lane, which may not be the active one).
        guard let req = try? JellyfinLibrary.activeEncodingStopRequest(server: session.baseURL,
                                                                       token: session.token,
                                                                       identity: jellyfinIdentity,
                                                                       deviceId: appModel.identity.clientIdentifier,
                                                                       playSessionId: playSessionId) else { return false }
        do {
            _ = try await send(req)
            return true
        } catch ServiceError.http(let status) {
            // Only treat the session-is-unknown answers as "gone": 400/404/410. An auth
            // rejection (401/403) or a server error (5xx) means the DELETE did NOT confirm
            // the job is dead — the encoder may still be live, so keep the psid and retry on
            // a later launch rather than orphaning it (#84).
            return MediaBrowserActiveEncodingStopPolicy.isConfirmedStopped(httpStatus: status)
        } catch {
            return false   // transport failure — keep the psid for a later launch
        }
    }

    private func context() throws -> (server: URL, token: String, userID: String) {
        guard let server = appModel.jellyfinServerBaseURL,
              let token = appModel.jellyfinAccessToken,
              let userID = appModel.jellyfinUserID else {
            throw ServiceError.notAuthenticated
        }
        return (server, token, userID)
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data = try await send(request)
        return try MediaBrowserRequestExecutor.decode(data, as: type)
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        do {
            return try await MediaBrowserRequestExecutor(session: session).send(request)
        } catch MediaBrowserRequestError.httpStatus(let status) {
            throw ServiceError.http(status)
        }
    }
}

struct JellyfinLibraryLink: Identifiable, Hashable {
    let id: String
    let title: String
    let collectionType: String?
}
