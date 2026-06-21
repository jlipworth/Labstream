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
               includeItemTypes: String = "Movie,Series,Season,Episode",
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
                   includeItemTypes: String = "Movie,Series,Season,Episode",
                   fields: String = JellyfinLibrary.fullItemFields,
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
                                                   filters: filters)
        let response = try await send(req, as: JellyfinItemsResponse.self)
        return (response.items.compactMap { $0.toMediaItem() }, response.totalRecordCount)
    }

    func homeRails(for views: [JellyfinLibraryLink]) async throws -> HomeRailsLoad<JellyfinHomeRail> {
        _ = try context()
        var rails: [JellyfinHomeRail] = []
        // Track whether any rail request *errored* (vs returned empty). A degraded load
        // (e.g. rails 401ing during a re-auth window) must not be cached as authoritative,
        // or the partial Home sticks until a manual pull-to-refresh (#93).
        var tracker = HomeRailsLoadTracker()

        // These two home rails are independent server requests. Start them together so
        // Jellyfin's homepage does not pay their network latency serially; append in the
        // existing UI order once both are available. Capture each as a Result so a thrown
        // error is recorded as degraded rather than silently swallowed by `try?`.
        async let continueWatchingResult = HomeRailsLoadTracker.resultOf { try await resumeItems(limit: 20) }
        async let nextUpResult = HomeRailsLoadTracker.resultOf { try await nextUp(limit: 20) }

        if let continueWatching = tracker.record(await continueWatchingResult), !continueWatching.isEmpty {
            rails.append(JellyfinHomeRail(id: "continue-watching",
                                          title: "Continue Watching",
                                          items: continueWatching))
        }

        if let nextUpItems = tracker.record(await nextUpResult), !nextUpItems.isEmpty {
            rails.append(JellyfinHomeRail(id: "next-up",
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
                rails.append(JellyfinHomeRail(id: "latest-\(view.id)",
                                              title: "Recently Added \(view.title)",
                                              items: items))
            }
        }
        if tracker.isDegraded {
            NSLog("[#93] Jellyfin homeRails degraded: %d of up to %d rails returned; will not pin loaded identity",
                  rails.count, views.prefix(8).count + 2)
        }
        return HomeRailsLoad(rails: rails, isDegraded: tracker.isDegraded)
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
                     includeItemTypes: String = "Movie,Episode",
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
        let maxBitrateBps = maxVideoBitrateKbps <= 0 ? 200_000_000 : maxVideoBitrateKbps * 1_000
        let resolutionCap = Self.resolutionCap(forBitrateKbps: maxVideoBitrateKbps)
        let audioBitrate = Self.audioBitrate(forBitrateKbps: maxVideoBitrateKbps)
        let startTicks = (resumeOffsetMs ?? item.viewOffset).map { $0 * 10_000 }
        let req = try JellyfinPlayback.playbackInfoRequest(server: context.server,
                                                           token: context.token,
                                                           identity: jellyfinIdentity,
                                                           itemId: item.ratingKey,
                                                           userId: context.userID,
                                                           startTimeTicks: startTicks,
                                                           maxStreamingBitrate: maxBitrateBps,
                                                           audioStreamIndex: audioStreamIndex,
                                                           subtitleStreamIndex: subtitleStreamIndex)
        let info = try await send(req, as: JellyfinPlaybackInfoResponse.self)
        return try JellyfinPlayback.resolveStream(response: info,
                                                  server: context.server,
                                                  identity: jellyfinIdentity,
                                                  token: context.token,
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
            return status == 400 || status == 404 || status == 410
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

private func latestItemTypes(for view: JellyfinLibraryLink) -> String {
    switch view.collectionType {
    case "movies":
        return "Movie"
    case "tvshows":
        return "Episode"
    default:
        return "Movie,Episode"
    }
}

struct JellyfinLibraryLink: Identifiable, Hashable {
    let id: String
    let title: String
    let collectionType: String?
}

struct JellyfinHomeRail: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [MediaItem]
}
