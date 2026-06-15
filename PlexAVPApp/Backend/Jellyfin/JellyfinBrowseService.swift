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
        JellyfinClientIdentity(client: appModel.identity.product,
                               device: appModel.identity.deviceName,
                               deviceId: appModel.identity.clientIdentifier,
                               version: appModel.identity.version)
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
               limit: Int? = nil,
               searchTerm: String? = nil,
               sortBy: String = "SortName",
               sortOrder: String = "Ascending",
               filters: [String] = []) async throws -> [MediaItem] {
        let context = try context()
        let req = try JellyfinLibrary.itemsRequest(server: context.server,
                                                   token: context.token,
                                                   identity: jellyfinIdentity,
                                                   userId: context.userID,
                                                   parentId: parentId,
                                                   recursive: recursive,
                                                   limit: limit,
                                                   searchTerm: searchTerm,
                                                   sortBy: sortBy,
                                                   sortOrder: sortOrder,
                                                   filters: filters)
        let response = try await send(req, as: JellyfinItemsResponse.self)
        return response.items.compactMap { $0.toMediaItem() }
    }

    func homeRails(for views: [JellyfinLibraryLink]) async throws -> [JellyfinHomeRail] {
        _ = try context()
        var rails: [JellyfinHomeRail] = []

        let continueWatching = try? await resumeItems(limit: 20)
        if let continueWatching, !continueWatching.isEmpty {
            rails.append(JellyfinHomeRail(id: "continue-watching",
                                          title: "Continue Watching",
                                          items: continueWatching))
        }

        let nextUpItems = try? await nextUp(limit: 20)
        if let nextUpItems, !nextUpItems.isEmpty {
            rails.append(JellyfinHomeRail(id: "next-up",
                                          title: "Next Up",
                                          items: nextUpItems))
        }

        for view in views.prefix(8) {
            let items = (try? await latestItems(parentId: view.id,
                                                includeItemTypes: latestItemTypes(for: view),
                                                limit: 20)) ?? []
            if !items.isEmpty {
                rails.append(JellyfinHomeRail(id: "latest-\(view.id)",
                                              title: "Recently Added \(view.title)",
                                              items: items))
            }
        }
        return rails
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
                      resumeOffsetMs: Int? = nil) async throws -> JellyfinPlaybackOpenResult {
        let context = try context()
        let maxBitrateBps = maxVideoBitrateKbps <= 0 ? 200_000_000 : maxVideoBitrateKbps * 1_000
        let startTicks = (resumeOffsetMs ?? item.viewOffset).map { $0 * 10_000 }
        let req = try JellyfinPlayback.playbackInfoRequest(server: context.server,
                                                           token: context.token,
                                                           identity: jellyfinIdentity,
                                                           itemId: item.ratingKey,
                                                           userId: context.userID,
                                                           startTimeTicks: startTicks,
                                                           maxStreamingBitrate: maxBitrateBps)
        let info = try await send(req, as: JellyfinPlaybackInfoResponse.self)
        return try JellyfinPlayback.resolveStream(response: info,
                                                  server: context.server,
                                                  identity: jellyfinIdentity,
                                                  token: context.token,
                                                  itemId: item.ratingKey)
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

    func downloadRequest(itemId: String) throws -> URLRequest {
        let context = try context()
        return try JellyfinLibrary.downloadRequest(server: context.server,
                                                   token: context.token,
                                                   identity: jellyfinIdentity,
                                                   itemId: itemId)
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

    func stopActiveEncoding(playSessionId: String) async {
        guard let context = try? context(), !playSessionId.isEmpty else { return }
        guard let req = try? JellyfinLibrary.activeEncodingStopRequest(server: context.server,
                                                                       token: context.token,
                                                                       identity: jellyfinIdentity,
                                                                       deviceId: appModel.identity.clientIdentifier,
                                                                       playSessionId: playSessionId) else { return }
        _ = try? await send(req)
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
