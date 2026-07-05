import Foundation
import PMSKit

/// App-layer browse/playback facade for the Emby backend. Mirrors
/// `JellyfinBrowseService` but uses the Emby PMSKit lane (distinct auth header
/// scheme, `UserId` in PlaybackInfo query+body, base-path preservation).
@MainActor
struct EmbyBrowseService {
    let appModel: AppModel
    var session: URLSession = .shared

    enum ServiceError: Error, LocalizedError {
        case notAuthenticated
        case noPlayableItem
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "No active Emby session."
            case .noPlayableItem: return "Emby did not return a playable item."
            case .http(let status): return "Emby server error (HTTP \(status))."
            }
        }
    }

    var embyIdentity: EmbyClientIdentity {
        appModel.identity.emby
    }

    func userViews() async throws -> [EmbyBaseItemDto] {
        let context = try context()
        let req = try EmbyLibrary.userViewsRequest(server: context.server,
                                                   token: context.token,
                                                   identity: embyIdentity,
                                                   userId: context.userID)
        let response = try await send(req, as: EmbyUserViewsResponse.self)
        return response.items
    }

    func userViewLinks() async throws -> [EmbyLibraryLink] {
        try await userViews().map {
            EmbyLibraryLink(id: $0.id, title: $0.name, collectionType: $0.collectionType)
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
               fields: String = EmbyLibrary.fullItemFields,
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
                   fields: String = EmbyLibrary.fullItemFields,
                   albumArtistIds: String? = nil,
                   artistIds: String? = nil,
                   filters: [String] = []) async throws -> (items: [MediaItem], total: Int?) {
        let context = try context()
        let req = try EmbyLibrary.itemsRequest(server: context.server,
                                               token: context.token,
                                               identity: embyIdentity,
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
        let response = try await send(req, as: EmbyItemsResponse.self)
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
        let req = try EmbyLibrary.albumArtistsRequest(server: context.server,
                                                      token: context.token,
                                                      identity: embyIdentity,
                                                      userId: context.userID,
                                                      parentId: parentId,
                                                      startIndex: startIndex,
                                                      limit: limit,
                                                      nameStartsWith: nameStartsWith,
                                                      sortBy: sortBy,
                                                      sortOrder: sortOrder)
        let response = try await send(req, as: EmbyItemsResponse.self)
        return (response.items.compactMap { $0.toMediaItem() }, response.totalRecordCount)
    }

    /// Ordered tracks of an audio playlist (#111) — see the Jellyfin twin. Playlist order
    /// is preserved by `/Playlists/{id}/Items`, so the caller must not re-sort.
    func playlistItems(playlistId: String) async throws -> [MediaItem] {
        let context = try context()
        let req = try EmbyLibrary.playlistItemsRequest(server: context.server,
                                                       token: context.token,
                                                       identity: embyIdentity,
                                                       userId: context.userID,
                                                       playlistId: playlistId)
        let response = try await send(req, as: EmbyItemsResponse.self)
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
                    let group = SearchResultGroup.mediaBrowserLibrary(backendID: "emby",
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
        let req = try EmbyLibrary.resumeItemsRequest(server: context.server,
                                                     token: context.token,
                                                     identity: embyIdentity,
                                                     userId: context.userID,
                                                     parentId: parentId,
                                                     limit: limit)
        let response = try await send(req, as: EmbyItemsResponse.self)
        return response.items.compactMap { $0.toMediaItem() }
    }

    func nextUp(parentId: String? = nil, limit: Int = 20) async throws -> [MediaItem] {
        let context = try context()
        let req = try EmbyLibrary.nextUpRequest(server: context.server,
                                                token: context.token,
                                                identity: embyIdentity,
                                                userId: context.userID,
                                                parentId: parentId,
                                                limit: limit)
        let response = try await send(req, as: EmbyItemsResponse.self)
        return response.items.compactMap { $0.toMediaItem() }
    }

    func latestItems(parentId: String?,
                     includeItemTypes: String = "Movie,Episode,Video",
                     limit: Int = 20) async throws -> [MediaItem] {
        let context = try context()
        let req = try EmbyLibrary.latestItemsRequest(server: context.server,
                                                     token: context.token,
                                                     identity: embyIdentity,
                                                     userId: context.userID,
                                                     parentId: parentId,
                                                     includeItemTypes: includeItemTypes,
                                                     limit: limit)
        let response = try await send(req, as: [EmbyBaseItemDto].self)
        return response.compactMap { $0.toMediaItem() }
    }

    func metadata(itemId: String) async throws -> MediaItem {
        let context = try context()
        let req = try EmbyLibrary.itemRequest(server: context.server,
                                              token: context.token,
                                              identity: embyIdentity,
                                              userId: context.userID,
                                              itemId: itemId)
        let dto = try await send(req, as: EmbyBaseItemDto.self)
        guard let item = dto.toMediaItem() else { throw ServiceError.noPlayableItem }
        return item
    }

    func playbackOpen(item: MediaItem,
                      maxVideoBitrateKbps: Int,
                      resumeOffsetMs: Int? = nil,
                      audioStreamIndex: Int? = nil,
                      subtitleStreamIndex: Int? = nil) async throws -> EmbyPlaybackOpenResult {
        let context = try context()
        let qualityPolicy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: maxVideoBitrateKbps)
        let startTicks = MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: resumeOffsetMs ?? item.viewOffset)
        // GH #196 DV P5 guard: a fallback-less DV stream must not travel a video-copy lane.
        // Emby is the backend where the unguarded failure is a SILENT black screen — and its
        // transcoder cannot tone-map an untagged P5 input either (no tonemap filter in the
        // ffmpeg graph; the "successful" transcode bakes in green/purple tint). Owner call:
        // block P5 on Emby outright rather than play garbage.
        let dvVerdict = DolbyVisionGuard.verdict(for: item, serverToneMapsUntaggedDV: false)
        let forceTranscode: Bool
        switch dvVerdict {
        case .blockPlayback(let reason):
            NSLog("EmbyBrowseService: blocking playback (%@)", reason)
            throw NSError(domain: "Labstream.Playback",
                          code: -196,
                          userInfo: [NSLocalizedDescriptionKey: DolbyVisionGuard.failureMessage])
        case .forceToneMapTranscode(let reason):
            forceTranscode = true
            NSLog("EmbyBrowseService: forcing tone-map transcode (%@)", reason)
        case .allowCopyLanes:
            forceTranscode = false
        }
        // DIVERGENCE: Emby PlaybackInfo needs UserId in BOTH query and body.
        let req = try EmbyPlayback.playbackInfoRequest(server: context.server,
                                                       token: context.token,
                                                       identity: embyIdentity,
                                                       userId: context.userID,
                                                       itemId: item.ratingKey,
                                                       startTimeTicks: startTicks,
                                                       maxStreamingBitrate: qualityPolicy.maxStreamingBitrateBps,
                                                       audioStreamIndex: audioStreamIndex,
                                                       subtitleStreamIndex: subtitleStreamIndex,
                                                       forcePlaybackTranscode: forceTranscode,
                                                       advertiseDolbyVision: DolbyVisionGuard.shouldAdvertiseDolbyVision(for: item))
        let info = try await send(req, as: EmbyPlaybackInfoResponse.self)
        return try EmbyPlayback.resolveStream(response: info,
                                              server: context.server,
                                              identity: embyIdentity,
                                              token: context.token,
                                              userId: context.userID,
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
        let req = try EmbyLibrary.markPlayedRequest(server: context.server,
                                                    token: context.token,
                                                    identity: embyIdentity,
                                                    userId: context.userID,
                                                    itemId: itemId,
                                                    played: played)
        _ = try await send(req)
    }

    /// Active-encoding cleanup invariant: `/Sessions/Playing/Stopped` does NOT stop the
    /// transcoder. For server-encoded sources, the stop path calls this on teardown.
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
        let session = BackendSession(kind: .emby, baseURL: ctx.server, token: ctx.token, userID: ctx.userID)
        return await stopActiveEncoding(playSessionId: playSessionId, session: session)
    }

    @discardableResult
    func stopActiveEncoding(playSessionId: String, session: BackendSession) async -> Bool {
        guard let userID = session.userID else { return false }
        // Authenticate against the EXPLICIT session the caller resolved/validated for this job's
        // backend — never re-read the live `context()` lane, which may have been re-pointed at a
        // different server since (the #84 launch sweep validates the server match before calling;
        // `releaseInFlight` passes the job's own lane, which may not be the active one).
        return await MediaBrowserActiveEncodingStopExecutor.stop(
            playSessionId: playSessionId,
            makeRequest: {
                try EmbyLibrary.activeEncodingStopRequest(server: session.baseURL,
                                                          token: session.token,
                                                          identity: embyIdentity,
                                                          userId: userID,
                                                          deviceId: appModel.identity.clientIdentifier,
                                                          playSessionId: playSessionId)
            },
            send: { req in _ = try await send(req) },
            httpStatus: Self.httpStatus(fromActiveEncodingStopError:))
    }

    nonisolated private static func httpStatus(fromActiveEncodingStopError error: Error) -> Int? {
        guard case ServiceError.http(let status) = error else { return nil }
        return status
    }

    private func context() throws -> (server: URL, token: String, userID: String) {
        guard let server = appModel.embyServerBaseURL,
              let token = appModel.embyAccessToken,
              let userID = appModel.embyUserID else {
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

struct EmbyLibraryLink: Identifiable, Hashable {
    let id: String
    let title: String
    let collectionType: String?
}
