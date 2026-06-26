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

    func homeRails(for views: [EmbyLibraryLink]) async throws -> HomeRailsLoad<EmbyHomeRail> {
        _ = try context()
        var rails: [EmbyHomeRail] = []
        // Mirrors Jellyfin (#93): record per-rail errors so a degraded load is not cached
        // as authoritative by the Home view.
        var tracker = HomeRailsLoadTracker()

        async let continueWatchingResult = HomeRailsLoadTracker.resultOf { try await resumeItems(limit: 20) }
        async let nextUpResult = HomeRailsLoadTracker.resultOf { try await nextUp(limit: 20) }

        if let continueWatching = tracker.record(await continueWatchingResult), !continueWatching.isEmpty {
            rails.append(EmbyHomeRail(id: "continue-watching",
                                      title: "Continue Watching",
                                      items: continueWatching))
        }

        if let nextUpItems = tracker.record(await nextUpResult), !nextUpItems.isEmpty {
            rails.append(EmbyHomeRail(id: "next-up",
                                      title: "Next Up",
                                      items: nextUpItems))
        }

        for view in views.prefix(8) {
            let items = await tracker.attempt {
                try await latestItems(parentId: view.id,
                                      includeItemTypes: latestItemTypes(for: view),
                                      limit: 20)
            } ?? []
            if !items.isEmpty {
                rails.append(EmbyHomeRail(id: "latest-\(view.id)",
                                          title: "Recently Added \(view.title)",
                                          items: items))
            }
        }
        if tracker.isDegraded {
            NSLog("[#93] Emby homeRails degraded: %d of up to %d rails returned; will not pin loaded identity",
                  rails.count, views.prefix(8).count + 2)
        }
        return HomeRailsLoad(rails: rails, isDegraded: tracker.isDegraded)
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
        let maxBitrateBps = maxVideoBitrateKbps <= 0 ? 200_000_000 : maxVideoBitrateKbps * 1_000
        let resolutionCap = Self.resolutionCap(forBitrateKbps: maxVideoBitrateKbps)
        let audioBitrate = Self.audioBitrate(forBitrateKbps: maxVideoBitrateKbps)
        let startTicks = (resumeOffsetMs ?? item.viewOffset).map { $0 * 10_000 }
        // DIVERGENCE: Emby PlaybackInfo needs UserId in BOTH query and body.
        let req = try EmbyPlayback.playbackInfoRequest(server: context.server,
                                                       token: context.token,
                                                       identity: embyIdentity,
                                                       userId: context.userID,
                                                       itemId: item.ratingKey,
                                                       startTimeTicks: startTicks,
                                                       maxStreamingBitrate: maxBitrateBps,
                                                       audioStreamIndex: audioStreamIndex,
                                                       subtitleStreamIndex: subtitleStreamIndex)
        let info = try await send(req, as: EmbyPlaybackInfoResponse.self)
        return try EmbyPlayback.resolveStream(response: info,
                                              server: context.server,
                                              identity: embyIdentity,
                                              token: context.token,
                                              userId: context.userID,
                                              itemId: item.ratingKey,
                                              startTimeTicks: startTicks,
                                              maxVideoBitrate: maxBitrateBps,
                                              maxWidth: resolutionCap?.width,
                                              maxHeight: resolutionCap?.height,
                                              audioBitrate: audioBitrate,
                                              audioStreamIndex: audioStreamIndex,
                                              subtitleStreamIndex: subtitleStreamIndex)
    }

    private static func resolutionCap(forBitrateKbps kbps: Int) -> (width: Int, height: Int)? {
        switch kbps {
        case 1...4_000:
            return (1280, 720)
        case 4_001...20_000:
            return (1920, 1080)
        case 20_001...40_000:
            return (3840, 2160)
        default:
            return nil
        }
    }

    private static func audioBitrate(forBitrateKbps kbps: Int) -> Int? {
        switch kbps {
        case 1...4_000:
            return 256_000
        case 4_001...20_000:
            return 640_000
        default:
            return nil
        }
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
        guard !playSessionId.isEmpty, let userID = session.userID else { return false }
        // Authenticate against the EXPLICIT session the caller resolved/validated for this job's
        // backend — never re-read the live `context()` lane, which may have been re-pointed at a
        // different server since (the #84 launch sweep validates the server match before calling;
        // `releaseInFlight` passes the job's own lane, which may not be the active one).
        guard let req = try? EmbyLibrary.activeEncodingStopRequest(server: session.baseURL,
                                                                   token: session.token,
                                                                   identity: embyIdentity,
                                                                   userId: userID,
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
            return status == 400 || status == 404 || status == 410
        } catch {
            return false   // transport failure — keep the psid for a later launch
        }
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
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServiceError.http(http.statusCode)
        }
        return data
    }
}

private func latestItemTypes(for view: EmbyLibraryLink) -> String {
    switch view.collectionType?.lowercased() {
    case "movies":
        return "Movie"
    case "tvshows":
        return "Episode"
    case "homevideos", "livetv":
        return "Video"
    default:
        return "Movie,Episode,Video"
    }
}

struct EmbyLibraryLink: Identifiable, Hashable {
    let id: String
    let title: String
    let collectionType: String?
}

struct EmbyHomeRail: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [MediaItem]
}
