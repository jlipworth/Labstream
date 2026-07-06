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
        try await browseCore().userViews()
    }

    func userViewLinks() async throws -> [EmbyLibraryLink] {
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
               fields: String = EmbyLibrary.fullItemFields,
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
                   fields: String = EmbyLibrary.fullItemFields,
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
        let req = try EmbyLibrary.collectionItemsRequest(server: context.server,
                                                         token: context.token,
                                                         identity: embyIdentity,
                                                         userId: context.userID,
                                                         collectionId: collectionId,
                                                         startIndex: startIndex,
                                                         limit: limit)
        let response = try await send(req, as: EmbyItemsResponse.self)
        return (response.items.compactMap { $0.toMediaItem() }, response.totalRecordCount)
    }

    /// Playable related media for a detail page (#199): local trailers first, then special
    /// features. Both endpoints return a bare `BaseItemDto` ARRAY (not an Items envelope).
    /// Each endpoint degrades independently — a failed/unsupported call contributes an
    /// empty list rather than sinking the whole shelf.
    func relatedMedia(itemId: String) async -> [MediaItem] {
        guard let context = try? context() else { return [] }
        var items: [MediaItem] = []
        if let req = try? EmbyLibrary.localTrailersRequest(server: context.server,
                                                           token: context.token,
                                                           identity: embyIdentity,
                                                           userId: context.userID,
                                                           itemId: itemId),
           let rows = try? await send(req, as: [EmbyBaseItemDto].self) {
            items += rows.compactMap { $0.toMediaItem() }
        }
        if let req = try? EmbyLibrary.specialFeaturesRequest(server: context.server,
                                                             token: context.token,
                                                             identity: embyIdentity,
                                                             userId: context.userID,
                                                             itemId: itemId),
           let rows = try? await send(req, as: [EmbyBaseItemDto].self) {
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

    /// Ordered tracks of an audio playlist (#111) — see the Jellyfin twin. Playlist order
    /// is preserved by `/Playlists/{id}/Items`, so the caller must not re-sort.
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
        guard session.kind == .emby,
              let userID = session.userID else { throw ServiceError.notAuthenticated }
        let core = MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(server: session.baseURL,
                                               token: session.token,
                                               userID: userID,
                                               identity: identity.emby),
            adapter: EmbyBrowseCoreAdapter(),
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
        let session = BackendSession(kind: .emby, baseURL: context.server,
                                     token: context.token, userID: context.userID,
                                     serverID: appModel.embyServerID)
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
        guard playbackSession.kind == .emby,
              let userID = playbackSession.userID else { throw ServiceError.notAuthenticated }
        let context = (server: playbackSession.baseURL, token: playbackSession.token, userID: userID)
        let requestIdentity = identity.emby
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
                                                       identity: requestIdentity,
                                                       userId: context.userID,
                                                       itemId: item.ratingKey,
                                                       mediaSourceId: mediaSourceId,
                                                       startTimeTicks: startTicks,
                                                       maxStreamingBitrate: qualityPolicy.maxStreamingBitrateBps,
                                                       audioStreamIndex: audioStreamIndex,
                                                       subtitleStreamIndex: subtitleStreamIndex,
                                                       forcePlaybackTranscode: forceTranscode,
                                                       advertiseDolbyVision: DolbyVisionGuard.shouldAdvertiseDolbyVision(for: item))
        let info = try await send(req, as: EmbyPlaybackInfoResponse.self)
        do {
            return try EmbyPlayback.resolveMediaBrowserStream(
                response: info,
                server: context.server,
                identity: requestIdentity,
                token: context.token,
                userId: context.userID,
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
            // Emby starts encoding during PlaybackInfo negotiation. If exact-source validation
            // rejects the response, clean up any alternate-source encoder before surfacing the
            // original error. Preserve Emby's direct-source contract: only send the active-
            // encoding stop when PlaybackInfo actually advertised an encoder-backed source.
            if info.mediaSources.contains(where: { $0.transcodingURL?.isEmpty == false }),
               let playSessionID = info.playSessionId, !playSessionID.isEmpty {
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
        await stopActiveEncoding(playSessionId: playSessionId,
                                 session: session,
                                 identity: appModel.identity)
    }

    @discardableResult
    func stopActiveEncoding(playSessionId: String,
                            session: BackendSession,
                            identity: ClientIdentity) async -> Bool {
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
                                                          identity: identity.emby,
                                                          userId: userID,
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

    private func browseCore() throws -> MediaBrowserBrowseCore<EmbyBrowseCoreAdapter> {
        let values = try context()
        return MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(server: values.server,
                                               token: values.token,
                                               userID: values.userID,
                                               identity: embyIdentity),
            adapter: EmbyBrowseCoreAdapter(),
            send: { request in try await send(request) }
        )
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
