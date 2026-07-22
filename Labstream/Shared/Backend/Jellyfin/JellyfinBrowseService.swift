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
        try await browseCore().userViews()
    }

    func userViewLinks() async throws -> [JellyfinLibraryLink] {
        try await browseCore().userViewLinks()
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
               filters: [String] = [],
               browseQuery: LibraryBrowseQuery = .default) async throws -> [MediaItem] {
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
                                       filters: filters,
                                       browseQuery: browseQuery)
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
                   filters: [String] = [],
                   browseQuery: LibraryBrowseQuery = .default) async throws -> (items: [MediaItem], total: Int?) {
        let page = try await browseCore().itemsPage(MediaBrowserItemsQuery(
            parentID: parentId, recursive: recursive, startIndex: startIndex, limit: limit,
            searchTerm: searchTerm, nameStartsWith: nameStartsWith, sortBy: sortBy,
            sortOrder: sortOrder, includeItemTypes: includeItemTypes, fields: fields,
            albumArtistIDs: albumArtistIds, artistIDs: artistIds, filters: filters,
            browseQuery: browseQuery
        ))
        return (page.items, page.total)
    }

    /// Children of a backend BoxSet/collection. Uses the generic Items + ParentId read
    /// path, not MediaBrowser collection-management endpoints.
    func collectionItemsPage(collectionId: String,
                             startIndex: Int? = nil,
                             limit: Int? = nil) async throws -> (items: [MediaItem], total: Int?) {
        let context = try context()
        let req = try JellyfinLibrary.collectionItemsRequest(server: context.server,
                                                             token: context.token,
                                                             identity: jellyfinIdentity,
                                                             userId: context.userID,
                                                             collectionId: collectionId,
                                                             startIndex: startIndex,
                                                             limit: limit)
        let response = try await send(req, as: JellyfinItemsResponse.self)
        return (response.items.compactMap { $0.toMediaItem() }, response.totalRecordCount)
    }

    /// Playable related media for a detail page (#199): local trailers first, then special
    /// features. Both endpoints return a bare `BaseItemDto` ARRAY (not an Items envelope).
    /// Each endpoint degrades independently — a failed/unsupported call contributes an
    /// empty list rather than sinking the whole shelf.
    func relatedMedia(itemId: String) async -> [MediaItem] {
        guard let context = try? context() else { return [] }
        var items: [MediaItem] = []
        if let req = try? JellyfinLibrary.localTrailersRequest(server: context.server,
                                                               token: context.token,
                                                               identity: jellyfinIdentity,
                                                               userId: context.userID,
                                                               itemId: itemId),
           let rows = try? await send(req, as: [JellyfinBaseItemDto].self) {
            items += rows.compactMap { $0.toMediaItem() }
        }
        if let req = try? JellyfinLibrary.specialFeaturesRequest(server: context.server,
                                                                 token: context.token,
                                                                 identity: jellyfinIdentity,
                                                                 userId: context.userID,
                                                                 itemId: itemId),
           let rows = try? await send(req, as: [JellyfinBaseItemDto].self) {
            items += rows.compactMap { $0.toMediaItem() }
        }
        return items
    }

    /// Tag-aggregated album artists for a music library (#111), via `/Artists/AlbumArtists`.
    func albumArtistsPage(parentId: String?,
                          startIndex: Int? = nil,
                          limit: Int? = nil,
                          nameStartsWith: String? = nil,
                          sortBy: String = "SortName",
                          sortOrder: String = "Ascending") async throws -> (items: [MediaItem], total: Int?) {
        let page = try await browseCore().albumArtistsPage(
            parentID: parentId, startIndex: startIndex, limit: limit,
            nameStartsWith: nameStartsWith, sortBy: sortBy, sortOrder: sortOrder
        )
        return (page.items, page.total)
    }

    /// Ordered tracks of an audio playlist (#111), via `/Playlists/{id}/Items` — playlist
    /// order is preserved by the endpoint, so the caller must not re-sort.
    func playlistItems(playlistId: String) async throws -> [MediaItem] {
        try await browseCore().playlistItems(playlistID: playlistId)
    }

    func searchResults(query: String, limitPerLibrary: Int = 50) async throws -> SearchResults {
        try await browseCore().searchResults(query: query, limitPerLibrary: limitPerLibrary)
    }

    func resumeItems(parentId: String? = nil, limit: Int = 20) async throws -> [MediaItem] {
        try await resumeItemsPage(parentId: parentId, startIndex: 0, limit: limit).items
    }

    func resumeItemsPage(parentId: String? = nil,
                         startIndex: Int,
                         limit: Int) async throws -> (items: [MediaItem], total: Int?) {
        let page = try await browseCore().resumeItemsPage(
            parentID: parentId, startIndex: startIndex, limit: limit)
        return (page.items, page.total)
    }

    func nextUp(parentId: String? = nil, limit: Int = 20) async throws -> [MediaItem] {
        try await nextUpPage(parentId: parentId, startIndex: 0, limit: limit).items
    }

    func nextUpPage(parentId: String? = nil,
                    startIndex: Int,
                    limit: Int) async throws -> (items: [MediaItem], total: Int?) {
        let page = try await browseCore().nextUpPage(
            parentID: parentId, startIndex: startIndex, limit: limit)
        return (page.items, page.total)
    }

    func latestItems(parentId: String?,
                     includeItemTypes: String = "Movie,Episode,Video",
                     limit: Int = 20) async throws -> [MediaItem] {
        try await browseCore().latestItems(parentID: parentId,
                                           includeItemTypes: includeItemTypes,
                                           limit: limit)
    }

    func metadata(itemId: String) async throws -> MediaItem {
        guard let item = try await browseCore().metadata(itemID: itemId) else {
            throw ServiceError.noPlayableItem
        }
        return item
    }

    func metadata(itemId: String,
                  session: BackendSession,
                  identity: ClientIdentity) async throws -> MediaItem {
        guard session.kind == .jellyfin,
              let userID = session.userID else { throw ServiceError.notAuthenticated }
        let core = MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(server: session.baseURL,
                                               token: session.token,
                                               userID: userID,
                                               identity: identity.jellyfin),
            adapter: JellyfinBrowseCoreAdapter(),
            send: { request in try await send(request) }
        )
        guard let item = try await core.metadata(itemID: itemId) else {
            throw ServiceError.noPlayableItem
        }
        return item
    }

    func playbackOpen(item: MediaItem,
                      maxVideoBitrateKbps: Int,
                      resumeOffsetMs: Int? = nil,
                      mediaSourceId: String? = nil,
                      audioStreamIndex: Int? = nil,
                      subtitleStreamIndex: Int? = nil) async throws -> MediaBrowserPlaybackOpenResult {
        let context = try context()
        let session = BackendSession(kind: .jellyfin, baseURL: context.server,
                                     token: context.token, userID: context.userID,
                                     serverID: appModel.jellyfinServerID)
        return try await playbackOpen(item: item, session: session, identity: appModel.identity,
                                      maxVideoBitrateKbps: maxVideoBitrateKbps,
                                      resumeOffsetMs: resumeOffsetMs,
                                      mediaSourceId: mediaSourceId,
                                      audioStreamIndex: audioStreamIndex,
                                      subtitleStreamIndex: subtitleStreamIndex)
    }

    func playbackOpen(item: MediaItem,
                      session playbackSession: BackendSession,
                      identity: ClientIdentity,
                      maxVideoBitrateKbps: Int,
                      resumeOffsetMs: Int? = nil,
                      mediaSourceId: String? = nil,
                      audioStreamIndex: Int? = nil,
                      subtitleStreamIndex: Int? = nil) async throws -> MediaBrowserPlaybackOpenResult {
        guard playbackSession.kind == .jellyfin,
              let userID = playbackSession.userID else { throw ServiceError.notAuthenticated }
        let context = (server: playbackSession.baseURL, token: playbackSession.token, userID: userID)
        let requestIdentity = identity.jellyfin
        let qualityPolicy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: maxVideoBitrateKbps)
        let startTicks = MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: resumeOffsetMs ?? item.viewOffset)
        // GH #196 DV P5 guard: a fallback-less DV stream must not travel a video-copy lane.
        // Jellyfin's transcoder detects untagged P5 and tone-maps properly (setparams +
        // tonemap_cuda, kubectl-verified), so the forced-transcode lane is the right one here.
        let dvVerdict = DolbyVisionGuard.verdict(for: item)
        let forceTranscode: Bool
        if case .forceToneMapTranscode(let reason) = dvVerdict {
            forceTranscode = true
            NSLog("JellyfinBrowseService: forcing tone-map transcode (%@)", reason)
        } else {
            forceTranscode = false
        }
        let req = try JellyfinPlayback.playbackInfoRequest(server: context.server,
                                                           token: context.token,
                                                           identity: requestIdentity,
                                                           itemId: item.ratingKey,
                                                           userId: context.userID,
                                                           mediaSourceId: mediaSourceId,
                                                           startTimeTicks: startTicks,
                                                           maxStreamingBitrate: qualityPolicy.maxStreamingBitrateBps,
                                                           audioStreamIndex: audioStreamIndex,
                                                           subtitleStreamIndex: subtitleStreamIndex,
                                                           forcePlaybackTranscode: forceTranscode,
                                                           advertiseDolbyVision: DolbyVisionGuard.shouldAdvertiseDolbyVision(for: item))
        let info = try await send(req, as: JellyfinPlaybackInfoResponse.self)
        do {
            return try JellyfinPlayback.resolveMediaBrowserStream(
                response: info,
                server: context.server,
                identity: requestIdentity,
                token: context.token,
                itemId: item.ratingKey,
                preferredMediaSourceId: mediaSourceId,
                startTimeTicks: startTicks,
                maxVideoBitrate: qualityPolicy.maxStreamingBitrateBps,
                maxWidth: qualityPolicy.maxWidth,
                maxHeight: qualityPolicy.maxHeight,
                audioBitrate: qualityPolicy.audioBitrateBps,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex)
        } catch {
            // PlaybackInfo may mint an encoder before its response proves that the explicitly
            // selected source is unavailable. Rejecting that response must also tear down the
            // session it minted rather than leaking an alternate-source transcode.
            if let playSessionID = info.playSessionId, !playSessionID.isEmpty {
                _ = await stopActiveEncoding(playSessionId: playSessionID,
                                             session: playbackSession,
                                             identity: identity)
            }
            throw error
        }
    }



    func setPlayed(itemId: String, played: Bool) async throws {
        try await browseCore().setPlayed(itemID: itemId, played: played)
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
        await stopActiveEncoding(playSessionId: playSessionId,
                                 session: session,
                                 identity: appModel.identity)
    }

    @discardableResult
    func stopActiveEncoding(playSessionId: String,
                            session: BackendSession,
                            identity: ClientIdentity) async -> Bool {
        // Authenticate against the EXPLICIT session the caller resolved/validated for this job's
        // backend — never re-read the live `context()` lane, which may have been re-pointed at a
        // different server since (the #84 launch sweep validates the server match before calling;
        // `releaseInFlight` passes the job's own lane, which may not be the active one).
        return await MediaBrowserActiveEncodingStopExecutor.stop(
            playSessionId: playSessionId,
            makeRequest: {
                try JellyfinLibrary.activeEncodingStopRequest(server: session.baseURL,
                                                              token: session.token,
                                                              identity: identity.jellyfin,
                                                              deviceId: identity.clientIdentifier,
                                                              playSessionId: playSessionId)
            },
            send: { req in _ = try await send(req) },
            httpStatus: Self.httpStatus(fromActiveEncodingStopError:))
    }

    nonisolated private static func httpStatus(fromActiveEncodingStopError error: Error) -> Int? {
        guard case ServiceError.http(let status) = error else { return nil }
        return status
    }

    private func browseCore() throws -> MediaBrowserBrowseCore<JellyfinBrowseCoreAdapter> {
        let values = try context()
        return MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(server: values.server,
                                               token: values.token,
                                               userID: values.userID,
                                               identity: jellyfinIdentity),
            adapter: JellyfinBrowseCoreAdapter(),
            send: { request in try await send(request) }
        )
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
